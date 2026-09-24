#!/usr/bin/env bash
# restore.sh WORKFLOW_NAME
# Restore one Postgres instance with a PostgresRestore. Inputs come from P_*
# environment variables (validated by validate-params.sh restore):
#   P_SOURCE_CLUSTER   cluster that holds the source instance
#   P_INSTANCE         source instance name (namespace pg-<instance>)
#   P_MODE             time | latest | backup | lsn | xid
#   P_TARGET           mode time: UTC timestamp; backup: PostgresBackup name;
#                      lsn/xid: the LSN or transaction ID; latest: empty
#   P_TARGET_CLUSTER   target cluster (empty: the source cluster)
#   P_TARGET_INSTANCE  target instance (empty: <instance>-restore-<yyyymmddhhmm>;
#                      equal to the source: in-place, destructive)
#   P_CONFIRM          must equal the target instance name when that instance exists
#   P_BEST_EFFORT      pitr bestEffort
#   P_PUSH_MODE        direct | pr, for the fleet.yaml entry of a cross-cluster restore
#   P_TIMEOUT          seconds to wait for the restore
#
# Same cluster, new instance: a one-off clone in the source namespace, not managed
# by Argo CD (delete it when the validation is done).
# Another cluster, new instance: the instance is added to clusters/fleet.yaml with
# the source instance's settings, its own backup location (pg-backups-<target cluster>)
# and Secrets from Vault, and the Argo CD Application adopts it after the restore.
# Cross-namespace (other cluster, or an existing instance in another namespace):
# a read-only copy of the source backup location is created in the target namespace
# (backupSync then lists the source backups there). The copy is kept, labelled
# tpg.fleet/restore-source=<source cluster>/<instance>: deleting it is a manual step
# (see docs/workflow-commands.md) because deleting a backup location removes the
# synced PostgresBackup objects of the source repository.
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

SRC_C="${P_SOURCE_CLUSTER}"
# shellcheck disable=SC2153  # P_INSTANCE (one instance), not P_INSTANCES of lib.sh
I="${P_INSTANCE}"
MODE="${P_MODE}"; TARGET="${P_TARGET:-}"
DST_C="${P_TARGET_CLUSTER:-$SRC_C}"; T="${P_TARGET_INSTANCE:-}"; CONFIRM="${P_CONFIRM:-}"
BEST="${P_BEST_EFFORT:-false}"; TIMEOUT="${P_TIMEOUT:-7200}"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
key="result.${DST_C}"
SRC_NS="pg-${I}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
[[ -n "$T" ]] || T="${I}-restore-$(date -u +%Y%m%d%H%M)"
DST_NS="pg-${T}"
IN_PLACE=false
[[ "$DST_C" == "$SRC_C" && "$T" == "$I" ]] && IN_PLACE=true

# ---- 1. source instance: version, backup location, stanza and recovery window
use_cluster "$SRC_C" || fail NOT_REGISTERED "$SRC_C"
tk -n "$SRC_NS" get postgres "$I" >/dev/null 2>&1 || fail INSTANCE_NOT_FOUND "${SRC_C}: ${SRC_NS}/${I}"
BL="$(tk -n "$SRC_NS" get postgres "$I" -o jsonpath='{.spec.backupLocation.name}')"
STANZA="$(tk -n "$SRC_NS" get postgres "$I" -o jsonpath='{.status.stanzaName}')"
PGV="$(tk -n "$SRC_NS" get postgres "$I" -o jsonpath='{.spec.postgresVersion.name}')"
[[ -n "$BL" && -n "$STANZA" ]] || fail BACKUP_LOCATION_NOT_INITIALIZED "${SRC_NS}/${I} has no stanza yet"
SRC_CONTAINER="$(tk -n "$SRC_NS" get postgresbackuplocation "$BL" -o jsonpath='{.spec.storage.azure.container}')"
SRC_REPO_PATH="$(tk -n "$SRC_NS" get postgresbackuplocation "$BL" -o jsonpath='{.spec.storage.azure.repoPath}')"
SRC_ENDPOINT="$(tk -n "$SRC_NS" get postgresbackuplocation "$BL" -o jsonpath='{.spec.storage.azure.endpoint}')"
# enableSSL of the source location (absent reads as false, as the operator does)
SRC_SSL="$(tk -n "$SRC_NS" get postgresbackuplocation "$BL" -o jsonpath='{.spec.storage.azure.enableSSL}')"
[[ "$SRC_SSL" == "true" ]] || SRC_SSL=false

