# tpg-target: Vault Secrets Operator on every target cluster (role tpg-vso on
# auth/k8s-<cluster>, ServiceAccount tpg-vso in any namespace). One shared
# policy for all targets: the backup key, the registry token and the metrics
# remote-write credential (standalone monitoring) are the same for every cluster.
path "tpg/data/shared/broadcom-registry" {
  capabilities = ["read"]
}
path "tpg/data/shared/backup-storage" {
  capabilities = ["read"]
}
path "tpg/data/shared/monitoring-remote-write" {
  capabilities = ["read"]
}
