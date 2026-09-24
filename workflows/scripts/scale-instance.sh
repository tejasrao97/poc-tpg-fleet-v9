#!/usr/bin/env bash
# scale-instance.sh plan WORKFLOW_NAME
# scale-instance.sh apply WORKFLOW_NAME CLUSTER INSTANCE TIMEOUT_SECONDS REPLICAS PREVIOUS
# tpg-scale-instance: set the read replica count of the selected instances.
# Targets: clusterMap (replicas and enableHAIfNeeded per instance, the inputs as
# defaults), or every instance of the instances list on every cluster of the
# clusters list (the discover step has checked that each one is declared).
#
# plan (one step for the run):
#   1 guards   0 <= replicas <= maxReadReplicas, instance Running, no upgrade or
#              restore in progress, the clusterMap postgresVersion guard
#   2 HA       replicas > 0 needs highAvailability.enabled: turned on when
#              enableHAIfNeeded=true, otherwise the instance fails. replicas=0 keeps
#              high availability as it is.
#   3 Git      clusters.<cluster>.instances.<instance>.instance.highAvailability for
#              every target in one commit (PUSH_MODE direct | pr)
#   Outputs /tmp/items.json: the instances to sync ([{cluster, instance, replicas, previous}]).
# apply (one step per instance): sync the instance Application at the pushed
#   commit, check spec.highAvailability.readReplicas, then the pods until Running.
# P_DRY_RUN=true records the plan per instance and changes nothing.
MODE="$1"; WF="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

if [[ "$MODE" == "plan" ]]; then
  result_guard result.git
  echo '[]' > /tmp/items.json
  REPO="$WORK/repo"
  git_clone "$REPO"
  inv="$(run_data inventory)"; [[ -n "$inv" ]] || inv="[]"
  items="[]"; summary=()
  while read -r C I; do
    [[ -n "$C" ]] || continue
    key="result.${C}.${I}"
    ifail() { record_entry "$key" FAILED "$1" "${2:-}"; }
    N="$(cmap_ival "$C" "$I" replicas "${P_REPLICAS:-}")"
    [[ "$N" =~ ^[0-9]+$ ]] || { ifail OUT_OF_BOUNDS "replicas must be a non-negative integer (got '${N}')"; continue; }
    max="$(fleet_cluster_value "$REPO" "$C" '.cluster.maxReadReplicas' 3)"
    (( N <= max )) || { ifail OUT_OF_BOUNDS "replicas ${N} > maxReadReplicas ${max}"; continue; }
    ha="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.enabled' true)"
    cur="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.readReplicas' 0)"
    [[ "$ha" == "true" ]] || cur=0
    HA="$ha"
    if (( N > 0 )) && [[ "$ha" != "true" ]]; then
      [[ "$(cmap_ival "$C" "$I" enableHAIfNeeded "${P_ENABLE_HA:-true}")" == "true" ]] \
        || { ifail HA_DISABLED "replicas ${N} needs highAvailability; set enableHAIfNeeded=true"; continue; }
      HA=true
    fi
    use_cluster "$C" || { ifail NOT_REGISTERED; continue; }
    if ! g="$(cmap_guard "$C" "$I")"; then record_entry "$key" SKIPPED_VERSION_MISMATCH "" "$g"; continue; fi
    [[ "$(pg_state "$I")" == "Running" ]] || { ifail NOT_RUNNING "currentState=$(pg_state "$I")"; continue; }
    busy=""
    for kind in postgresversionupgrade postgresrestore; do
      n="$(tk -n "pg-${I}" get "$kind" -o json 2>/dev/null \
        | jq -r '[.items[] | select((.status.phase // "") | test("^(Succeeded|Failed|PreCheckFailed)$") | not)] | length')"
      [[ "${n:-0}" -eq 0 ]] || busy="${busy}${kind} "
    done
    [[ -z "$busy" ]] || { ifail OPERATION_IN_PROGRESS "$busy"; continue; }
    if [[ "$cur" == "$N" && "$HA" == "$ha" ]]; then
      record_entry "$key" SUCCEEDED ALREADY_AT_TARGET "readReplicas=${N}"
      continue
    fi
    if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
      record_entry "$key" SUCCEEDED DRY_RUN "would set readReplicas ${cur} -> ${N}, highAvailability ${ha} -> ${HA}"
      continue
    fi
    C="$C" I="$I" N="$N" HA="$HA" yq -i '
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.enabled = (strenv(HA) == "true") |
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.readReplicas = (strenv(N) | tonumber)' "$REPO/$FLEET_REL"
    items="$(jq -c --arg c "$C" --arg i "$I" --arg n "$N" --arg p "$cur" '. + [{cluster: $c, instance: $i, replicas: $n, previous: $p}]' <<<"$items")"
    summary+=("${C}/${I} ${cur}->${N}")
  done < <(jq -r '.[] | .name as $c | .instances[] | "\($c) \(.name)"' <<<"$inv")

  if [[ "$(jq 'length' <<<"$items")" -eq 0 ]]; then
    record result.git SUCCEEDED NO_CHANGE "nothing to change in ${FLEET_REL}"
    exit 0
  fi
  git_commit_push "$REPO" "scale ${summary[*]} (${WF})" "$FLEET_REL" \
    || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
  record_entry revision SET "" "${PUSHED_REVISION:-}"
  printf '%s' "$items" > /tmp/items.json
  record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} ${PUSHED_REVISION:0:12} $(cat /tmp/pull-request 2>/dev/null || true)"
  exit 0
fi

# ---- apply: one instance
C="$3"; I="$4"; TIMEOUT="$5"; N="$6"; prev="${7:-}"
key="result.${C}.${I}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
use_cluster "$C" || fail NOT_REGISTERED
ns="pg-${I}"
app="tpg-${C}-${I}"
rev="$(run_data revision | jq -r '.detail // empty')"
[[ -n "$rev" ]] || rev="$(fleet_head)"
_PG_WATCHED="$I"
rc=0; app_sync_wait "$app" "$TIMEOUT" ${rev:+--revision "$rev"} --pods "$ns" "postgres-instance=${I}" --ready-fn _pg_ready || rc=$?
[[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"

spec_rr="$(tk -n "$ns" get postgres "$I" -o jsonpath='{.spec.highAvailability.readReplicas}')"
[[ "${spec_rr:-0}" == "$N" ]] || fail SPEC_NOT_APPLIED "spec.highAvailability.readReplicas=${spec_rr}, expected ${N}"
# The operator adds or removes replica pods after the spec change
log "giving the operator 30s to act on the spec change"
sleep 30
pg_wait_ready "$I" "$TIMEOUT" || fail "${POD_WATCH_REASON:-REPLICAS_NOT_READY}" "after the scale: ${POD_WATCH_DETAIL}"
ready="$(tk -n "$ns" get statefulset "$I" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
record "$key" SUCCEEDED "" "readReplicas=${N}, statefulset ready ${ready}" "$prev"