oldest="$(tk -n "$SRC_NS" get postgresbackup -o json | jq -r --arg i "$I" '
  [.items[] | select(.spec.sourceInstance.name == $i and .spec.type == "full"
   and .status.phase == "Succeeded" and .status.timeStarted != null)
   | .status.timeStarted | fromdateiso8601] | min // empty')"
[[ -n "$oldest" ]] || fail NO_FULL_BACKUP "no Succeeded full backup of ${I} on ${SRC_C}"
case "$MODE" in
  time)
    target_epoch="$(jq -rn --arg t "$TARGET" '$t | fromdateiso8601')" || fail INVALID_TIMESTAMP "$TARGET"
    (( target_epoch < $(date +%s) )) || fail INVALID_TIMESTAMP "targetTime is in the future"
    (( target_epoch > oldest )) || fail OUTSIDE_RECOVERY_WINDOW "targetTime is older than the oldest full backup ($(date -u -d "@${oldest}" +%Y-%m-%dT%H:%M:%SZ))"
    ;;
  backup)
    tk -n "$SRC_NS" get postgresbackup "$TARGET" >/dev/null 2>&1 \
      || fail BACKUP_NOT_FOUND "${SRC_NS}/${TARGET} on ${SRC_C}"
    [[ "$(tk -n "$SRC_NS" get postgresbackup "$TARGET" -o jsonpath='{.status.phase}')" == "Succeeded" ]] \
      || fail BACKUP_NOT_SUCCEEDED "$TARGET"
    ;;
esac

# ---- 2. target cluster and namespace
FLEET_ADDED=false
if [[ "$DST_C" != "$SRC_C" ]]; then
  git_clone "$WORK/repo"
  fleet_has_cluster "$WORK/repo" "$DST_C" || fail UNKNOWN_TARGET_CLUSTER "no clusters.${DST_C} in ${FLEET_REL} (run tpg-day0 for it first)"
fi
use_cluster "$DST_C" || fail NOT_REGISTERED "$DST_C"
TARGET_EXISTS=false
tk -n "$DST_NS" get postgres "$T" >/dev/null 2>&1 && TARGET_EXISTS=true
if [[ "$TARGET_EXISTS" == "true" || "$IN_PLACE" == "true" ]]; then
  [[ "$CONFIRM" == "$T" ]] || fail CONFIRMATION_MISMATCH "restoring into the existing instance ${DST_C}/${T} overwrites its data: set confirm=${T}"
fi
if [[ "$DST_C" != "$SRC_C" && "$TARGET_EXISTS" == "false" ]]; then
  # New instance on another cluster: declare it in Git first, then render the
  # Secrets and backup location the Application will manage, so the restored
  # instance is adopted by Argo CD afterwards.
  SRC="$SRC_C" DST="$DST_C" OLD="$I" NEW="$T" yq -i '
    .clusters[strenv(DST)].instances[strenv(NEW)] = .clusters[strenv(SRC)].instances[strenv(OLD)]' \
    "$WORK/repo/$FLEET_REL" || fail FLEET_EDIT_FAILED "${FLEET_REL}"
  git_commit_push "$WORK/repo" "restore: add ${DST_C}/${T} from ${SRC_C}/${I} (${WF})" "$FLEET_REL" \
    || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"
  FLEET_ADDED=true
  tk create namespace "$DST_NS" --dry-run=client -o yaml | tk apply -f - >/dev/null
  tk label namespace "$DST_NS" tpg.fleet/managed=true --overwrite >/dev/null
  # Secrets (Vault) and the target's own backup location, rendered from the chart
  values="$(C="$DST_C" I2="$T" yq -o=json '.clusters[strenv(C)].instances[strenv(I2)]
    * {"cluster": {"name": strenv(C)}, "instance": {"name": strenv(I2)},
       "backup": {"container": ("pg-backups-" + strenv(C))}}' "$WORK/repo/$FLEET_REL")"
  printf '%s' "$values" > "$WORK/target-values.yaml"
  helm template "$T" "$WORK/repo/charts/tpg-instance" \
    -f "$WORK/repo/$TEMPLATE_CLUSTER_REL" -f "$WORK/repo/$TEMPLATE_INSTANCE_REL" -f "$WORK/target-values.yaml" \
    --namespace "$DST_NS" > "$WORK/target-render.yaml" || fail CHART_RENDER_FAILED "$T"
  yq 'select(.kind != "Postgres")' "$WORK/target-render.yaml" | tk -n "$DST_NS" apply -f - >/dev/null \
    || fail TARGET_PREPARE_FAILED "Secrets and backup location in ${DST_NS}"
  for sec in regsecret backup-storage; do
    okk=""
    for _ in $(seq 1 30); do
      tk -n "$DST_NS" get secret "$sec" >/dev/null 2>&1 && { okk=1; break; }
      sleep 10
    done
    [[ -n "$okk" ]] || fail SECRET_NOT_SYNCED "${DST_NS}/${sec} from Vault"
  done
