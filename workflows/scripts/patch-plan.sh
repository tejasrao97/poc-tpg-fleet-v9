#!/usr/bin/env bash
# patch-plan.sh WORKFLOW_NAME
# tpg-patch, before anything changes on a cluster: resolve the patch files of
# every target, check them, write the references into clusters/fleet.yaml and
# dry-run the result on each target cluster. Then commit (PUSH_MODE direct | pr)
# unless dryRun=true.
#
# Targets come from the discover step (run inventory): the clusterMap entries,
# or the clusters and instances inputs. Patch files per target: the clusterMap
# keys, else the workflow inputs:
#   instance  postgresPatchFilePath  partial Postgres manifests  charts/tpg-instance/patches/
#             valuesPatchFilePath    chart values fragments      charts/tpg-instance/patches/
#   cluster   operatorValuesPatchFilePath    operator chart values     patches/operator/
#             operatorManifestPatchFilePath  partial manifests of objects the operator
#                                            chart renders              patches/operator/
# patchMode (map key or input): append (default; a file already listed is a
# no-op), replace (the given files become the list of that kind), remove (the
# given files leave the list).
#
# clusters/fleet.yaml keeps references only, never file contents:
#   clusters.<c>.instances.<i>.patches.postgres   paths relative to charts/tpg-instance
#   clusters.<c>.instances.<i>.patches.values     (the chart reads them with .Files.Get)
#   clusters.<c>.operator.patches.values          repository paths ($fleet/<path> value files)
#   clusters.<c>.operator.patches.manifests       repository paths (server-side apply, tpg-patch)
#
# Checks (refused with the workflow that owns the field):
#   postgres files   kind Postgres, only apiVersion/kind/spec; no spec.postgresVersion
#                    (tpg-upgrade), spec.highAvailability (tpg-scale-instance),
#                    spec.storageClassName; storageSize/walStorageSize not smaller
#   values files     no instance.name, instance.postgresVersion, instance.highAvailability,
#                    instance.storageClassName, cluster, patches; sizes not smaller;
#                    no backup.additionalParameters, backup.enableSSL, backup.forcePathStyle
#                    (ignored by the tpg-instances ApplicationSet on a running instance)
#   operator values  no operatorImage or postgresImage (the image follows the chart
#                    version: tpg-upgrade)
#   operator manifests  apiVersion, kind and metadata.name of an object the operator
#                    Application manages; no image field anywhere
#   clusterMap postgresVersion guard: an instance that runs another version is
#                    SKIPPED_VERSION_MISMATCH and left out
# Dry run per cluster: the instance manifests rendered by helm from the new
# fleet.yaml (Postgres, PostgresBackupLocation), the operator chart rendered with
# the new value files (its Deployments), and the operator manifest patches -
# each applied with --dry-run=server on the target. A cluster that fails is
# BLOCKED (its fleet.yaml entry is left as it was); the others go ahead.
#
# Records precheck.<cluster> (PASSED | BLOCKED) for plan-batches, plan.<cluster>
# (what patch-cluster.sh syncs), revision (the pushed commit) and result.git.
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
result_guard result.git

REPO="$WORK/repo"
F="$REPO/$FLEET_REL"
git_clone "$REPO"
cp "$F" "$WORK/fleet.before.yaml"
inv="$(run_data inventory)"; [[ -n "$inv" ]] || inv="[]"
CHART_PREFIX="charts/tpg-instance/"
any_blocked=0

