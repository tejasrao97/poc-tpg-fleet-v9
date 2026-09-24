#!/usr/bin/env bash
# day0-deploy.sh WORKFLOW_NAME CLUSTER SYNC_TIMEOUT_SECONDS [INSTALL_ADDONS]
# Prepare the namespaces, install the Helm add-ons (cert-manager, the Vault Secrets
# Operator, and the monitoring agent for the standalone option) when
# INSTALL_ADDONS=true, sync the platform, operator and instance Applications,
# then verify every instance. The regsecret and backup-storage Secrets come from
# Vault through VaultStaticSecrets (platform/base and charts/tpg-instance).
# Exits 1 on failure so later batches do not run.
# MONITORING_OPTION (environment) overrides tpg-settings monitoringOption.
# EXISTING_ADDONS (environment): skip (default) or upgrade add-on releases that already exist.
WF="$1"; C="$2"; TIMEOUT="$3"; INSTALL_ADDONS="${4:-true}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

fail() { record "result.${C}" FAILED "$1" "${2:-}"; exit 1; }
result_guard "result.${C}"

use_cluster "$C" || fail NOT_REGISTERED
INSTANCES="$(inventory_instances "$C")"

# ---- Step 2: prepare
log "preparing namespaces on ${C}"
for ns in tanzu-postgres-operator $(for i in $INSTANCES; do echo "pg-$i"; done); do
  tk create namespace "$ns" --dry-run=client -o yaml | tk apply -f - >/dev/null
  tk label namespace "$ns" tpg.fleet/managed=true --overwrite >/dev/null
done

# ---- Step 3: Helm add-ons and platform components
if [[ "$INSTALL_ADDONS" == "true" ]]; then
  bash /scripts/addons-cluster.sh "$WF" "$C" auto false "result.${C}.addons" "${EXISTING_ADDONS:-skip}" \
    || fail ADDONS_FAILED "see result ${C}.addons"
fi
tk wait --for=condition=Established --timeout=60s crd/certificates.cert-manager.io >/dev/null 2>&1 \
  || fail CERT_MANAGER_NOT_AVAILABLE "install it with tpg-helm-addons or installAddons=true"
if ! tk wait --for=condition=Established --timeout=60s crd/vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1 \
   || ! tk -n tpg-vault get vaultauth tpg-vault >/dev/null 2>&1; then
  fail VSO_NOT_AVAILABLE "Vault Secrets Operator or VaultAuth tpg-vault/tpg-vault missing: run tpg-helm-addons or installAddons=true"
fi

wait_secret() {  # wait_secret NAMESPACE NAME: the VaultStaticSecret has created the Secret
  local _
  for _ in $(seq 1 30); do
    tk -n "$1" get secret "$2" >/dev/null 2>&1 && return 0
    sleep 10
  done
  log "$1/$2: $(tk -n "$1" get vaultstaticsecret "$2" -o json 2>/dev/null \
    | jq -r '[.status.conditions[]? | .type + "=" + .status + " " + .message] | join("; ")')"
  return 1
}

wait_generated() {  # wait_generated APP APPLICATIONSET
  app_exists "$1" && return 0
  appset_refresh "$2"
  for _ in $(seq 1 40); do
    app_exists "$1" && return 0
    sleep 15
  done
  return 1
}
# Every sync follows the fleet commit at the head of the branch (fleet-day0.sh
# pushed the Day 0 change in the step before this one).
REV="$(fleet_head)"
[[ -n "$REV" ]] || log "WARNING: could not read the fleet branch head; syncing without a pinned revision"

# Platform: namespace, regsecret (Vault), StorageClass. No pods of its own.
app="tpg-${C}-platform"
wait_generated "$app" tpg-platform || fail APP_NOT_GENERATED "$app"
rc=0; app_sync_wait "$app" "$TIMEOUT" ${REV:+--revision "$REV"} || rc=$?
[[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"
# The operator images need the pull Secret synced from Vault
wait_secret tanzu-postgres-operator regsecret || fail SECRET_NOT_SYNCED "tanzu-postgres-operator/regsecret (Vault tpg/shared/broadcom-registry)"

# Operator: the chart from the Broadcom OCI registry (no fleet commit to pin).
# The target is checked directly - CRD Established, operator Deployment
# available, pods printed every 5 seconds - instead of waiting for Argo CD to
# rediscover the new CRDs, which took more than 5 minutes.
app="tpg-${C}-operator"
wait_generated "$app" tpg-operator || fail APP_NOT_GENERATED "$app"
rc=0; app_sync_wait "$app" "$TIMEOUT" --pods tanzu-postgres-operator "" --ready-fn _operator_ready || rc=$?
[[ "$rc" -eq 0 ]] || fail "OPERATOR_${SYNC_FAIL_REASON}" "$SYNC_FAIL_DETAIL"
# Operator manifest patches (tpg-patch) declared for the cluster are re-applied
# after every operator sync: a re-created object comes back from the chart alone
git_clone "$WORK/repo"
if [[ -n "$(operator_patch_files "$WORK/repo" "$C")" ]]; then
  operator_patches_apply "$WORK/repo" "$C" || fail OPERATOR_PATCH_APPLY_FAILED "$OPERATOR_PATCH_DETAIL"
  operator_wait_ready "$TIMEOUT" || fail "OPERATOR_${POD_WATCH_REASON:-NOT_READY}" "after the operator manifest patches: ${POD_WATCH_DETAIL}"
  log "operator manifest patches applied: ${OPERATOR_PATCH_DETAIL}"
fi

# Versions declared in Git must exist now that the operator is installed
while read -r v; do
  [[ -z "$v" ]] && continue
  tk get postgresversion "$v" >/dev/null 2>&1 || fail VERSION_NOT_AVAILABLE "$v"
done < <(inventory_cluster "$C" | jq -r '.instances[].postgresVersion' | sort -u)

# ---- Step 4: instances (sync, then the instance pods every 5 seconds until Running)
for i in $INSTANCES; do
  rc=0
  sync_instance_app "$C" "$i" "$TIMEOUT" "$REV" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "tpg-${C}-${i}: ${SYNC_FAIL_DETAIL}"
done

# ---- Step 5: verify
details=()
for i in $INSTANCES; do
  pg_wait_ready "$i" "$TIMEOUT" || fail "INSTANCE_${POD_WATCH_REASON:-NOT_RUNNING}" "$POD_WATCH_DETAIL"
  for sec in regsecret backup-storage; do
    wait_secret "pg-$i" "$sec" || fail SECRET_NOT_SYNCED "pg-$i/$sec from Vault"
  done
  stanza="$(tk -n "pg-$i" get postgres "$i" -o jsonpath='{.status.stanzaName}' 2>/dev/null || true)"
  [[ -n "$stanza" ]] || fail BACKUP_LOCATION_NOT_INITIALIZED "$i"
  details+=("${i}:Running")
done
record "result.${C}" SUCCEEDED "" "$(IFS=' '; echo "${details[*]:-no instances}")"
