# Vault Agent sidecar configuration. Not used: the workflows set
# agent-pre-populate-only, so only config-init.hcl runs. Kept because the
# injector expects the ConfigMap to be complete.
#
# Vault Agent for the tpg workflow pods (ConfigMap argo/tpg-vault-agent).
#
# Every tpg WorkflowTemplate sets these pod annotations (spec.podMetadata):
#   vault.hashicorp.com/agent-inject: "true"
#   vault.hashicorp.com/agent-pre-populate-only: "true"   init container only, no sidecar
#   vault.hashicorp.com/agent-init-first: "true"          secrets exist before argoexec starts
#   vault.hashicorp.com/agent-configmap: tpg-vault-agent  this file
#   vault.hashicorp.com/tls-secret: vault-ca              CA mounted at /vault/tls
# The templates live here, not in annotations, because Argo Workflows would
# try to resolve the {{ }} expressions of annotation values.
#
# Output (JSON files read by workflows/scripts/lib.sh vault_secret):
#   /vault/secrets/broadcom-registry.json  {"username": ..., "password": ...}
#   /vault/secrets/github-push.json        {"username": ..., "token": ...}
#   /vault/secrets/backup-storage.json     {"accountName": ..., "accountKey": ...}
exit_after_auth = false
pid_file        = "/home/vault/.pid"

vault {
  address = "https://vault.vault.svc:8200"
  ca_cert = "/vault/tls/ca.crt"
}

auto_auth {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role = "tpg-workflow"
    }
  }

  sink "file" {
    config = {
      path = "/home/vault/.token"
    }
  }
}

template {
  destination = "/vault/secrets/broadcom-registry.json"
  perms       = "0440"
  contents    = <<-EOT
    {{- with secret "tpg/data/shared/broadcom-registry" }}{{ .Data.data | toJSON }}{{ end }}
  EOT
}

template {
  destination = "/vault/secrets/github-push.json"
  perms       = "0440"
  contents    = <<-EOT
    {{- with secret "tpg/data/shared/github-push" }}{{ .Data.data | toJSON }}{{ end }}
  EOT
}

template {
  destination = "/vault/secrets/backup-storage.json"
  perms       = "0440"
  contents    = <<-EOT
    {{- with secret "tpg/data/shared/backup-storage" }}{{ .Data.data | toJSON }}{{ end }}
  EOT
}
