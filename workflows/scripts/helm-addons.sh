#!/usr/bin/env bash
# helm-addons.sh: install or upgrade the fleet add-ons as Helm releases on one cluster,
# after a pre-check of what is already installed.
#
#   component     role          release                  chart                               namespace
#   cert-manager  target        cert-manager             jetstack/cert-manager               cert-manager
#   monitoring    hub           kps                      kube-prometheus-stack               monitoring
#                                                        + monitoring/standalone/hub (kubectl apply -k)
#   monitoring    target        kps (agent), tpg-ksm     kube-prometheus-stack, kube-state-metrics
#                                                        + monitoring/standalone/targets (kubectl apply -k)
#   vso           hub, target   vault-secrets-operator   hashicorp/vault-secrets-operator    vault-secrets-operator-system
#                                                        + VaultConnection/VaultAuth tpg-vault (vault/tpg-vault-objects.yaml)
#   vault         hub           vault                    hashicorp/vault (server + injector) vault
#
# Used by tpg-aks-infra scripts/steps/35-vault.sh (vault and vso on the hub),
# scripts/steps/45-helm-addons.sh (workstation) and by the tpg-helm-addons and
# tpg-day0 workflows (targets only).
#
# Pre-check, per release, before anything changes:
#   NOT_INSTALLED   nothing found                         -> install
#   OURS            our release in the expected namespace -> compare chart version and values:
#                     same version and values             -> UP_TO_DATE (nothing to do)
#                     installed chart newer than target   -> SKIPPED_NEWER (never downgrade)
#                     otherwise show the version change and the values diff, then act on
#                     --existing: ask (prompt: upgrade, skip or abort), upgrade, skip or abort
#   OTHER_RELEASE   the same chart as another Helm release (other name or namespace)
#   NOT_HELM        the component's CRDs or controller exist without a Helm release
#                   -> reuse it when compatible (REUSED_EXISTING), otherwise BLOCKED:
#                        cert-manager  controller available and version >= v1.14.0
#                        vso           controller available and version >= 0.9.0
#                        kps, vault    never reused: the fleet needs its own configuration
#                   tpg-ksm is not checked for foreign copies: several kube-state-metrics
#                   instances coexist without conflict.
# Every result is printed on stdout as: ADDON <release> <STATUS> <detail>
#
# The pre-check, the install and the pod watch come from common.sh (hr_* and
# pods_watch, shared with tpg-aks-infra scripts/lib/common.sh). While helm
# --wait runs, the pods of the release namespace are printed every 5 seconds and
# the install stops as soon as a pod cannot start (CrashLoopBackOff,
# CreateContainerConfigError, ImagePullBackOff, ...), with the pod's events and logs.
#
# Target monitoring (standalone option) writes to the hub remote-write gateway
# (https, basic auth). The credential comes from Vault through the
# VaultStaticSecret monitoring/tpg-remote-write, and the gateway certificate is
# checked against the Vault CA (copied from tpg-vault/vault-ca).
#
# Usage:
#   helm-addons.sh --cluster NAME --role hub|target --components LIST --fleet-dir DIR
#     [--kubeconfig FILE] [--context CTX] [--remote-write-url URL]
#     [--existing ask|upgrade|skip|abort] [--dry-run]
#     [--vault-addr URL --vault-ca-file FILE --vault-auth-mount MOUNT --vault-auth-role ROLE]  (vso)
# LIST: comma-separated cert-manager, monitoring, vso, vault.
# --existing defaults to ADDONS_EXISTING, else ask on a terminal and skip without one.
#
# Component vault reads VAULT_UNSEAL_MODE (shamir | azure-keyvault) and, for
# azure-keyvault, VAULT_AKV_TENANT_ID, VAULT_AKV_NAME, VAULT_AKV_KEY_NAME and
# VAULT_AKV_CLIENT_ID from the environment.
#
# Hub monitoring: Grafana reads its admin credentials from Secret monitoring/grafana-admin.
# The script creates it before the install when it is missing, with GRAFANA_ADMIN_PASSWORD
# from the environment or a generated 24-character password. The password is never
# written to a file. On success the hub run prints REMOTE_WRITE_URL=<url>.
# KPS_HUB_EXTRA_VALUES: optional comma-separated extra values files for the hub release,
# relative to --fleet-dir (for example monitoring/grafana/smtp/grafana-smtp-values.yaml).
set -euo pipefail
# shellcheck source=workflows/scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CERT_MANAGER_VERSION="v1.21.2"
KPS_VERSION="91.4.0"
KSM_VERSION="8.5.0"
VSO_VERSION="1.5.1"
VAULT_CHART_VERSION="0.34.1"
JETSTACK_REPO="https://charts.jetstack.io"
PROM_REPO="https://prometheus-community.github.io/helm-charts"
HASHICORP_REPO="https://helm.releases.hashicorp.com"
CERT_MANAGER_MIN="1.14.0"
VSO_MIN="0.9.0"

CLUSTER="" ROLE="" COMPONENTS="" FLEET_DIR="" KUBECONFIG_FILE="" CONTEXT="" RW_URL="" DRY_RUN=0
EXISTING="${ADDONS_EXISTING:-}"
VAULT_ADDR_ARG="" VAULT_CA_FILE="" VAULT_AUTH_MOUNT="" VAULT_AUTH_ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --fleet-dir) FLEET_DIR="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --remote-write-url) RW_URL="$2"; shift 2 ;;
    --existing) EXISTING="$2"; shift 2 ;;
    --vault-addr) VAULT_ADDR_ARG="$2"; shift 2 ;;
    --vault-ca-file) VAULT_CA_FILE="$2"; shift 2 ;;
    --vault-auth-mount) VAULT_AUTH_MOUNT="$2"; shift 2 ;;
    --vault-auth-role) VAULT_AUTH_ROLE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Read by hr_say and hr_die in common.sh (set here so errors before hr_setup are labelled)
# shellcheck disable=SC2034
HR_CLUSTER="$CLUSTER"; HR_LOG_NAME="helm-addons"
[[ -n "$CLUSTER" && -n "$COMPONENTS" && -d "$FLEET_DIR" ]] || hr_die "--cluster, --components and --fleet-dir are required"
[[ "$ROLE" == "hub" || "$ROLE" == "target" ]] || hr_die "--role must be hub or target"
command -v helm >/dev/null || hr_die "helm is required"
command -v yq >/dev/null || hr_die "yq (mikefarah v4) is required"
setup_args=(--cluster "$CLUSTER" --dry-run "$DRY_RUN" --log-name helm-addons)
[[ -z "$KUBECONFIG_FILE" ]] || setup_args+=(--kubeconfig "$KUBECONFIG_FILE")
[[ -z "$CONTEXT" ]] || setup_args+=(--context "$CONTEXT")
[[ -z "$EXISTING" ]] || setup_args+=(--existing "$EXISTING")
hr_setup "${setup_args[@]}"
trap 'rm -rf "$HR_TMP"' EXIT
k() { hr_k "$@"; }
h() { hr_h "$@"; }
say() { hr_say "$@"; }
die() { hr_die "$@"; }

# ----------------------------------------------------------------- pre-check hooks
# foreign_image PATTERN -> "<ns>/<deployment> <image>" of the first Deployment running PATTERN
foreign_image() {
  k get deploy -A -o json 2>/dev/null | jq -r --arg p "$1" '
    [.items[] | . as $d | .spec.template.spec.containers[] | select(.image | contains($p))
     | $d.metadata.namespace + "/" + $d.metadata.name + " " + .image] | first // empty'
}

image_version() { sed -E 's/@.*$//; s/^.*:([^:\/]+)$/\1/' <<<"$1"; }

deploy_available() {  # deploy_available NS/NAME
  k -n "${1%%/*}" get deploy "${1##*/}" -o json 2>/dev/null \
    | jq -e '(.status.availableReplicas // 0) > 0' >/dev/null
}

# hr_foreign_hook RELEASE NS -> NOT_HELM when the component runs without a Helm release
hr_foreign_hook() {
  case "$1" in
    cert-manager)
      if k get crd certificates.cert-manager.io >/dev/null 2>&1 || [[ -n "$(foreign_image jetstack/cert-manager-controller)" ]]; then echo NOT_HELM; fi ;;
    kps)
      if k get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1 || [[ -n "$(foreign_image prometheus-operator/prometheus-operator)" ]]; then echo NOT_HELM; fi ;;
    vault-secrets-operator)
      if [[ -n "$(foreign_image hashicorp/vault-secrets-operator)" ]]; then echo NOT_HELM; return; fi
      if k get crd vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1; then
        say "VSO CRDs exist without a controller (left over from an earlier install); installing"
      fi ;;
    vault)
      if [[ -n "$(k get statefulset -A -o json 2>/dev/null | jq -r '[.items[] | select(any(.spec.template.spec.containers[]; .image | test("(^|/)(hashicorp/)?vault:"))) | .metadata.namespace + "/" + .metadata.name] | first // empty')" ]]; then
        echo NOT_HELM
      fi ;;
  esac
}

