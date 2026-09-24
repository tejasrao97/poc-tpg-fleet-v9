#!/usr/bin/env bash
# patch-cluster.sh WORKFLOW_NAME CLUSTER TIMEOUT_SECONDS
# tpg-patch, one cluster, after patch-plan.sh has written and pushed the patch
# references (plan.<cluster> in the run ConfigMap says what to do here):
#   1 operator values     sync tpg-<cluster>-operator at the pushed fleet commit
#                         (the chart re-renders with the value files) and wait
#                         until the CRDs are Established and the operator runs
#   2 operator manifests  when patches were declared before: a sync first (the Argo
#                         CD field manager co-owns the patched fields), then the
#                         server-side apply of the merged manifest patches (field
#                         manager tpg-patch) with the release of objects no longer
#                         patched, then a sync that gives the fields that left the
#                         patches back to the chart; every patched field is then
#                         compared with the live object (OPERATOR_PATCH_NOT_APPLIED)
#   3 instances           sync tpg-<cluster>-<instance> at the pushed commit, then
#                         the instance pods every 5 seconds until Running
# Records result.<cluster>.operator and result.<cluster>.<instance>. Exits 1 when
# anything failed, so the later batches of rolloutMode do not run.
WF="$1"; C="$2"; TIMEOUT="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
result_guard "result.${C}"

plan="$(run_data "plan.${C}" | jq -r '.detail // empty')"
if [[ -z "$plan" ]]; then
  record "result.${C}" SKIPPED_NOT_PLANNED "" "no plan for ${C}: blocked or nothing to patch (see the pre-check)"
  exit 0
fi
if jq -e '(.instances | length) == 0 and (.operatorValues | not) and (.operatorManifests | not)' <<<"$plan" >/dev/null; then
  record "result.${C}" SUCCEEDED NOTHING_TO_PATCH "no patch file applies to ${C}"
  exit 0
fi
use_cluster "$C" || { record "result.${C}" FAILED NOT_REGISTERED; exit 1; }
REV="$(run_data revision | jq -r '.detail // empty')"
[[ -n "$REV" ]] || REV="$(fleet_head)"
REPO="$WORK/repo"
git_clone "$REPO"
if [[ -n "$REV" ]]; then
  git -C "$REPO" fetch --quiet --depth 50 origin "$REV" 2>/dev/null || true
  git -C "$REPO" checkout --quiet "$REV" 2>/dev/null || log "WARNING: could not check out ${REV:0:12}; using the fleet branch head"
fi
failed=0
app="tpg-${C}-operator"

# ---- 1 and 2: the operator
if [[ "$(jq -r '.operatorValues' <<<"$plan")" == "true" || "$(jq -r '.operatorManifests' <<<"$plan")" == "true" ]]; then
  key="result.${C}.operator"
  notes=()
  if [[ "$(jq -r '.operatorValues' <<<"$plan")" == "true" ]]; then
    appset_refresh tpg-operator
    rc=0; app_sync_wait "$app" "$TIMEOUT" --pods "$OPERATOR_NS" "" --ready-fn _operator_ready || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      record "$key" FAILED "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"; failed=1
    else
      notes+=("values: $(C="$C" yq -r '.clusters[strenv(C)].operator.patches.values // [] | join(",")' "$REPO/$FLEET_REL")")
    fi
  fi
  if [[ "$failed" -eq 0 && "$(jq -r '.operatorManifests' <<<"$plan")" == "true" ]]; then
    old="$(jq -r '.oldManifests | join(" ")' <<<"$plan")"
    # 2a A sync first: with RespectIgnoreDifferences Argo CD applies the live
    #    (patched) value of every field tpg-patch owns, so the Argo CD field manager
    #    co-owns them. A field that leaves the patches then keeps its value until
    #    the sync in 2c, instead of disappearing from the object in between.
    if [[ -n "$old" ]]; then
      rc=0; app_sync_wait "$app" "$TIMEOUT" --pods "$OPERATOR_NS" "" --ready-fn _operator_ready || rc=$?
      [[ "$rc" -eq 0 ]] || { record "$key" FAILED "$SYNC_FAIL_REASON" "before changing the manifest patches: $SYNC_FAIL_DETAIL"; failed=1; }
    fi
    # 2b the merged patches of every object, and the release of objects no longer patched
    if [[ "$failed" -eq 0 ]] && ! operator_patches_apply "$REPO" "$C" --old "$old"; then
      record "$key" FAILED OPERATOR_PATCH_APPLY_FAILED "$OPERATOR_PATCH_DETAIL"; failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
      applied="$OPERATOR_PATCH_DETAIL"
      # 2c fields that left the patches go back to the chart values
      if [[ -n "$old" ]]; then
        rc=0; app_sync_wait "$app" "$TIMEOUT" --pods "$OPERATOR_NS" "" --ready-fn _operator_ready || rc=$?
        [[ "$rc" -eq 0 ]] || { record "$key" FAILED "$SYNC_FAIL_REASON" "after changing the manifest patches: $SYNC_FAIL_DETAIL"; failed=1; }
      else
        operator_wait_ready "$TIMEOUT" \
          || { record "$key" FAILED "OPERATOR_${POD_WATCH_REASON:-NOT_READY}" "$POD_WATCH_DETAIL"; failed=1; }
      fi
      if [[ "$failed" -eq 0 ]]; then
        diffs="$(operator_patch_diffs "$REPO" "$C")"
        if [[ -n "$diffs" ]]; then
          record "$key" FAILED OPERATOR_PATCH_NOT_APPLIED "$(head -n 5 <<<"$diffs" | tr '\n' ';')"; failed=1
        else
          notes+=("manifests: ${applied% }")
        fi
      fi
    fi
  fi
  [[ "$failed" -ne 0 ]] || record "$key" SUCCEEDED "" "$(IFS='; '; echo "${notes[*]}")"
fi

# ---- 3: the instances
for i in $(jq -r '.instances[]' <<<"$plan"); do
  [[ "$failed" -eq 0 ]] || { record "result.${C}.${i}" SKIPPED_EARLIER_FAILURE "" "the operator step failed on ${C}"; continue; }
  busy="$(busy_operations "$i")"
  if [[ -n "$busy" ]]; then
    record "result.${C}.${i}" FAILED OPERATION_IN_PROGRESS "$busy- the patch is in Git; re-run tpg-patch to sync it"
    failed=1; continue
  fi
  rc=0
  sync_instance_app "$C" "$i" "$TIMEOUT" "$REV" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    record "result.${C}.${i}" FAILED "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"; failed=1; continue
  fi
  refs="$(C="$C" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].patches // {} | to_entries
    | map(.key + ": " + (.value | join(","))) | join("; ")' "$REPO/$FLEET_REL")"
  record "result.${C}.${i}" SUCCEEDED "" "Running, Synced at ${REV:0:12}; ${refs:-no patch files referenced}"
done
exit "$failed"
