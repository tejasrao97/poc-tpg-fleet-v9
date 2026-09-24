#!/usr/bin/env bash
# rotate-cluster.sh WORKFLOW_NAME CLUSTER SECRET_TYPE
# Target side of a credential rotation: wait until the Vault Secrets Operator on
# the cluster has written the new Vault value into every managed namespace, then
# verify it. The expected value comes from Vault through Vault Agent (this pod).
#   broadcom-registry: regsecret in tanzu-postgres-operator and every pg-* managed
#                      namespace; then an image pull with the operator image
#   backup-storage:    backup-storage in every pg-* managed namespace; then every
#                      PostgresBackupLocation reconciles the new Secret version
# Records result.<cluster> UPDATED | FAILED | SKIPPED. Exits 1 on FAILED.
WF="$1"; C="$2"; TYPE="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
if ! use_cluster "$C" || ! tk get --raw=/readyz >/dev/null 2>&1; then
  record "$key" SKIPPED UNREACHABLE; exit 0
fi
mapfile -t NSS < <(tk get namespace -l tpg.fleet/managed=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^(tanzu-postgres-operator|pg-.+)$' || true)
[[ "${#NSS[@]}" -gt 0 ]] || { record "$key" SKIPPED NO_MANAGED_NAMESPACES; exit 0; }

sha() { sha256sum | cut -c1-16; }

# wait_synced NAMESPACE SECRET JQ_EXPR WANT_SHA: poll until sha(JQ_EXPR on the Secret) == WANT_SHA
wait_synced() {
  local ns="$1" name="$2" expr="$3" want="$4" have="" _
  for _ in $(seq 1 30); do
    have="$(tk -n "$ns" get secret "$name" -o json 2>/dev/null | jq -r "$expr" 2>/dev/null | sha)"
    [[ "$have" == "$want" ]] && return 0
    sleep 10
  done
  log "${ns}/${name}: $(tk -n "$ns" get vaultstaticsecret "$name" -o json 2>/dev/null \
    | jq -r '[.status.conditions[]? | .type + "=" + .status + " " + .message] | join("; ")')"
  return 1
}

case "$TYPE" in
  broadcom-registry)
    P="$(vault_secret broadcom-registry password)" || fail NO_VAULT_SECRET broadcom-registry
    want="$(printf '%s' "$P" | sha)"
    for ns in "${NSS[@]}"; do
      wait_synced "$ns" regsecret '.data[".dockerconfigjson"] | @base64d | fromjson | .auths[].password' "$want" \
        || fail SECRET_NOT_SYNCED "${ns}/regsecret still has the previous token after 5 minutes"
    done
    image="$(tk -n tanzu-postgres-operator get deploy -l app=postgres-operator \
      -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [[ -n "$image" ]] || fail VERIFY_FAILED "operator Deployment not found for pull test"
    pod="tpg-pull-check-$(date +%s)"
    tk -n tanzu-postgres-operator run "$pod" --image="$image" --restart=Never \
      --image-pull-policy=Always \
      --overrides='{"apiVersion":"v1","spec":{"imagePullSecrets":[{"name":"regsecret"}],"tolerations":[{"operator":"Exists"}]}}' \
      --command -- sh -c "exit 0" >/dev/null || fail VERIFY_FAILED "could not create pull-check pod"
    result=""
    for _ in $(seq 1 30); do
      waiting="$(tk -n tanzu-postgres-operator get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
      pulled="$(tk -n tanzu-postgres-operator get pod "$pod" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)"
      if [[ "$waiting" == "ErrImagePull" || "$waiting" == "ImagePullBackOff" ]]; then result="pull-failed"; break; fi
      if [[ -n "$pulled" ]]; then result="pulled"; break; fi
      sleep 5
    done
    tk -n tanzu-postgres-operator delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    [[ "$result" == "pulled" ]] || fail VERIFY_FAILED "image pull with the new token: ${result:-timeout}"
    record "$key" UPDATED "" "regsecret synced from Vault in ${#NSS[@]} namespaces, image pull verified"
    ;;
  backup-storage)
    K="$(vault_secret backup-storage accountKey)" || fail NO_VAULT_SECRET backup-storage
    want="$(printf '%s' "$K" | sha)"
    count=0
    for ns in "${NSS[@]}"; do
      [[ "$ns" == pg-* ]] || continue
      wait_synced "$ns" backup-storage '.data.accountKey | @base64d' "$want" \
        || fail SECRET_NOT_SYNCED "${ns}/backup-storage still has the previous key after 5 minutes"
      rv="$(tk -n "$ns" get secret backup-storage -o jsonpath='{.metadata.resourceVersion}')"
      for bl in $(tk -n "$ns" get postgresbackuplocation -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        okk=""
        for _ in $(seq 1 30); do
          cur="$(tk -n "$ns" get postgresbackuplocation "$bl" -o jsonpath='{.status.currentSecretResourceVersion}' 2>/dev/null || true)"
          [[ "$cur" == "$rv" ]] && { okk=1; break; }
          sleep 10
        done
        [[ -n "$okk" ]] || fail VERIFY_FAILED "$ns/$bl did not pick up Secret resourceVersion $rv"
      done
      count=$((count + 1))
    done
    record "$key" UPDATED "" "backup-storage synced from Vault in ${count} namespaces, backup locations reconciled"
    ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac
