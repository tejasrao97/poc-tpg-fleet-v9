#!/usr/bin/env bash
# operator-upgrade.sh WORKFLOW_NAME CLUSTER TARGET_VERSION TIMEOUT_SECONDS
# tpg-upgrade component=operator, one cluster:
#   1 guards     every instance Running; no downgrade; nothing to do when already at the target
#   2 backup     optional full backup of every Running instance (P_PRE_BACKUP=true)
#   3 Git        clusters.<cluster>.operator.version in clusters/fleet.yaml (PUSH_MODE direct | pr)
#   4 sync       wait for the ApplicationSet to render the new version, sync, verify operator and instances
# Operator manifest patches (tpg-patch operatorManifestPatchFilePath) and the new
# chart (design decision D56):
#   keep (P_OPERATOR_PATCHES, default): the sync runs once without
#        RespectIgnoreDifferences, so the new chart takes every field back from the
#        tpg-patch field manager and applies cleanly; each patched field whose new
#        chart value differs is reported (warning OPERATOR_PATCH_OVERRIDES), then the
#        patches are applied again and verified.
#   drop: the manifest patch references leave clusters/fleet.yaml in the version
#        commit; after the same clean sync the patched objects are released, and the
#        chart values stay. Operator values patches are chart inputs and are kept.
# P_DRY_RUN=true records the plan and changes nothing.
WF="$1"; C="$2"; TIMEOUT="$4"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
TARGET="$(norm_operator_version "$3")"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

fail() { record "result.${C}" FAILED "$1" "${2:-}"; exit 1; }
result_guard "result.${C}"
use_cluster "$C" || fail NOT_REGISTERED
app="tpg-${C}-operator"
REPO="$WORK/repo"
git_clone "$REPO"
current="$(C="$C" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
[[ -n "$current" ]] || fail NOT_IN_FLEET "clusters.${C}.operator.version is not declared (run tpg-day0)"
if [[ "$current" == "$TARGET" ]]; then
  record "result.${C}" SUCCEEDED ALREADY_AT_TARGET "$TARGET" "$current"
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "${current#v}" "${TARGET#v}" | sort -V | tail -n1)" != "${TARGET#v}" ]]; then
  fail DOWNGRADE_NOT_SUPPORTED "${current} -> ${TARGET}"
fi
for i in $(inventory_instances "$C"); do
  [[ "$(pg_state "$i")" == "Running" ]] || fail INSTANCE_NOT_RUNNING_BEFORE "$i"
done
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record "result.${C}" SUCCEEDED DRY_RUN "would upgrade ${current} -> ${TARGET}; preUpgradeBackup=${P_PRE_BACKUP:-true}$( [[ -z "$(operator_patch_files "$REPO" "$C")" ]] || printf '; manifest patches: %s' "${P_OPERATOR_PATCHES:-keep}")" "$current"
  exit 0
fi

if [[ "${P_PRE_BACKUP:-true}" == "true" ]]; then
  for i in $(inventory_instances "$C"); do
    RESULT_KEY="backup.${C}.${i}" bash /scripts/backup-instance.sh "$WF" "$C" "$i" full "$TIMEOUT"
    b="$(run_data "backup.${C}.${i}")"
    case "$(jq -r '.status' <<<"$b")" in
      SUCCEEDED) ;;
      *) fail PRE_UPGRADE_BACKUP_FAILED "${i}: $(jq -r '.status + " " + .reason + " " + .detail' <<<"$b")" ;;
    esac
  done
fi

TARGET="$TARGET" C="$C" yq -i '.clusters[strenv(C)].operator.version = strenv(TARGET)' "$REPO/$FLEET_REL"
PATCHES_MODE="${P_OPERATOR_PATCHES:-keep}"
old_manifests="$(operator_patch_files "$REPO" "$C" | paste -sd' ')"
if [[ -n "$old_manifests" && "$PATCHES_MODE" == "drop" ]]; then
  C="$C" yq -i 'del(.clusters[strenv(C)].operator.patches.manifests)
    | del(.clusters[strenv(C)].operator | select(.patches == {}) | .patches)' "$REPO/$FLEET_REL"
