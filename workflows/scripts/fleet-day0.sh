#!/usr/bin/env bash
# fleet-day0.sh WORKFLOW_NAME CLUSTERS_JSON
# Write the tpg-day0 inputs into clusters/fleet.yaml for every selected cluster.
#
# The targets and their values come from clusterMap (P_CLUSTER_MAP) or from the
# clusters and instances inputs; the other inputs are the defaults of every
# target and a clusterMap key overrides them for one cluster or instance. Each
# value is written to the clusters/fleet.yaml paths listed for its key in
# workflows/params/cluster-map-keys.yaml ("fleet"), so a new Day 0 key needs no
# change here:
#   clusters.<cluster>.operator.version                 operatorVersion
#   clusters.<cluster>.cluster.maxReadReplicas          maxReadReplicas
#   clusters.<cluster>.instances.<instance>.instance.*  postgresVersion, highAvailability,
#                                                       readReplicas, sizing, storageClass
#   clusters.<cluster>.instances.<instance>.backup.*    enableSSL, backupSchedule (scheduled)
# Existing entries keep their other settings.
#
# Versions (design decision D49): the cluster decides, not clusters/fleet.yaml.
#   - The operator (or an instance) does not run on the target yet: the input wins
#     and replaces whatever fleet.yaml declares (FLEET_OVERRIDDEN, logged and in
#     the result).
#   - It runs the requested version: nothing to change.
#   - It runs another version: the cluster is BLOCKED (UPGRADE_REQUIRED when the
#     input is newer, DOWNGRADE_NOT_ALLOWED when it is older, VERSION_UNKNOWN when
#     the running version cannot be read), fleet.yaml is not changed for it, and
#     the pre-check reports it; the other clusters go ahead. tpg-upgrade moves a
#     running operator or instance to another version.
#
# dryRun=true: log the change and output it, push nothing. Otherwise commit with
# PUSH_MODE (direct | pr). Outputs /tmp/fleet.json: the planned fleet.yaml as JSON
# on a dry run (discover uses it instead of Git), otherwise {}.
# Inputs (environment): P_CLUSTER_MAP P_INSTANCES P_HA P_OPERATOR_VERSION
#   P_POSTGRES_VERSION P_READ_REPLICAS P_STORAGE_SIZE P_WAL_STORAGE_SIZE
#   P_STORAGE_CLASS P_CPU P_MEMORY P_BACKUP_SCHEDULE P_BACKUP_ENABLE_SSL P_DRY_RUN
WF="$1"; CLUSTERS_JSON="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
result_guard result.git

REPO="$WORK/repo"
F="$REPO/clusters/fleet.yaml"
git_clone "$REPO"
cp "$F" "$WORK/fleet.before.yaml"
FAILED=(); NOTES=(); BLOCKED=()

# ---- the effective targets: clusterMap, or the clusters x instances inputs,
# with the inputs as defaults of every key tpg-day0 uses
yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/keys.json"
if cmap_set; then
  cmap_load
  cp "$WORK/cmap.json" "$WORK/targets.json"
else
  jq -cn --argjson cl "$CLUSTERS_JSON" --arg inst "$(split_list "${P_INSTANCES:-}" | paste -sd,)" '
    ($inst | split(",") | map(select(length > 0))) as $il
    | reduce $cl[] as $c ({}; .[$c] = {instances: (reduce $il[] as $i ({}; .[$i] = {}))})' > "$WORK/targets.json"
