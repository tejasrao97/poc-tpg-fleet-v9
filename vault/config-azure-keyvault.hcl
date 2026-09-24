# Vault server configuration, unseal mode azure-keyvault.
# Rendered into the vault Helm release by helm-addons.sh, which replaces the
# @TENANT_ID@, @KEY_VAULT_NAME@ and @KEY_NAME@ tokens. The pod authenticates
# to Azure Key Vault with workload identity (no client secret): the AKS
# webhook injects AZURE_CLIENT_ID, AZURE_TENANT_ID and AZURE_FEDERATED_TOKEN_FILE.
ui            = true
disable_mlock = true

listener "tcp" {
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file   = "/vault/userconfig/vault-tls/tls.crt"
  tls_key_file    = "/vault/userconfig/vault-tls/tls.key"
  # /v1/sys/metrics without a token, for the Vault sealed alert
  telemetry {
    unauthenticated_metrics_access = true
  }
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-0"
}

seal "azurekeyvault" {
  tenant_id  = "@TENANT_ID@"
  vault_name = "@KEY_VAULT_NAME@"
  key_name   = "@KEY_NAME@"
}

service_registration "kubernetes" {}

telemetry {
  prometheus_retention_time = "60s"
  disable_hostname          = true
}