fi

# ---- 3. source backup location copy for a cross-namespace restore
SRC_BL="$BL"
NOTES=()
join_notes() {  # the notes of this run as one "a; b; c" line (empty when there are none)
  local out="" n
  for n in "${NOTES[@]:-}"; do [[ -n "$n" ]] || continue; out="${out:+${out}; }${n}"; done
  printf '%s' "$out"
}
if [[ "$DST_NS" != "$SRC_NS" || "$DST_C" != "$SRC_C" ]]; then
  SRC_BL="restore-src-${SRC_C}-${I}"
  [[ "${#SRC_BL}" -le 253 ]] || SRC_BL="restore-src-$(printf '%s-%s' "$SRC_C" "$I" | cksum | cut -d' ' -f1)"
  tk -n "$DST_NS" apply -f - >/dev/null <<YAML || fail SOURCE_LOCATION_FAILED "$SRC_BL"
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresBackupLocation
metadata:
  name: ${SRC_BL}
  namespace: ${DST_NS}
  labels:
    tpg.fleet/restore-source: ${SRC_C}.${I}
    tpg.fleet/managed: "true"
  annotations:
    tpg.fleet/created-by: "${WF}"
spec:
  # Read-only use: the retention numbers are deliberately high so that no
  # expiry ever runs against the source repository through this copy.
  retentionPolicy:
    fullRetention:
      type: count
      number: 9999999
    diffRetention:
      number: 9999999
  storage:
    azure:
      container: "${SRC_CONTAINER}"
      repoPath: "${SRC_REPO_PATH}"
      endpoint: "${SRC_ENDPOINT}"
      keyType: "shared"
      enableSSL: ${SRC_SSL}
      secret:
        name: backup-storage
  # forcePathStyle: false and additionalParameters: {} are deliberately absent.
  # The CRD serializes both with omitempty, so the API server stores neither and
  # the object read back never matches what was applied. This copy is not
  # managed by Argo CD, but it is compared with the source location by hand, and
  # the instance chart leaves them out for the same reason.
  backupSync:
    enabled: true
  backupIntegrityValidation:
    enabled: true
YAML
  NOTES+=("source backup location ${DST_NS}/${SRC_BL} kept (delete it by hand when the restore is validated)")
  if [[ "$MODE" == "backup" ]]; then
    fail UNSUPPORTED_COMBINATION "mode=backup restores only inside the source namespace; use time, latest, lsn or xid for a cross-namespace restore"
  fi
  # Wait until the synced backups of the source repository appear
  synced=""
  for _ in $(seq 1 30); do
    n="$(tk -n "$DST_NS" get postgresbackup -o json 2>/dev/null | jq '[.items[] | select(.metadata.labels["sql.tanzu.vmware.com/recovered-from-backuplocation"] == "true")] | length')"
    [[ "${n:-0}" -gt 0 ]] && { synced="$n"; break; }
    sleep 20
  done
  [[ -n "$synced" ]] || fail BACKUPS_NOT_SYNCED "no backups appeared in ${DST_NS} from ${SRC_BL} (backupSync)"
  NOTES+=("${synced} backups synced from the source repository")
fi

# ---- 4. PostgresRestore
in_progress() {
  local r
  r="$(latest_cr postgresrestore "$DST_NS" ".spec.targetInstance.name == \"${T}\"")"
  [[ -n "$r" ]] || return 1
  case "$(jq -r '.status.phase // ""' <<<"$r")" in
    Succeeded|Failed) return 1 ;;
    *) printf '%s' "$r"; return 0 ;;
  esac
}
if in_progress >/dev/null; then
  log "a restore of ${T} is still in progress, waiting 2 minutes"
  sleep 120
  if R="$(in_progress)"; then
    record "$key" SKIPPED_IN_PROGRESS "" "$(jq -r '.metadata.name + " phase " + (.status.phase // "Pending")' <<<"$R")"
    exit 0
  fi
