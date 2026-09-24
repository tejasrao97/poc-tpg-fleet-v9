#!/usr/bin/env bash
# rotate-hub.sh WORKFLOW_NAME SECRET_TYPE
# Hub side of a credential rotation. The new value is already in Vault (written
# by tpg-aks-infra scripts/run.sh --only hub-secrets, which checks it first); this
# step waits until the hub consumers use it and verifies it.
#   broadcom-registry: Argo CD repository repo-tanzu-postgres-oci (VaultStaticSecret) reconnects
#   git-read:          Argo CD repository repo-tpg-fleet (VaultStaticSecret) reconnects
#   git-push:          clone and push --dry-run with the Vault value (Vault Agent, this pod)
#   backup-storage:    the new key opens every target's container (Get Container Properties)
WF="$1"; TYPE="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.hub"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"

# argocd_repo_check REPOSITORY_SECRET REPO_URL: wait for the VaultStaticSecret to be
# Ready after VSO's next refresh (refreshAfter 60s), then for Argo CD to connect.
argocd_repo_check() {
  local vss="$1" url="$2" st="" state="" _
  log "waiting 70s for the Vault Secrets Operator refresh of argocd/${vss}"
  sleep 70
  for _ in $(seq 1 20); do
    st="$(kubectl -n argocd get vaultstaticsecret "$vss" -o json 2>/dev/null \
      | jq -r '[.status.conditions[]? | select(.type == "Ready" or .type == "SecretSynced")] | ((map(select(.type == "Ready")) + .)[0].status // "")')"
    [[ "$st" == "True" ]] && break
    sleep 15
  done
  [[ "$st" == "True" ]] || fail SECRET_NOT_SYNCED "VaultStaticSecret argocd/${vss} not Ready"
  for _ in $(seq 1 12); do
    state="$(acd GET "/api/v1/repositories?forceRefresh=true" \
      | jq -r --arg u "$url" '.items[] | select(.repo == $u) | .connectionState.status' | head -n1)"
    [[ "$state" == "Successful" ]] && return 0
    sleep 15
  done
  fail VERIFY_FAILED "Argo CD connection state for ${url}: ${state:-unknown}"
}

case "$TYPE" in
  broadcom-registry)
    argocd_repo_check repo-tanzu-postgres-oci "$(setting registryHost)"
    record "$key" UPDATED "" "repo-tanzu-postgres-oci synced from Vault, Argo CD connection Successful"
    ;;
  git-read)
    argocd_repo_check repo-tpg-fleet "$(setting fleetRepoURL)"
    record "$key" UPDATED "" "repo-tpg-fleet synced from Vault, Argo CD connection Successful"
    ;;
  git-push)
    git_clone "$WORK/repo" || fail VERIFY_FAILED "clone with the Vault value tpg/shared/github-push failed"
    git -C "$WORK/repo" push --dry-run --quiet origin "HEAD:$(setting fleetRevision)" \
      || fail VERIFY_FAILED "push authentication failed"
    record "$key" UPDATED "" "tpg/shared/github-push verified (clone and push dry-run)"
    ;;
  backup-storage)
    A="$(vault_secret backup-storage accountName)" || fail NO_VAULT_SECRET backup-storage
    K="$(vault_secret backup-storage accountKey)" || fail NO_VAULT_SECRET backup-storage
    [[ "$A" == "$(setting backupStorageAccount)" ]] \
      || fail VERIFY_FAILED "Vault accountName ${A} differs from tpg-settings backupStorageAccount $(setting backupStorageAccount)"
    checked=()
    for c in $(run_data inventory | jq -r '.[].name'); do
      code="$(blob_container_status "$A" "$K" "pg-backups-${c}")"
      [[ "$code" == "200" ]] || fail VERIFY_FAILED "container pg-backups-${c}: HTTP ${code} with the new key (403: key rejected, 404: container missing)"
      checked+=("pg-backups-${c}")
    done
    record "$key" UPDATED "" "new key opens ${#checked[@]} containers: ${checked[*]:-none}"
    ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac
