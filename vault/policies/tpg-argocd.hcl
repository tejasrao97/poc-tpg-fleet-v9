# tpg-argocd: Vault Secrets Operator on the hub (role tpg-argocd, ServiceAccounts
# argocd/tpg-vso and argo/tpg-vso). Builds the Argo CD repository Secrets
# (argocd) and the Secret argo/argo-artifacts with the storage account key of
# the archived workflow logs (argo).
path "tpg/data/shared/github-read" {
  capabilities = ["read"]
}
path "tpg/data/shared/broadcom-registry" {
  capabilities = ["read"]
}
path "tpg/data/shared/backup-storage" {
  capabilities = ["read"]
}
