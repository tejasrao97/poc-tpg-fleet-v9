# Vault server configuration, unseal mode shamir (default).
# Rendered into the vault Helm release by helm-addons.sh. Unseal keys are
# created by vault operator init (5 shares, threshold 3) and never stored.
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

service_registration "kubernetes" {}

telemetry {
  prometheus_retention_time = "60s"
  disable_hostname          = true
}
