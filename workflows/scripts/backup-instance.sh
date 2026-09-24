#!/usr/bin/env bash
# backup-instance.sh WORKFLOW_NAME CLUSTER INSTANCE BACKUP_TYPE TIMEOUT_SECONDS [SCHEDULED] [SCHEDULED_ONLY]
# RESULT_KEY (environment) overrides the result key result.<cluster>.<instance>.
# BACKUP_FROM_MAP=true (tpg-backup): backupType and backupTimeoutSeconds of the
#   instance come from clusterMap (P_CLUSTER_MAP) when set there, and the clusterMap
#   postgresVersion guard applies (SKIPPED_VERSION_MISMATCH).
#   SCHEDULED=false and SCHEDULED_ONLY=true -> SKIPPED_NOT_SCHEDULED (fleet.yaml backup.scheduled: false)
# Guarded backup (design decision D16):
#   previous backup Pending/Running -> wait 2 minutes -> still running -> SKIPPED_IN_PROGRESS
#   instance not Running -> SKIPPED_NOT_RUNNING
#   otherwise create PostgresBackup and wait for Succeeded/Failed/TIMEOUT.
# Always exits 0 after recording, so one instance never blocks the others.
WF="$1"; C="$2"; I="$3"; TYPE="$4"; TIMEOUT="$5"; SCHEDULED="${6:-true}"; SCHEDULED_ONLY="${7:-false}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="${RESULT_KEY:-result.${C}.${I}}"
result_guard "$key"
NS="pg-${I}"
if ! use_cluster "$C"; then record "$key" FAILED NOT_REGISTERED; exit 0; fi
if [[ "${BACKUP_FROM_MAP:-false}" == "true" ]]; then
  TYPE="$(cmap_ival "$C" "$I" backupType "$TYPE")"
  TIMEOUT="$(cmap_ival "$C" "$I" backupTimeoutSeconds "$TIMEOUT")"
  if ! g="$(cmap_guard "$C" "$I")"; then record "$key" SKIPPED_VERSION_MISMATCH "" "$g"; exit 0; fi
fi
if [[ "$SCHEDULED_ONLY" == "true" && "$SCHEDULED" == "false" ]]; then
  record "$key" SKIPPED_NOT_SCHEDULED "" "backup.scheduled is false in clusters/fleet.yaml"
  exit 0
fi
case "$TYPE" in full|differential|incremental) ;; *) record "$key" FAILED INVALID_TYPE "$TYPE"; exit 0 ;; esac

latest() { latest_cr postgresbackup "$NS" ".spec.sourceInstance.name == \"$I\""; }
busy() {
  local b
  b="$(latest)"
  [[ -n "$b" ]] || return 1
  case "$(jq -r '.status.phase // ""' <<<"$b")" in
    ""|Pending|Running) printf '%s' "$b"; return 0 ;;
    *) return 1 ;;
  esac
}

PREV="$(latest | jq -r '.status.phase // "NONE"' 2>/dev/null || echo NONE)"
[[ -n "$PREV" ]] || PREV="NONE"
if busy >/dev/null; then
  log "previous backup still in progress, waiting 2 minutes"
  sleep 120
  if B="$(busy)"; then
    record "$key" SKIPPED_IN_PROGRESS "" \
      "$(jq -r '.metadata.name + " started " + (.status.timeStarted // "unknown")' <<<"$B")" "$PREV"
    exit 0
  fi
fi

STATE="$(pg_state "$I")"
if [[ "$STATE" != "Running" ]]; then
  record "$key" SKIPPED_NOT_RUNNING "" "currentState=${STATE:-none}" "$PREV"
  exit 0
fi

NAME="${I}-${TYPE}-$(date -u +%Y%m%d%H%M)"
if ! tk -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresBackup
metadata:
  name: ${NAME}
  labels:
    tpg.fleet/trigger: argo-workflows
    tpg.fleet/workflow: ${WF}
spec:
  sourceInstance:
    name: ${I}
  type: ${TYPE}
YAML
then
  record "$key" FAILED CREATE_FAILED "$NAME" "$PREV"
  exit 0
fi

start="$(date +%s)"
while true; do
  j="$(tk -n "$NS" get postgresbackup "$NAME" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$j")"
  case "$phase" in
    Succeeded)
      record "$key" SUCCEEDED "" "${NAME} size=$(jq -r '.status.size // "?"' <<<"$j")" "$PREV"
      exit 0 ;;
    Failed)
      record "$key" FAILED BACKUP_FAILED "$NAME $(jq -r '[.status.conditions[]?.message] | join("; ")' <<<"$j")" "$PREV"
      exit 0 ;;
  esac
  if (( $(date +%s) - start > TIMEOUT )); then
    record "$key" TIMEOUT "" "${NAME} phase=${phase:-none}" "$PREV"
    exit 0
  fi
  log "PostgresBackup ${NAME}: phase ${phase:-<none>} ($(( $(date +%s) - start ))s)"
  sleep 30
done
