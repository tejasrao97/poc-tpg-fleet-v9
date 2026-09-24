#!/usr/bin/env bash
# delete-instance.sh WORKFLOW CLUSTER INSTANCE CONFIRM FINAL_BACKUP PURGE_PVCS PURGE_NAMESPACE TIMEOUT
# Guarded delete of one Postgres instance (README: Day 2: delete).
#   1 guards      confirm == instance, instance declared in clusters/fleet.yaml (ALLOW_UNTRACKED=true:
#                 may be missing there), no backup/restore/upgrade in progress
#   2 backup      final full backup when the instance is Running (finalBackup: true|false|required)
#   3 Git         remove clusters.<cluster>.instances.<instance> from clusters/fleet.yaml and keep
#                 a copy in clusters/deleted/<cluster>/<instance>-<time>.yaml (PUSH_MODE direct | pr);
#                 the ApplicationSet removes the Application without touching resources
#   4 delete      Postgres CR (operator removes pods, services, secrets) and backup location CR
#   5 purge       optional: PVCs and their Retain PVs/disks; optional: the namespace
# The Azure Blob backup repository is never deleted by this workflow.
# DELETE_FROM_MAP=true (tpg-delete-instance, tpg-delete-apps): finalBackup,
# purgePvcs and purgeNamespace come from clusterMap (P_CLUSTER_MAP) when set for
# the instance, and the clusterMap postgresVersion guard applies.
WF="$1"; C="$2"; I="$3"; CONFIRM="$4"; FINAL_BACKUP="${5:-true}"; PURGE_PVCS="${6:-false}"; PURGE_NS="${7:-false}"; TIMEOUT="${8:-1800}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}.${I}"
NS="pg-${I}"
notes=()
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"

if [[ "${DELETE_FROM_MAP:-false}" == "true" ]]; then
  FINAL_BACKUP="$(cmap_ival "$C" "$I" finalBackup "$FINAL_BACKUP")"
  PURGE_PVCS="$(cmap_ival "$C" "$I" purgePvcs "$PURGE_PVCS")"
  PURGE_NS="$(cmap_ival "$C" "$I" purgeNamespace "$PURGE_NS")"
fi

# ---- 1 guards
[[ "$CONFIRM" == "$I" ]] || fail NOT_CONFIRMED "set confirm=${I}"
[[ "$PURGE_NS" != "true" || "$PURGE_PVCS" == "true" ]] || fail INVALID_OPTIONS "purgeNamespace=true needs purgePvcs=true"
git_clone "$WORK/repo"
fleet_materialize "$WORK/repo"
f="$WORK/fleet/${C}/${I}.yaml"
if [[ ! -f "$f" ]]; then
  if ls "$WORK/repo/clusters/deleted/${C}/${I}-"*.yaml >/dev/null 2>&1; then
    notes+=("instance already removed from fleet.yaml (re-run)")
  elif [[ "${ALLOW_UNTRACKED:-false}" == "true" ]]; then
    notes+=("instance was not declared in fleet.yaml")
  else
    fail UNKNOWN_INSTANCE "no clusters.${C}.instances.${I} in ${FLEET_REL}; declared: $(fleet_instances "$WORK/repo" "$C" | paste -sd, -)"
  fi
fi
use_cluster "$C" || fail NOT_REGISTERED
if [[ "${DELETE_FROM_MAP:-false}" == "true" ]] && ! g="$(cmap_guard "$C" "$I")"; then
  record "$key" SKIPPED_VERSION_MISMATCH "" "$g"
  exit 0
fi
EXISTS=true
tk -n "$NS" get postgres "$I" >/dev/null 2>&1 || EXISTS=false
if [[ "$EXISTS" == "true" ]]; then
  busy="$(busy_operations "$I")"
  [[ -z "$busy" ]] || fail OPERATION_IN_PROGRESS "$busy"
fi