# ---- file checks (append and replace only; remove needs no file)
file_errors=()
ferr() { file_errors+=("$*"); }
check_yaml_map() {  # check_yaml_map FILE
  [[ -f "$REPO/$1" ]] || { ferr "$1 does not exist in the fleet repository (commit and push it first)"; return 1; }
  yq -e 'type == "!!map"' "$REPO/$1" >/dev/null 2>&1 || { ferr "$1 is not a YAML map"; return 1; }
}
size_not_smaller() {  # size_not_smaller FILE WHAT NEW CURRENT
  [[ -n "$3" && -n "$4" ]] || return 0
  local n c
  n="$(qty_bytes "$3")"; c="$(qty_bytes "$4")"
  [[ "$n" -ge 0 && "$c" -ge 0 ]] || { ferr "$1: $2 '$3' is not a valid quantity"; return 0; }
  (( n >= c )) || ferr "$1: $2 ${3} is smaller than the current ${4}; a volume cannot shrink"
}
check_postgres_file() {  # check_postgres_file FILE CLUSTER INSTANCE
  local f="$1" bad
  check_yaml_map "$f" || return
  [[ "$(yq -r '.kind // ""' "$REPO/$f")" == "Postgres" ]] || ferr "$f: kind must be Postgres"
  bad="$(yq -r 'keys | map(select(. != "apiVersion" and . != "kind" and . != "spec")) | join(",")' "$REPO/$f")"
  [[ -z "$bad" ]] || ferr "$f: only apiVersion, kind and spec can be patched (found ${bad})"
  yq -e '.spec.postgresVersion == null' "$REPO/$f" >/dev/null || ferr "$f: spec.postgresVersion is changed by tpg-upgrade component=postgres"
  yq -e '.spec.highAvailability == null' "$REPO/$f" >/dev/null || ferr "$f: spec.highAvailability is changed by tpg-scale-instance"
  yq -e '.spec.storageClassName == null' "$REPO/$f" >/dev/null || ferr "$f: spec.storageClassName cannot change on a running instance"
  size_not_smaller "$f" spec.storageSize "$(yq -r '.spec.storageSize // ""' "$REPO/$f")" \
    "$(fleet_instance_value "$REPO" "$2" "$3" '.instance.storageSize' '')"
  size_not_smaller "$f" spec.walStorageSize "$(yq -r '.spec.walStorageSize // ""' "$REPO/$f")" \
    "$(fleet_instance_value "$REPO" "$2" "$3" '.instance.walStorageSize' '')"
}
check_values_file() {  # check_values_file FILE CLUSTER INSTANCE
  local f="$1" k
  check_yaml_map "$f" || return
  for k in .instance.name .instance.postgresVersion .instance.highAvailability .instance.storageClassName .cluster .patches; do
    yq -e "${k} == null" "$REPO/$f" >/dev/null || ferr "$f: ${k#.} cannot be set by a values patch"
  done
  # tpg-instances ignores these PostgresBackupLocation fields (ignoreDifferences with
  # RespectIgnoreDifferences), so a sync would never apply them to a running instance
  for k in .backup.additionalParameters .backup.enableSSL .backup.forcePathStyle; do
    yq -e "${k} == null" "$REPO/$f" >/dev/null \
      || ferr "$f: ${k#.} is ignored by Argo CD on a running instance (tpg-instances ignoreDifferences); it is set when the instance is created (tpg-day0)"
  done
  size_not_smaller "$f" instance.storageSize "$(yq -r '.instance.storageSize // ""' "$REPO/$f")" \
    "$(fleet_instance_value "$REPO" "$2" "$3" '.instance.storageSize' '')"
  size_not_smaller "$f" instance.walStorageSize "$(yq -r '.instance.walStorageSize // ""' "$REPO/$f")" \
    "$(fleet_instance_value "$REPO" "$2" "$3" '.instance.walStorageSize' '')"
}
check_operator_values_file() {  # check_operator_values_file FILE
  check_yaml_map "$1" || return
  yq -e '.operatorImage == null and .postgresImage == null' "$REPO/$1" >/dev/null \
    || ferr "$1: operatorImage and postgresImage follow the operator version (tpg-upgrade component=operator)"
}
check_operator_manifest_file() {  # check_operator_manifest_file FILE CLUSTER
  local f="$1" doc key resources
  [[ -f "$REPO/$f" ]] || { ferr "$f does not exist in the fleet repository (commit and push it first)"; return; }
  resources="$(app_get "tpg-$2-operator" | jq -c '[.status.resources[]? | (.kind + "/" + .name)]')"
  while IFS= read -r doc; do
    [[ -n "$doc" ]] || continue
    key="$(jq -r '(.kind // "") + "/" + (.metadata.name // "")' <<<"$doc")"
    jq -e '(.apiVersion // "") != "" and (.kind // "") != "" and (.metadata.name // "") != ""' <<<"$doc" >/dev/null \
      || { ferr "$f: every document needs apiVersion, kind and metadata.name"; continue; }
    jq -e --arg k "$key" 'index($k) != null' <<<"$resources" >/dev/null \
      || ferr "$f: ${key} is not an object of the operator Application tpg-$2-operator"
    jq -e '[.. | objects | select(has("image"))] | length == 0' <<<"$doc" >/dev/null \
      || ferr "$f: ${key}: image fields follow the operator version (tpg-upgrade component=operator)"
  done < <(yq -o=json -I=0 'select(. != null)' "$REPO/$f")
}

# ---- list edits in fleet.yaml
ordered_append() {  # ordered_append YQ_PATH FILE...: append the files not listed yet, keeping order
  local path="$1" f
  shift
  for f in "$@"; do
    V="$f" yq -e "(${path} // []) | any_c(. == strenv(V))" "$F" >/dev/null 2>&1 && continue
    V="$f" yq -i "${path} = ((${path} // []) + [strenv(V)])" "$F"
  done
}
apply_mode() {  # apply_mode YQ_PATH MODE FILE...
  local path="$1" mode="$2"
  shift 2
  case "$mode" in
    append) ordered_append "$path" "$@" ;;
    replace) yq -i "${path} = []" "$F"; ordered_append "$path" "$@" ;;
    remove) local f; for f in "$@"; do V="$f" yq -i "${path} = ((${path} // []) - [strenv(V)])" "$F"; done ;;
  esac
}
prune_empty() {  # prune_empty CLUSTER: drop empty patches lists and maps
  C="$1" yq -i '
    (.clusters[strenv(C)].instances[]? | select(has("patches"))) |= (.patches |= with_entries(select((.value | length) > 0)))
    | (.clusters[strenv(C)].instances[]? | select(has("patches") and (.patches | length) == 0)) |= del(.patches)
    | (.clusters[strenv(C)] | select(has("operator")) | .operator | select(has("patches")))
        |= (.patches |= with_entries(select((.value | length) > 0)))
    | (.clusters[strenv(C)] | select(has("operator")) | .operator | select(has("patches") and (.patches | length) == 0))
        |= del(.patches)' "$F"
}

split_paths() { split_list "$1" | sed 's#^\./##'; }

