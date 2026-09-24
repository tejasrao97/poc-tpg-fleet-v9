#!/usr/bin/env bash
# postgres-upgrade.sh WORKFLOW_NAME CLUSTER TARGET_VERSION INSTANCES TIMEOUT_SECONDS
# tpg-upgrade component=postgres: upgrade Postgres instances on one cluster with
# PostgresVersionUpgrade. INSTANCES is all or a comma-separated list.
# With clusterMap, each instance's postgresVersion, preUpgradeBackup and
# allowMajor come from the map; TARGET_VERSION (targetVersion, may be empty) and
# the inputs are their defaults.
# Minor or major is detected per instance; a major upgrade needs P_ALLOW_MAJOR=true
# and a Succeeded backup from the last 26 hours (P_PRE_BACKUP=true takes one first).
# After the upgrade, clusters.<cluster>.instances.<instance>.instance.postgresVersion is
# written to clusters/fleet.yaml (PUSH_MODE direct | pr) and the Application is synced.
# P_DRY_RUN=true records the plan per instance and changes nothing.
# Records result.<cluster>.<instance>. Exits 1 if any instance FAILED.
WF="$1"; C="$2"; SELECTED="$4"; TIMEOUT="$5"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
DEFAULT_TARGET=""; [[ -z "$3" ]] || DEFAULT_TARGET="$(norm_postgres_version "$3")"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
[[ "$SELECTED" == "all" ]] || SELECTED="$(split_list "$SELECTED" | paste -sd,)"
DRY="${P_DRY_RUN:-false}"

use_cluster "$C" || { record "result.${C}" FAILED NOT_REGISTERED; exit 1; }
result_guard "result.${C}"
any_failed=0

wanted() { [[ "$SELECTED" == "all" ]] || [[ ",${SELECTED}," == *",$1,"* ]]; }

# done-fn for pods_watch: 0 when the PostgresVersionUpgrade Succeeded, 3 when it failed
_PVU_NS="" _PVU_NAME=""
# shellcheck disable=SC2317  # called indirectly by pods_watch --done-fn
_pvu_finished() {
  local phase
  phase="$(tk -n "$_PVU_NS" get postgresversionupgrade "$_PVU_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  printf 'PostgresVersionUpgrade %s: phase %s' "$_PVU_NAME" "${phase:-<none>}"
  case "$phase" in
    Succeeded) return 0 ;;
    PreCheckFailed|Failed) return 3 ;;
    *) return 1 ;;
  esac
}