# hr_reuse_hook RELEASE CLASS -> 0 and prints the detail when the foreign installation is usable
hr_reuse_hook() {
  local rel="$1" class found dep img ver min
  class="$(hr_class_text "$2")"
  case "$rel" in
    cert-manager) found="$(foreign_image jetstack/cert-manager-controller)"; min="$CERT_MANAGER_MIN" ;;
    vault-secrets-operator) found="$(foreign_image hashicorp/vault-secrets-operator)"; min="$VSO_MIN" ;;
    *) echo "${class}, and the fleet needs its own ${rel} configuration: that installation cannot be reused"; return 1 ;;
  esac
  if [[ -z "$found" ]]; then
    echo "${class}, but no running controller was found (leftover CRDs?)"; return 1
  fi
  dep="${found%% *}"; img="${found#* }"; ver="$(image_version "$img")"
  if ! deploy_available "$dep"; then
    echo "${class}, but ${dep} (${img}) is not available"; return 1
  fi
  if ! hr_ver_ge "$ver" "$min"; then
    echo "${class}: ${dep} runs ${ver}, the fleet needs ${min} or later"; return 1
  fi
  echo "${class}: reusing ${dep} ${ver}"
}

# ----------------------------------------------------------------- components
cert_manager() {
  local m="$HR_TMP/cert-manager.yaml"
  hr_merge_values "$m" "$(hr_overlay cert-manager '.crds.enabled = true')"
  # hr_release waits (helm --wait) while it prints the cert-manager pods every 5 seconds
  hr_release cert-manager cert-manager "$CERT_MANAGER_VERSION" "$JETSTACK_REPO" cert-manager "$m" ""
}

grafana_admin_secret() {
  if k -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    say "Secret monitoring/grafana-admin exists; keeping it"
    return
  fi
  local pw="${GRAFANA_ADMIN_PASSWORD:-}" src="GRAFANA_ADMIN_PASSWORD"
  if [[ -z "$pw" ]]; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
    src="generated"
  fi
  [[ "${#pw}" -ge 12 ]] || die "the Grafana admin password must have at least 12 characters"
  if [[ "$DRY_RUN" -eq 1 ]]; then say "dry run: would create Secret monitoring/grafana-admin (${src} password)"; return; fi
  k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$pw" >/dev/null
  say "created Secret monitoring/grafana-admin (${src} password). Read it with:"
  say "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
}