for c in $(jq -r '.[].name' <<<"$inv"); do
  C_ERRS=()
  cp "$F" "$WORK/fleet.cluster.bak"
  plan='{"instances":[],"operatorValues":false,"operatorManifests":false,"oldManifests":[]}'
  if ! use_cluster "$c" || ! tk get --raw=/readyz >/dev/null 2>&1; then
    record_entry "precheck.${c}" BLOCKED UNREACHABLE "API server not reachable from the hub"
    any_blocked=1; continue
  fi
  file_errors=()

  # ---- operator
  opv_files="$(cmap_cval "$c" operatorValuesPatchFilePath "${P_OPERATOR_VALUES_PATCH:-}")"
  opm_files="$(cmap_cval "$c" operatorManifestPatchFilePath "${P_OPERATOR_MANIFEST_PATCH:-}")"
  cmode="$(cmap_cval "$c" patchMode "${P_PATCH_MODE:-append}")"
  if [[ -n "$opv_files$opm_files" ]] && ! fleet_has_cluster "$REPO" "$c"; then
    C_ERRS+=("no clusters.${c} in ${FLEET_REL} (run tpg-day0 first)")
  fi
  old_manifests="$(C="$c" yq -o=json -I=0 '.clusters[strenv(C)].operator.patches.manifests // []' "$F")"
  if [[ -n "$opv_files" ]]; then
    mapfile -t files < <(split_paths "$opv_files")
    [[ "$cmode" == "remove" ]] || for f in "${files[@]}"; do check_operator_values_file "$f"; done
    apply_mode ".clusters[\"${c}\"].operator.patches.values" "$cmode" "${files[@]}"
    plan="$(jq -c '.operatorValues = true' <<<"$plan")"
  fi
  if [[ -n "$opm_files" ]]; then
    mapfile -t files < <(split_paths "$opm_files")
    [[ "$cmode" == "remove" ]] || for f in "${files[@]}"; do check_operator_manifest_file "$f" "$c"; done
    apply_mode ".clusters[\"${c}\"].operator.patches.manifests" "$cmode" "${files[@]}"
    plan="$(jq -c --argjson o "$old_manifests" '.operatorManifests = true | .oldManifests = $o' <<<"$plan")"
  fi

  # ---- instances
  for i in $(jq -r --arg c "$c" '.[] | select(.name == $c) | .instances[].name' <<<"$inv"); do
    pg_files="$(cmap_ival "$c" "$i" postgresPatchFilePath "${P_POSTGRES_PATCH:-}")"
    val_files="$(cmap_ival "$c" "$i" valuesPatchFilePath "${P_VALUES_PATCH:-}")"
    [[ -n "$pg_files$val_files" ]] || continue
    if ! g="$(cmap_guard "$c" "$i")"; then
      record_entry "result.${c}.${i}" SKIPPED_VERSION_MISMATCH "" "$g"
      continue
    fi
    imode="$(cmap_ival "$c" "$i" patchMode "${P_PATCH_MODE:-append}")"
    if [[ -n "$pg_files" ]]; then
      mapfile -t files < <(split_paths "$pg_files")
      [[ "$imode" == "remove" ]] || for f in "${files[@]}"; do check_postgres_file "$f" "$c" "$i"; done
      rel=(); for f in "${files[@]}"; do rel+=("${f#"$CHART_PREFIX"}"); done
      apply_mode ".clusters[\"${c}\"].instances[\"${i}\"].patches.postgres" "$imode" "${rel[@]}"
    fi
    if [[ -n "$val_files" ]]; then
      mapfile -t files < <(split_paths "$val_files")
      [[ "$imode" == "remove" ]] || for f in "${files[@]}"; do check_values_file "$f" "$c" "$i"; done
      rel=(); for f in "${files[@]}"; do rel+=("${f#"$CHART_PREFIX"}"); done
      apply_mode ".clusters[\"${c}\"].instances[\"${i}\"].patches.values" "$imode" "${rel[@]}"
    fi
    plan="$(jq -c --arg i "$i" '.instances += [$i]' <<<"$plan")"
  done
  prune_empty "$c"
  C_ERRS+=("${file_errors[@]}")

  # ---- dry run on the target with the new fleet.yaml
  if [[ "${#C_ERRS[@]}" -eq 0 ]]; then
    for i in $(jq -r '.instances[]' <<<"$plan"); do
      if ! out="$(instance_render "$REPO" "$c" "$i" 2>&1)"; then
        C_ERRS+=("${i}: the chart does not render: $(tail -n 3 <<<"$out" | tr '\n' ' ')"); continue
      fi
      docs="$(yq 'select(.kind == "Postgres" or .kind == "PostgresBackupLocation")' <<<"$out")"
      if ! dr="$(tk -n "pg-${i}" apply --server-side --dry-run=server --field-manager=argocd-controller \
          --force-conflicts -f - <<<"$docs" 2>&1)"; then
        C_ERRS+=("${i}: the API server rejects the patched instance: $(tr '\n' ' ' <<<"$dr" | cut -c1-400)")
      fi
    done
    if [[ "$(jq -r '.operatorValues' <<<"$plan")" == "true" ]]; then
      opv="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$F")"
      vf=(); while IFS= read -r f; do [[ -n "$f" ]] && vf+=(-f "$REPO/$f"); done \
        < <(C="$c" yq -r '.clusters[strenv(C)].operator.patches.values // [] | .[]' "$F")
      host="tanzu-sql-postgres.packages.broadcom.com"
      if ! out="$(vault_secret broadcom-registry password \
          | helm registry login "$host" --username "$(vault_secret broadcom-registry username)" --password-stdin 2>&1 \
          && helm template tpg-operator "oci://${host}/vmware-sql-postgres-operator" --version "$opv" \
               --namespace "$OPERATOR_NS" --set dockerRegistrySecretName=regsecret "${vf[@]}" 2>&1)"; then
        C_ERRS+=("operator values: the operator chart ${opv} does not render with the value files: $(tail -n 3 <<<"$out" | tr '\n' ' ')")
      else
        docs="$(yq 'select(.kind == "Deployment")' <<<"$out")"
        if [[ -n "$docs" ]] && ! dr="$(tk -n "$OPERATOR_NS" apply --server-side --dry-run=server \
            --field-manager=argocd-controller --force-conflicts -f - <<<"$docs" 2>&1)"; then
          C_ERRS+=("operator values: the API server rejects the operator Deployment: $(tr '\n' ' ' <<<"$dr" | cut -c1-400)")
        fi
      fi
    fi
    if [[ "$(jq -r '.operatorManifests' <<<"$plan")" == "true" ]]; then
      if ! operator_patches_apply "$REPO" "$c" --dry-run --old "$(jq -r '.oldManifests | join(" ")' <<<"$plan")"; then
        C_ERRS+=("operator manifests: ${OPERATOR_PATCH_DETAIL}")
      fi
    fi
  fi

  if [[ "${#C_ERRS[@]}" -gt 0 ]]; then
    cp "$WORK/fleet.cluster.bak" "$F"   # leave the cluster as it was
    record_entry "precheck.${c}" BLOCKED PATCH_REFUSED "$(printf '%s; ' "${C_ERRS[@]}")"
    for i in $(jq -r '.instances[]' <<<"$plan"); do record_entry "result.${c}.${i}" FAILED PATCH_REFUSED "see precheck.${c}"; done
    any_blocked=1
    continue
  fi
  record_entry "precheck.${c}" PASSED "" "instances: $(jq -r '.instances | join(",")' <<<"$plan"); operator values: $(jq -r '.operatorValues' <<<"$plan"); operator manifests: $(jq -r '.operatorManifests' <<<"$plan")"
  record_entry "plan.${c}" PLANNED "" "$plan"