upgrade_one() {
  local i="$1" ns="pg-$1" key="result.${C}.$1" cur cur_major b phase name start j stamp TYPE dbv spec_v spec_wait
  local TARGET target_major target_num ALLOW_MAJOR PRE_BACKUP
  ifail() { record "$key" FAILED "$1" "${2:-}"; any_failed=1; }
  TARGET="$(cmap_ival "$C" "$i" postgresVersion "$DEFAULT_TARGET")"
  [[ -n "$TARGET" ]] || { record "$key" SKIPPED_NOT_SELECTED "" "no postgresVersion for ${i}"; return; }
  target_major="$(major_of "$TARGET")"
  target_num="$(sed -E 's/^[^0-9]*//' <<<"$TARGET")"
  ALLOW_MAJOR="$(cmap_ival "$C" "$i" allowMajor "${P_ALLOW_MAJOR:-false}")"
  PRE_BACKUP="$(cmap_ival "$C" "$i" preUpgradeBackup "${P_PRE_BACKUP:-true}")"

  if ! tk get postgresversion "$TARGET" >/dev/null 2>&1; then ifail VERSION_NOT_AVAILABLE "$TARGET"; return; fi
  cur="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.spec.postgresVersion.name}' 2>/dev/null || true)"
  [[ -n "$cur" ]] || cur="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.status.dbVersion}' 2>/dev/null || true)"
  [[ -n "$cur" ]] || { ifail INSTANCE_NOT_FOUND; return; }
  if [[ "$cur" == "$TARGET" ]]; then record "$key" SUCCEEDED ALREADY_AT_TARGET "$TARGET"; return; fi
  cur_major="$(major_of "$cur")"
  TYPE=minor
  if (( target_major > cur_major )); then
    TYPE=major
    [[ "$ALLOW_MAJOR" == "true" ]] || { ifail MAJOR_UPGRADE_NOT_ALLOWED "$cur -> $TARGET is a major upgrade: set allowMajor=true"; return; }
  elif (( target_major < cur_major )); then
    ifail DOWNGRADE_NOT_SUPPORTED "$cur -> $TARGET"; return
  elif [[ "$(printf '%s\n%s\n' "${cur#postgres-}" "${TARGET#postgres-}" | sort -V | tail -n1)" != "${TARGET#postgres-}" ]]; then
    ifail DOWNGRADE_NOT_SUPPORTED "$cur -> $TARGET"; return
  fi

  if [[ "$(pg_state "$i")" != "Running" ]]; then record "$key" SKIPPED_NOT_RUNNING "$(pg_state "$i")"; return; fi

  busy() {
    b="$(latest_cr postgresbackup "$ns" ".spec.sourceInstance.name == \"$i\"")"
    [[ -n "$b" ]] && [[ "$(jq -r '.status.phase // ""' <<<"$b")" =~ ^(|Pending|Running)$ ]]
  }
  if busy; then
    sleep 120
    if busy; then record "$key" SKIPPED_IN_PROGRESS "backup $(jq -r '.metadata.name' <<<"$b") in progress"; return; fi
  fi

  if [[ "$DRY" == "true" ]]; then
    record "$key" SUCCEEDED DRY_RUN "would run a ${TYPE} upgrade ${cur} -> ${TARGET}; preUpgradeBackup=${PRE_BACKUP}" "$cur"
    return
  fi

  if [[ "$PRE_BACKUP" == "true" ]]; then
    RESULT_KEY="backup.${C}.${i}" bash /scripts/backup-instance.sh "$WF" "$C" "$i" full "$TIMEOUT"
    case "$(run_data "backup.${C}.${i}" | jq -r '.status')" in
      SUCCEEDED) ;;
      *) ifail PRE_UPGRADE_BACKUP_FAILED "$(run_data "backup.${C}.${i}" | jq -r '.status + " " + .reason + " " + .detail')"; return ;;
    esac
  fi

  if [[ "$TYPE" == "major" ]]; then
    [[ -n "$(tk -n "$ns" get postgres "$i" -o jsonpath='{.spec.backupLocation.name}')" ]] || { ifail NO_BACKUP_LOCATION; return; }
    recent="$(tk -n "$ns" get postgresbackup -o json | jq -r --arg i "$i" '
      [.items[] | select(.spec.sourceInstance.name == $i and .status.phase == "Succeeded" and .status.timeCompleted != null)
       | select((now - (.status.timeCompleted | fromdateiso8601)) < 93600)] | length')"
    [[ "$recent" -gt 0 ]] || { ifail NO_RECENT_BACKUP "no Succeeded backup in the last 26 hours"; return; }
  fi

  stamp="$(date -u +%Y%m%d%H%M)"
  name="${i}-to-$(tr '._' '--' <<<"$TARGET")-${stamp}"
  log "creating PostgresVersionUpgrade ${ns}/${name}"
  tk -n "$ns" apply -f - >/dev/null <<YAML || { ifail CREATE_FAILED; return; }
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresVersionUpgrade
metadata:
  name: ${name}
  annotations:
    postgres.database/acknowledge-no-backup: "false"
  labels:
    tpg.fleet/workflow: ${WF}
spec:
  postgresInstance:
    name: ${i}
  postgresVersion:
    name: ${TARGET}
YAML

  # Follow the upgrade with the instance pods printed every 5 seconds: the
  # operator replaces the pods with the new image, and a pod that cannot start
  # stops the wait at once instead of after the timeout.
  _PVU_NS="$ns"; _PVU_NAME="$name"
  local wrc=0
  pods_watch "$ns" "$TIMEOUT" --selector "postgres-instance=${i}" --kubectl tk \
    --label "PostgresVersionUpgrade ${name}" --done-fn _pvu_finished || wrc=$?
  j="$(tk -n "$ns" get postgresversionupgrade "$name" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$j")"
  case "$wrc/$phase" in
    0/Succeeded) ;;
    */PreCheckFailed|*/Failed)
      ifail "UPGRADE_${phase^^}" "$(tk -n "$ns" describe postgresversionupgrade "$name" | tail -n 15 | tr '\n' ' ')"
      return ;;
    1/*) ifail "${POD_WATCH_REASON}_DURING_UPGRADE" "$POD_WATCH_DETAIL (PostgresVersionUpgrade phase ${phase:-none})"; return ;;
    *) record "$key" TIMEOUT "" "phase=${phase:-none}${POD_WATCH_DETAIL:+; ${POD_WATCH_DETAIL}}"; any_failed=1; return ;;
  esac

  pg_wait_ready "$i" 1800 || { ifail "${POD_WATCH_REASON:-NOT_RUNNING}_AFTER_UPGRADE" "$POD_WATCH_DETAIL"; return; }
  dbv="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.status.dbVersion}')"
  [[ "$dbv" == "$target_num"* ]] || { ifail DB_VERSION_MISMATCH "status.dbVersion=${dbv}, expected ${target_num}"; return; }

  # The PostgresVersionUpgrade owns spec.postgresVersion.name of the running
  # instance. Wait for the operator to write the target version there before Git
  # and Argo CD are touched. The tpg-instances ApplicationSet ignores that field
  # (ignoreDifferences + RespectIgnoreDifferences), so the sync below never tries
  # to change the version of a running instance; the admission webhook rejected
  # such a change ("postgresVersion.name cannot be changed to use a different
  # major version") while the operator was still finishing the upgrade.
  spec_wait="${P_SPEC_WAIT_SECONDS:-300}"
  start="$(date +%s)"
  while true; do
    spec_v="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.spec.postgresVersion.name}' 2>/dev/null || true)"
    if [[ "$spec_v" == "$TARGET" ]]; then
      log "${i}: spec.postgresVersion.name is ${TARGET}"
      break
    fi
    if (( $(date +%s) - start >= spec_wait )); then
      log "${i}: the operator left spec.postgresVersion.name at ${spec_v:-<empty>} after ${spec_wait}s; status.dbVersion is ${dbv}. Argo CD ignores this field, so Git records ${TARGET} without applying it"
      break
    fi
    log "${i}: waiting for the operator to set spec.postgresVersion.name to ${TARGET} (now ${spec_v:-<empty>})"
    sleep 5
  done

  # Keep Git in line with the cluster, then sync the instance Application at that commit
  C="$C" I="$i" TARGET="$TARGET" yq -i '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion = strenv(TARGET)' "$WORK/repo/$FLEET_REL"
  git_commit_push "$WORK/repo" "postgres ${C}/${i} ${cur} -> ${TARGET} (${WF})" "$FLEET_REL" || { ifail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; return; }
  local rc=0
  sync_instance_app "$C" "$i" "$TIMEOUT" "${PUSHED_REVISION:-}" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # The database is upgraded, but Git and the cluster are not reconciled: the
    # result is FAILED so later batches stop and the report says why.
    ifail "$SYNC_FAIL_REASON" "database upgraded to ${dbv}, but the Application did not sync: ${SYNC_FAIL_DETAIL}"
    return
  fi
  record "$key" SUCCEEDED "" "${TYPE} upgrade, dbVersion ${dbv}" "$cur"
}

git_clone "$WORK/repo"
if [[ "$SELECTED" != "all" ]]; then
  for i in $(split_list "$SELECTED"); do
    inventory_instances "$C" | grep -qx "$i" || { record "result.${C}.${i}" FAILED UNKNOWN_INSTANCE "not declared for ${C} in ${FLEET_REL}"; any_failed=1; }
  done
fi
for i in $(inventory_instances "$C"); do
  if ! wanted "$i"; then
    record "result.${C}.${i}" SKIPPED_NOT_SELECTED "" "instances=${SELECTED}"
    continue
  fi
  upgrade_one "$i"
done
exit "$any_failed"