fi
opv_flag=""; [[ -z "${P_OPERATOR_VERSION:-}" ]] || opv_flag="$(norm_operator_version "$P_OPERATOR_VERSION")"
pgv_flag=""; [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgv_flag="$(norm_postgres_version "$P_POSTGRES_VERSION")"
jq -cn --arg operatorVersion "$opv_flag" --arg postgresVersion "$pgv_flag" --arg highAvailability "${P_HA:-}" \
  --arg readReplicas "${P_READ_REPLICAS:-1}" --arg storageSize "${P_STORAGE_SIZE:-}" \
  --arg walStorageSize "${P_WAL_STORAGE_SIZE:-}" --arg storageClass "${P_STORAGE_CLASS:-}" \
  --arg cpu "${P_CPU:-}" --arg memory "${P_MEMORY:-}" --arg backupSchedule "${P_BACKUP_SCHEDULE:-fleet}" \
  --arg backupEnableSSL "${P_BACKUP_ENABLE_SSL:-false}" '$ARGS.named' > "$WORK/flags.json"
# shellcheck disable=SC2016  # jq program
jq -c --slurpfile keys "$WORK/keys.json" --slurpfile flags "$WORK/flags.json" '
  $keys[0] as $k | $flags[0] as $f
  | def fill($level; $entry):
      reduce ($level | to_entries[] | select(.value.workflows.day0 != null)) as $e ($entry;
        if has($e.key) then .
        else ((if ($e.value | has("flag")) then $e.value.flag else $e.key end)) as $fl
          | (if $fl == "" then "" else ($f[$fl] // "") end) as $v
          | if $v != "" then .[$e.key] = $v else . end
        end);
    with_entries(.value |= (fill($k.cluster; .)
      | .instances = ((.instances // {}) | with_entries(.value |= fill($k.instance; .)))))
' "$WORK/targets.json" > "$WORK/effective.json"

# ---- what runs on the target now
live_operator() {
  # live_operator -> "none", "unknown" or the running operator version (vX.Y.Z)
  # of the current cluster (use_cluster first, in this shell: tk reads CLUSTER)
  local img tag
  img="$(tk get deploy -A -l app=postgres-operator -o json 2>/dev/null \
    | jq -r '[.items[].spec.template.spec.containers[] | select(.image | test("postgres-operator")) | .image][0] // ""')"
  [[ -n "$img" ]] || { echo none; return; }
  tag="${img##*:}"; tag="${tag%%@*}"
  if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then norm_operator_version "$tag"; else echo unknown; fi
}
live_postgres() {
  # live_postgres INSTANCE -> "none" or the spec.postgresVersion.name of the running instance (use_cluster first)
  local v
  v="$(tk -n "pg-$1" get postgres "$1" -o jsonpath='{.spec.postgresVersion.name}' 2>/dev/null || true)"
  if tk -n "pg-$1" get postgres "$1" >/dev/null 2>&1; then printf '%s' "${v:-unknown}"; else echo none; fi
}
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }   # A newer than B
block() {  # block CLUSTER REASON DETAIL: the cluster keeps its fleet.yaml entry; the pre-check reports it
  record_entry "block.$1" BLOCKED "$2" "$3"
  BLOCKED+=("$1: $2 $3")
}

write_value() {  # write_value BASE_YQ_PATH FLEET_PATH FORMAT VALUE (paths from cluster-map-keys.yaml)
  local base="$1" path="$2" fmt="$3" v="$4" expr
  [[ "$path" =~ ^(\.[A-Za-z0-9_]+)+$ ]] || { FAILED+=("cluster-map-keys.yaml: invalid fleet path ${path}"); return; }
  case "$fmt" in
    number)  expr="(strenv(V) | tonumber)" ;;
    boolean) expr="(strenv(V) == \"true\")" ;;
    *)       expr="strenv(V)" ;;
  esac
  V="$v" C="$CUR_C" I="${CUR_I:-}" yq -i "${base}${path} = ${expr}" "$F"
}

for c in $(jq -r 'keys[]' "$WORK/effective.json"); do
  CUR_C="$c"; CUR_I=""
  entry="$(jq -c --arg c "$c" '.[$c]' "$WORK/effective.json")"
  opv="$(jq -r '.operatorVersion // ""' <<<"$entry")"
  [[ -n "$opv" ]] || { FAILED+=("${c}: operatorVersion is required"); continue; }
  max="$(jq -r '.maxReadReplicas // ""' <<<"$entry")"
  [[ -n "$max" ]] || max="$(fleet_cluster_value "$REPO" "$c" '.cluster.maxReadReplicas' 3)"

  # ---- versions against the live cluster
  cur_opv="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$F")"
  if use_cluster "$c" >/dev/null 2>&1 && tk get --raw=/readyz >/dev/null 2>&1; then
    live="$(live_operator)"
  else
    live=unreachable
  fi
  case "$live" in
    unreachable) block "$c" UNREACHABLE "API server not reachable from the hub"; continue ;;
    none)
      [[ -z "$cur_opv" || "$cur_opv" == "$opv" ]] \
        || NOTES+=("FLEET_OVERRIDDEN ${c} operator ${cur_opv} -> ${opv} (not installed on the cluster)") ;;
    unknown)
      if [[ "$cur_opv" != "$opv" ]]; then
        block "$c" VERSION_UNKNOWN "an operator runs on ${c} but its version cannot be read from its image; fleet.yaml declares ${cur_opv:-none}, the input is ${opv}"
        continue
      fi ;;
    "$opv")
      [[ -z "$cur_opv" || "$cur_opv" == "$opv" ]] \
        || NOTES+=("FLEET_OVERRIDDEN ${c} operator ${cur_opv} -> ${opv} (the cluster runs ${opv})") ;;
    *)
      if newer "${opv#v}" "${live#v}"; then
        block "$c" UPGRADE_REQUIRED "operator ${live} runs on ${c}: use tpg-upgrade component=operator targetVersion=${opv}"
      else
        block "$c" DOWNGRADE_NOT_ALLOWED "operator ${live} runs on ${c}, which is newer than ${opv}"
      fi
      continue ;;
  esac
  stop=""
  for i in $(jq -r '.instances | keys[]' <<<"$entry"); do
    pgv="$(jq -r --arg i "$i" '.instances[$i].postgresVersion // ""' <<<"$entry")"
    [[ -n "$pgv" ]] || { FAILED+=("${c}/${i}: postgresVersion is required"); continue; }
    cur_pgv="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion // ""' "$F")"
    lpg="none"; [[ "$live" == "none" ]] || lpg="$(live_postgres "$i")"
    case "$lpg" in
      none)
        [[ -z "$cur_pgv" || "$cur_pgv" == "$pgv" ]] \
          || NOTES+=("FLEET_OVERRIDDEN ${c}/${i} ${cur_pgv} -> ${pgv} (not running on the cluster)") ;;
      "$pgv")
        [[ -z "$cur_pgv" || "$cur_pgv" == "$pgv" ]] \
          || NOTES+=("FLEET_OVERRIDDEN ${c}/${i} ${cur_pgv} -> ${pgv} (the instance runs ${pgv})") ;;
      unknown) stop="VERSION_UNKNOWN ${i} runs on ${c} without spec.postgresVersion.name" ;;
      *)
        if newer "${pgv#postgres-}" "${lpg#postgres-}"; then
          stop="UPGRADE_REQUIRED ${i} runs ${lpg} on ${c}: use tpg-upgrade component=postgres targetVersion=${pgv} instances=${i}"
        else
          stop="DOWNGRADE_NOT_ALLOWED ${i} runs ${lpg} on ${c}, which is newer than ${pgv}"
        fi ;;
    esac
    [[ -z "$stop" ]] || break
  done
  if [[ -n "$stop" ]]; then block "$c" "${stop%% *}" "${stop#* }"; continue; fi

  # ---- write the values
  while IFS=$'\t' read -r key fmt paths; do
    v="$(jq -r --arg k "$key" '.[$k] // ""' <<<"$entry")"
    [[ -n "$v" ]] || continue
    for p in $paths; do write_value '.clusters[strenv(C)]' "$p" "$fmt" "$v"; done
  done < <(jq -r '.cluster | to_entries[] | select(.value.workflows.day0 != null and (.value.fleet // [] | length) > 0)
      | [.key, (.value.format // "string"), (.value.fleet | join(" "))] | @tsv' "$WORK/keys.json")
  for i in $(jq -r '.instances | keys[]' <<<"$entry"); do
    CUR_I="$i"
    ientry="$(jq -c --arg i "$i" '.instances[$i]' <<<"$entry")"
    ha="$(jq -r '.highAvailability // ""' <<<"$ientry")"
    [[ -n "$ha" ]] || { FAILED+=("${c}/${i}: highAvailability is required"); continue; }
    # read replicas only with high availability
    [[ "$ha" == "true" ]] || ientry="$(jq -c '.readReplicas = "0"' <<<"$ientry")"
    rr="$(jq -r '.readReplicas // "0"' <<<"$ientry")"
    if (( rr > max )); then FAILED+=("${c}/${i}: readReplicas ${rr} exceeds maxReadReplicas ${max}"); continue; fi
    while IFS=$'\t' read -r key fmt paths; do
      v="$(jq -r --arg k "$key" '.[$k] // ""' <<<"$ientry")"
      [[ -n "$v" ]] || continue
      for p in $paths; do write_value '.clusters[strenv(C)].instances[strenv(I)]' "$p" "$fmt" "$v"; done
    done < <(jq -r '.instance | to_entries[] | select(.value.workflows.day0 != null and (.value.fleet // [] | length) > 0)
        | [.key, (.value.format // "string"), (.value.fleet | join(" "))] | @tsv' "$WORK/keys.json")
    # backupSchedule: none excludes the instance from the backup CronWorkflows
    if [[ "$(jq -r '.backupSchedule // "fleet"' <<<"$ientry")" == "none" ]]; then
      C="$c" I="$i" yq -i '.clusters[strenv(C)].instances[strenv(I)].backup.scheduled = false' "$F"
    else
      C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].backup.scheduled) |
        del(.clusters[strenv(C)].instances[strenv(I)].backup | select(length == 0))' "$F"
    fi
  done
done

echo '{}' > /tmp/fleet.json
if [[ "${#FAILED[@]}" -gt 0 ]]; then
  record result.git FAILED INVALID_INPUT "$(printf '%s; ' "${FAILED[@]}")"
  exit 1
fi
for n in "${NOTES[@]}"; do log "$n"; done
for b in "${BLOCKED[@]}"; do log "BLOCKED ${b} (fleet.yaml not changed for this cluster)"; done
note="$( [[ "${#NOTES[@]}" -eq 0 ]] || printf '%s; ' "${NOTES[@]}")$( [[ "${#BLOCKED[@]}" -eq 0 ]] || printf 'blocked: %s; ' "${BLOCKED[@]%%:*}")"
changes="$(diff -u "$WORK/fleet.before.yaml" "$F" | tail -n +3 || true)"
if [[ -z "$changes" ]]; then
  record result.git SUCCEEDED NO_CHANGE "clusters/fleet.yaml already declares these inputs${note:+; ${note}}"
  exit 0
fi
log "clusters/fleet.yaml changes:"
printf '%s\n' "$changes" >&2
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  yq -o=json -I=0 '.' "$F" > /tmp/fleet.json
  record result.git SUCCEEDED DRY_RUN "$(grep -c '^[+-]' <<<"$changes") changed lines, not pushed${note:+; ${note}}"
  exit 0
fi
summary="$(jq -r 'to_entries | map(.key + "(" + ((.value.instances // {}) | keys | join(",")) + ")") | join(" ")' "$WORK/effective.json")"
git_commit_push "$REPO" "day0: ${summary} (${WF})" clusters/fleet.yaml \
  || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
appset_refresh tpg-operator
appset_refresh tpg-instances
record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} $(cat /tmp/pull-request 2>/dev/null || true)${note:+; ${note}}"