fi
git_commit_push "$REPO" "operator ${C} ${current} -> ${TARGET}$( [[ -z "$old_manifests" || "$PATCHES_MODE" != drop ]] || printf ', manifest patches dropped') (${WF})" "$FLEET_REL" \
  || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"

appset_refresh tpg-operator
start="$(date +%s)"
until [[ "$(app_target_revision "$app")" == "$TARGET" ]]; do
  (( $(date +%s) - start > 600 )) && fail APPSET_NOT_UPDATED "$app targetRevision"
  log "waiting for the ApplicationSet tpg-operator to render ${TARGET} into ${app} (now $(app_target_revision "$app"))"
  sleep 15
done
# The operator chart comes from the OCI registry, so there is no fleet commit to
# sync to: the Application already carries the new targetRevision.
# The target is checked directly (CRD Established, operator Deployment
# available) instead of waiting for Argo CD to rediscover the CRDs.
sopts=""
# With manifest patches, one sync without RespectIgnoreDifferences hands every
# patched field back to the chart (server-side apply --force-conflicts)
[[ -z "$old_manifests" ]] || sopts="CreateNamespace=true,ServerSideApply=true"
rc=0; app_sync_wait "$app" "$TIMEOUT" --pods tanzu-postgres-operator "" --ready-fn _operator_ready ${sopts:+--sync-options "$sopts"} || rc=$?
[[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"
patch_note=""
if [[ -n "$old_manifests" ]]; then
  if [[ "$PATCHES_MODE" == "drop" ]]; then
    operator_patches_apply "$REPO" "$C" --old "$old_manifests" || fail OPERATOR_PATCH_RELEASE_FAILED "$OPERATOR_PATCH_DETAIL"
    rc=0; app_sync_wait "$app" "$TIMEOUT" --pods tanzu-postgres-operator "" --ready-fn _operator_ready || rc=$?
    [[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "after releasing the manifest patches: $SYNC_FAIL_DETAIL"
    patch_note="; manifest patches dropped: ${old_manifests}"
  else
    overrides="$(operator_patch_diffs "$REPO" "$C")"
    if [[ -n "$overrides" ]]; then
      record_entry "warning.${C}.operator" WARNING OPERATOR_PATCH_OVERRIDES \
        "the manifest patches override these values of chart ${TARGET}: $(tr '\n' ';' <<<"$overrides")"
    fi
    operator_patches_apply "$REPO" "$C" || fail OPERATOR_PATCH_APPLY_FAILED "$OPERATOR_PATCH_DETAIL"
    operator_wait_ready "$TIMEOUT" || fail "OPERATOR_${POD_WATCH_REASON:-NOT_READY}" "after the manifest patches: ${POD_WATCH_DETAIL}"
    left="$(operator_patch_diffs "$REPO" "$C")"
    [[ -z "$left" ]] || fail OPERATOR_PATCH_NOT_APPLIED "$(head -n 5 <<<"$left" | tr '\n' ';')"
    patch_note="; manifest patches re-applied: ${OPERATOR_PATCH_DETAIL% }$( [[ -z "$overrides" ]] || printf ' (overrides reported)')"
  fi
fi
image="$(tk -n tanzu-postgres-operator get deploy -l app=postgres-operator \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')"

for i in $(inventory_instances "$C"); do
  pg_wait_ready "$i" "$TIMEOUT" || fail "INSTANCE_${POD_WATCH_REASON:-NOT_RUNNING}" "after the operator upgrade: ${POD_WATCH_DETAIL}"
done
record "result.${C}" SUCCEEDED "" "operator ${TARGET}, image ${image}${patch_note}" "$current"
