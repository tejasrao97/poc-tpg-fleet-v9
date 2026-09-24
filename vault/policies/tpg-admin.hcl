# tpg-admin: used by tpg-aks-infra scripts (login through auth/kubernetes role
# tpg-setup) to manage the tpg KV mount, auth mounts, roles and policies.
path "tpg/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/tpg" {
  capabilities = ["create", "read", "update"]
}
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/auth/kubernetes" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/auth/k8s-*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "auth/kubernetes/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/k8s-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policies/acl/tpg-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
path "sys/seal-status" {
  capabilities = ["read"]
}