fi

NAME="${T}-restore-$(date -u +%Y%m%d%H%M%S)"
{
  printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresRestore\nmetadata:\n  name: %s\n  labels:\n    tpg.fleet/workflow: %s\nspec:\n' "$NAME" "$WF"
  if [[ "$MODE" == "backup" ]]; then
    printf '  sourceBackup:\n    name: %s\n' "$TARGET"
  else
    printf '  pitr:\n    type: %s\n' "$( [[ "$MODE" == "xid" ]] && echo transaction || echo "$MODE" )"
    case "$MODE" in
      time) printf '    timestamp: "%s"\n' "$TARGET" ;;
      lsn|xid) printf '    target: "%s"\n' "$TARGET" ;;
    esac
    printf '    bestEffort: %s\n    sourceBackupLocation:\n      name: %s\n      stanzaName: %s\n' "$BEST" "$SRC_BL" "$STANZA"
  fi
  printf '  targetInstance:\n    name: %s\n' "$T"
  if [[ "$TARGET_EXISTS" == "false" ]]; then
    if [[ -f "$WORK/target-render.yaml" && "$DST_C" != "$SRC_C" ]]; then
      # The spec the Argo CD Application will manage, so the restored instance matches Git
      yq 'select(.kind == "Postgres") | {"spec": .spec}' "$WORK/target-render.yaml" | sed 's/^/    /'
    else
      printf '    spec:\n      postgresVersion:\n        name: %s\n' "$PGV"
    fi
  fi
} > "$WORK/restore.yaml"
log "creating PostgresRestore ${DST_NS}/${NAME} (mode ${MODE}${TARGET:+ ${TARGET}}) -> ${DST_C}/${T}"
tk -n "$DST_NS" apply -f "$WORK/restore.yaml" >/dev/null || fail CREATE_FAILED "$NAME"

start="$(date +%s)"
while true; do
  j="$(tk -n "$DST_NS" get postgresrestore "$NAME" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$j")"
  case "$phase" in
    Succeeded) break ;;
    Failed) fail RESTORE_FAILED "$(jq -r '[.status.conditions[]?.message] | join("; ")' <<<"$j" | tr '\n' ' ')" ;;
  esac
  if (( $(date +%s) - start > TIMEOUT )); then
    notes="$(join_notes)"
    record "$key" TIMEOUT "" "${NAME} phase=${phase:-none}${notes:+; ${notes}}"
    exit 0
  fi
  log "PostgresRestore ${DST_NS}/${NAME}: phase ${phase:-<none>} ($(( $(date +%s) - start ))s); pods: $(tk -n "$DST_NS" get pods --no-headers 2>/dev/null \
    | awk '{printf "%s%s=%s %s", (n++ ? ", " : ""), $1, $3, $2}')"
  sleep 30
done

pg_wait_ready "$T" 1800 || fail "TARGET_${POD_WATCH_REASON:-NOT_RUNNING}" "$T: ${POD_WATCH_DETAIL}"

# ---- 5. hand the new instance to Argo CD (cross-cluster restores)
if [[ "$FLEET_ADDED" == "true" ]]; then
  if sync_instance_app "$DST_C" "$T" "$TIMEOUT" "${PUSHED_REVISION:-}"; then
    NOTES+=("Application tpg-${DST_C}-${T} synced: the instance is managed by Argo CD")
  else
    NOTES+=("Application tpg-${DST_C}-${T} did not sync (${SYNC_FAIL_REASON}: ${SYNC_FAIL_DETAIL}): check it in Argo CD")
  fi
elif [[ "$TARGET_EXISTS" == "false" ]]; then
  NOTES+=("not managed by Argo CD: delete ${DST_NS}/${T} after the validation, or add it to clusters/fleet.yaml")
fi
notes="$(join_notes)"
record "$key" SUCCEEDED "" "restored ${SRC_C}/${I} into ${DST_C}/${DST_NS}/${T} (mode ${MODE}${TARGET:+ ${TARGET}})${notes:+; ${notes}}"