# ---- 2 final backup
if [[ "$EXISTS" == "true" && "$FINAL_BACKUP" != "false" ]]; then
  if [[ "$(pg_state "$I")" == "Running" ]]; then
    bash /scripts/backup-instance.sh "$WF" "$C" "$I" full "$TIMEOUT"
    b="$(run_data "$key")"
    [[ "$(jq -r '.status' <<<"$b")" == "SUCCEEDED" ]] || fail FINAL_BACKUP_FAILED "$(jq -r '.status + " " + .reason + " " + .detail' <<<"$b")"
    notes+=("final backup $(jq -r '.detail' <<<"$b" | cut -d' ' -f1)")
  elif [[ "$FINAL_BACKUP" == "required" ]]; then
    fail FINAL_BACKUP_IMPOSSIBLE "currentState=$(pg_state "$I")"
  else
    notes+=("no final backup: currentState=$(pg_state "$I")")
  fi
fi
stanza="$(tk -n "$NS" get postgres "$I" -o jsonpath='{.status.stanzaName}' 2>/dev/null || true)"

# ---- 3 Git: remove the entry from fleet.yaml, keep a copy for audit and re-creation
if [[ -f "$f" ]]; then
  mkdir -p "$WORK/repo/clusters/deleted/${C}"
  drel="clusters/deleted/${C}/${I}-$(date -u +%Y%m%d%H%M).yaml"
  C="$C" I="$I" yq '.clusters[strenv(C)].instances[strenv(I)]' "$WORK/repo/$FLEET_REL" > "$WORK/repo/$drel"
  W="$WF" T="$(date -u +%Y-%m-%dT%H:%M:%SZ)" S="$stanza" yq -i '.deleted = {"workflow": strenv(W), "time": strenv(T), "stanzaName": strenv(S)}' "$WORK/repo/$drel"
  C="$C" I="$I" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)])' "$WORK/repo/$FLEET_REL"
  rm -rf "$WORK/fleet"   # nothing to write back: the entry is gone
  git_commit_push "$WORK/repo" "delete ${C}/${I} (${WF})" "$FLEET_REL" "$drel" || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE:-direct}"
fi
app="tpg-${C}-${I}"
appset_refresh tpg-instances
for _ in $(seq 1 40); do
  app_exists "$app" || break
  sleep 15
done
app_exists "$app" && fail APPLICATION_NOT_REMOVED "$app still exists; check tpg-instances preserveResourcesOnDeletion"

# ---- 4 delete the database objects
if [[ "$EXISTS" == "true" ]]; then
  tk -n "$NS" delete postgres "$I" --wait=true --timeout="${TIMEOUT}s" >/dev/null || fail DELETE_TIMEOUT "postgres ${I}"
  for _ in $(seq 1 40); do
    [[ "$(tk -n "$NS" get pods -l "postgres-instance=${I}" -o name 2>/dev/null | wc -l)" -eq 0 ]] && break
    sleep 15
  done
fi
tk -n "$NS" delete postgresbackuplocation "${I}-backup-location" --ignore-not-found --wait=true >/dev/null || notes+=("backup location CR not deleted")

# ---- 5 optional purge
pvcs="$(tk -n "$NS" get pvc -o json 2>/dev/null || echo '{"items":[]}')"
count="$(jq '.items | length' <<<"$pvcs")"
if [[ "$PURGE_PVCS" == "true" && "$count" -gt 0 ]]; then
  # Retain StorageClass: switch each bound PV to Delete first so the Azure disk goes too
  for pv in $(jq -r '.items[].spec.volumeName // empty' <<<"$pvcs"); do
    tk patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null || notes+=("pv ${pv} not patched")
  done
  tk -n "$NS" delete pvc --all --wait=true --timeout=600s >/dev/null || fail PVC_DELETE_FAILED
  notes+=("${count} PVCs and disks deleted")
elif [[ "$count" -gt 0 ]]; then
  notes+=("${count} PVCs kept in ${NS} (Retain)")
fi
if [[ "$PURGE_NS" == "true" ]]; then
  tk delete namespace "$NS" --wait=true --timeout=600s >/dev/null || fail NAMESPACE_DELETE_FAILED
  notes+=("namespace ${NS} deleted")
fi
notes+=("backup repository kept: stanza ${stanza:-unknown}")
detail="$(printf '%s; ' "${notes[@]}")"
record "$key" SUCCEEDED "" "${detail%; }"
