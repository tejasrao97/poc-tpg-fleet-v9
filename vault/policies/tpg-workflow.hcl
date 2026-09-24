# tpg-workflow: Vault Agent in the hub Argo Workflows pods (role tpg-workflow,
# ServiceAccount argo/tpg-workflow). Reads the three values the workflows use.
path "tpg/data/shared/broadcom-registry" {
  capabilities = ["read"]
}
path "tpg/data/shared/github-push" {
  capabilities = ["read"]
}
path "tpg/data/shared/backup-storage" {
  capabilities = ["read"]
}