# Hub: kube-prometheus-stack (Prometheus with the remote-write receiver, Grafana,
# Alertmanager), the fleet dashboards, alert rules and ServiceMonitors, and the
# remote-write gateway (nginx: TLS and basic auth in front of
# /api/v1/write). The gateway's Secrets (tpg-remote-write-tls,
# tpg-remote-write-htpasswd) and its load balancer Service are created by
# tpg-aks-infra scripts/steps/45-helm-addons.sh before this runs, because they
# need Vault and the inventory.
monitoring_hub() {
  # raw defaults to empty: the script runs with set -u, and an unset
  # KPS_HUB_EXTRA_VALUES would otherwise abort the hub monitoring install with
  # "KPS_HUB_EXTRA_VALUES: unbound variable" before anything is installed.
  local f raw="${KPS_HUB_EXTRA_VALUES:-}"
  local files=("$FLEET_DIR/monitoring/standalone/hub/kps-values.yaml"
               "$FLEET_DIR/monitoring/grafana/alerts/grafana-alerting-values.yaml") m="$HR_TMP/kps-hub.yaml"
  for f in ${raw//,/ }; do
    [[ "$f" == /* ]] || f="$FLEET_DIR/$f"
    [[ -f "$f" ]] || die "KPS_HUB_EXTRA_VALUES file not found: $f"
    files+=("$f")
  done
  hr_merge_values "$m" "${files[@]}"
  grafana_admin_secret
  hr_release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring "$m" ""
  [[ "$DRY_RUN" -eq 1 ]] && return
  k apply -k "$FLEET_DIR/monitoring/standalone/hub" >/dev/null
  say "applied monitoring/standalone/hub (dashboards, ServiceMonitors, PrometheusRule, remote-write gateway)"
  pods_watch monitoring 600 --kubectl k --selector app.kubernetes.io/name=tpg-remote-write \
    --label "remote-write gateway" \
    || die "the remote-write gateway is not ready: ${POD_WATCH_REASON} ${POD_WATCH_DETAIL} (Secrets monitoring/tpg-remote-write-tls and tpg-remote-write-htpasswd come from tpg-aks-infra scripts/run.sh --only addons)"
}

# Target: Prometheus (2 h local retention) that remote-writes everything to the
# hub gateway with basic auth over TLS, kube-state-metrics with the Tanzu
# Postgres custom resource metrics, and the PodMonitor for postgres-exporter.
monitoring_target() {
  [[ -n "$RW_URL" ]] || die "--remote-write-url is required for target monitoring (tpg-settings hubPrometheusRemoteWriteUrl)"
  [[ "$RW_URL" == https://* ]] || die "--remote-write-url must be the https URL of the hub remote-write gateway (got ${RW_URL}); re-run tpg-aks-infra scripts/run.sh --only addons"
  local m="$HR_TMP/kps-target.yaml" s="$HR_TMP/ksm.yaml" ca
  if [[ "$DRY_RUN" -ne 1 ]]; then
    # Credential and CA for the remote write, before Prometheus starts: the
    # operator does not create the Prometheus pod while a referenced Secret is missing.
    k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
    k apply -f "$FLEET_DIR/monitoring/standalone/targets/remote-write-credentials.yaml" >/dev/null \
      || die "could not apply the remote-write VaultStaticSecret (is the Vault Secrets Operator installed? component vso)"
    ca="$(k -n tpg-vault get secret vault-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || true)"
    [[ -n "$ca" ]] || die "Secret tpg-vault/vault-ca not found on ${CLUSTER}: install component vso first"
    printf '%s' "$ca" | k -n monitoring create secret generic tpg-remote-write-ca --from-file=ca.crt=/dev/stdin \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    local _i
    for _i in $(seq 1 30); do
      k -n monitoring get secret tpg-remote-write >/dev/null 2>&1 && break
      sleep 5
    done
    k -n monitoring get secret tpg-remote-write >/dev/null 2>&1 \
      || die "Secret monitoring/tpg-remote-write was not synced from Vault (tpg/shared/monitoring-remote-write): $(k -n monitoring get vaultstaticsecret tpg-remote-write -o json 2>/dev/null | jq -r '[.status.conditions[]? | .type + "=" + .status + " " + (.message // "")] | join("; ")')"
    say "remote-write credential (Vault) and CA are in place"
  fi
  hr_merge_values "$m" "$FLEET_DIR/monitoring/standalone/targets/kps-values.yaml" \
    "$(CL="$CLUSTER" RW="$RW_URL" hr_overlay kps-target '.prometheus.prometheusSpec.externalLabels.cluster = strenv(CL)
      | .prometheus.prometheusSpec.remoteWrite = [{
          "url": strenv(RW),
          "basicAuth": {"username": {"name": "tpg-remote-write", "key": "username"},
                        "password": {"name": "tpg-remote-write", "key": "password"}},
          "tlsConfig": {"ca": {"secret": {"name": "tpg-remote-write-ca", "key": "ca.crt"}}}}]')"
  hr_release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring "$m" ""
  hr_merge_values "$s" "$FLEET_DIR/monitoring/ksm/values.yaml" "$(hr_overlay ksm '.prometheus.monitor.enabled = true')"
  hr_release tpg-ksm kube-state-metrics "$KSM_VERSION" "$PROM_REPO" monitoring "$s" ""
  [[ "$DRY_RUN" -eq 1 ]] && return
  k apply -k "$FLEET_DIR/monitoring/standalone/targets" -n monitoring >/dev/null
  say "applied monitoring/standalone/targets (PodMonitor)"
  pods_watch monitoring 600 --kubectl k --selector app.kubernetes.io/name=prometheus --label "Prometheus (remote write to the hub)" \
    || die "the target Prometheus is not ready: ${POD_WATCH_REASON} ${POD_WATCH_DETAIL}"
}

vso() {
  [[ -n "$VAULT_ADDR_ARG" && -f "$VAULT_CA_FILE" && -n "$VAULT_AUTH_MOUNT" && -n "$VAULT_AUTH_ROLE" ]] \
    || die "component vso needs --vault-addr, --vault-ca-file, --vault-auth-mount and --vault-auth-role"
  # Namespaces whose VaultStaticSecrets may use the VaultAuth: every namespace on
  # a target; on the hub argocd (repository Secrets) and argo (log archive key).
  local m="$HR_TMP/vso.yaml" allowed="*"
  [[ "$ROLE" == "hub" ]] && allowed="argocd,argo"
  hr_merge_values "$m" "$FLEET_DIR/vault/vso-values.yaml"
  hr_release vault-secrets-operator vault-secrets-operator "$VSO_VERSION" "$HASHICORP_REPO" vault-secrets-operator-system "$m" ""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "dry run: would apply VaultConnection and VaultAuth tpg-vault/tpg-vault (${VAULT_ADDR_ARG}, auth/${VAULT_AUTH_MOUNT}, role ${VAULT_AUTH_ROLE}, namespaces ${allowed})"
    return
  fi
  k wait --for=condition=Established --timeout=120s \
    crd/vaultconnections.secrets.hashicorp.com crd/vaultauths.secrets.hashicorp.com crd/vaultstaticsecrets.secrets.hashicorp.com >/dev/null \
    || die "VSO CRDs are not established"
  k create namespace tpg-vault --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n tpg-vault create secret generic vault-ca --from-file=ca.crt="$VAULT_CA_FILE" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  sed -e "s|@VAULT_ADDR@|${VAULT_ADDR_ARG}|" -e "s|@AUTH_MOUNT@|${VAULT_AUTH_MOUNT}|" \
      -e "s|@AUTH_ROLE@|${VAULT_AUTH_ROLE}|" "$FLEET_DIR/vault/tpg-vault-objects.yaml" \
    | NS="$allowed" yq '(select(.kind == "VaultAuth") | .spec.allowedNamespaces) = (strenv(NS) | split(","))' \
    | k apply -f - >/dev/null
  say "applied VaultConnection and VaultAuth tpg-vault/tpg-vault (${VAULT_ADDR_ARG}, auth/${VAULT_AUTH_MOUNT}, role ${VAULT_AUTH_ROLE}, namespaces ${allowed})"
}

vault_server() {
  local mode="${VAULT_UNSEAL_MODE:-shamir}" cfg="$HR_TMP/vault-config.hcl" m="$HR_TMP/vault.yaml" wi="" note=""
  case "$mode" in
    shamir)
      cp "$FLEET_DIR/vault/config-shamir.hcl" "$cfg"
      note="unseal mode shamir: an upgrade restarts vault-0, which then needs 3 unseal keys" ;;
    azure-keyvault)
      local v
      for v in VAULT_AKV_TENANT_ID VAULT_AKV_NAME VAULT_AKV_KEY_NAME VAULT_AKV_CLIENT_ID; do
        [[ "${!v:-}" =~ ^[A-Za-z0-9-]+$ ]] || die "${v} is required for unseal mode azure-keyvault (letters, digits and '-')"
      done
      sed -e "s|@TENANT_ID@|${VAULT_AKV_TENANT_ID}|" -e "s|@KEY_VAULT_NAME@|${VAULT_AKV_NAME}|" \
          -e "s|@KEY_NAME@|${VAULT_AKV_KEY_NAME}|" "$FLEET_DIR/vault/config-azure-keyvault.hcl" > "$cfg"
      # Workload identity: pod label plus the client ID on the ServiceAccount
      wi="$(CID="$VAULT_AKV_CLIENT_ID" hr_overlay vault-wi '.server.extraLabels["azure.workload.identity/use"] = "true"
        | .server.serviceAccount.annotations["azure.workload.identity/client-id"] = strenv(CID)')" ;;
    *) die "VAULT_UNSEAL_MODE must be shamir or azure-keyvault (got ${mode})" ;;
  esac
  local files=("$FLEET_DIR/vault/vault-values.yaml"
               "$(CFG="$cfg" hr_overlay vault-config '.server.standalone.config = load_str(strenv(CFG))
                  | .server.updateStrategyType = "RollingUpdate"')")
  [[ -z "$wi" ]] || files+=("$wi")
  hr_merge_values "$m" "${files[@]}"
  # vault-0 only becomes Ready once initialized and unsealed (35-vault.sh), so no --wait.
  HR_NO_WAIT=1 hr_release vault vault "$VAULT_CHART_VERSION" "$HASHICORP_REPO" vault "$m" "$note"
}

for comp in ${COMPONENTS//,/ }; do
  case "${ROLE}/${comp}" in
    target/cert-manager) cert_manager ;;
    hub/cert-manager) say "cert-manager is not installed on the hub (no Postgres instances there); skipping" ;;
    hub/monitoring) monitoring_hub ;;
    target/monitoring) monitoring_target ;;
    */vso) vso ;;
    hub/vault) vault_server ;;
    target/vault) die "component vault is installed on the hub only" ;;
    *) die "unknown component ${comp}" ;;
  esac
done
say "done: ${COMPONENTS} (${ROLE})"