done

changes="$(diff -u "$WORK/fleet.before.yaml" "$F" | tail -n +3 || true)"
[[ -z "$changes" ]] || { log "clusters/fleet.yaml changes:"; printf '%s\n' "$changes" >&2; }
blocked_note=""; [[ "$any_blocked" -eq 0 ]] || blocked_note="; some clusters are BLOCKED (see the pre-check)"
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record result.git SUCCEEDED DRY_RUN "$(grep -c '^[+-]' <<<"$changes" || true) changed lines, not pushed; every dry run passed where not BLOCKED${blocked_note}"
  exit 0
fi
if [[ -z "$changes" ]]; then
  record result.git SUCCEEDED NO_CHANGE "clusters/fleet.yaml already references these patch files; the targets are synced and verified again${blocked_note}"
  exit 0
fi
git_commit_push "$REPO" "patch: $(jq -r 'map(.name) | join(",")' <<<"$inv") mode=${P_PATCH_MODE:-append} (${WF})" "$FLEET_REL" \
  || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
record_entry revision SET "" "${PUSHED_REVISION:-}"
appset_refresh tpg-operator
appset_refresh tpg-instances
record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} ${PUSHED_REVISION:0:12} $(cat /tmp/pull-request 2>/dev/null || true)${blocked_note}"
