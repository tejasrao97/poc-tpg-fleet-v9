#!/usr/bin/env bash
# addons-cluster.sh WORKFLOW_NAME CLUSTER COMPONENTS DRY_RUN [RESULT_KEY] [EXISTING]
# Install or upgrade the Helm add-on releases on one target cluster with helm-addons.sh.
# COMPONENTS: auto (cert-manager and vso, plus monitoring when tpg-settings
# monitoringOption is standalone) or a comma-separated list of cert-manager, vso
# and monitoring.
# EXISTING: skip (default) or upgrade, for releases that already exist with a
# different chart version or values (helm-addons.sh pre-check; never downgrades).
# MONITORING_OPTION in the environment overrides tpg-settings monitoringOption.
# The result detail lists every release with its pre-check outcome, for example
#   cert-manager=UP_TO_DATE vault-secrets-operator=INSTALLED kps=SKIPPED_EXISTS
# Monitoring: standalone checks that the cluster's metrics reach the hub
# Prometheus within MONITORING_FLOW_TIMEOUT (300 s); azure checks the ama-metrics
# agent pods. Either failure is MONITORING_NOT_FLOWING.
WF="$1"; C="$2"; COMPONENTS="$3"; DRY="${4:-false}"; KEY="${5:-result.${C}}"; EXISTING="${6:-skip}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

fail() { record "$KEY" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$KEY"
use_cluster "$C" || fail NOT_REGISTERED
case "$EXISTING" in skip|upgrade) ;; *) fail INVALID_EXISTING "$EXISTING (skip or upgrade)" ;; esac
option="${MONITORING_OPTION:-}"; [[ -n "$option" ]] || option="$(setting monitoringOption)"; option="${option:-none}"
if [[ "$COMPONENTS" == "auto" ]]; then
  COMPONENTS="cert-manager,vso"
  [[ "$option" == "standalone" ]] && COMPONENTS="cert-manager,vso,monitoring"
fi
args=(--cluster "$C" --role target --components "$COMPONENTS" --kubeconfig "/tmp/kube/${C}" --existing "$EXISTING")
if [[ ",${COMPONENTS}," == *",monitoring,"* ]]; then
  url="$(setting hubPrometheusRemoteWriteUrl)"
  [[ -n "$url" ]] || fail NO_REMOTE_WRITE_URL "tpg-settings hubPrometheusRemoteWriteUrl is empty: run tpg-aks-infra scripts/run.sh --only addons first"
  args+=(--remote-write-url "$url")
fi
if [[ ",${COMPONENTS}," == *",vso,"* ]]; then
  addr="$(setting vaultFleetAddr)"
  [[ -n "$addr" ]] || fail NO_VAULT_ADDRESS "tpg-settings vaultFleetAddr is empty: run tpg-aks-infra scripts/run.sh --only hub-secrets"
  secret_val vault-ca ca.crt > /tmp/vault-ca.crt
  [[ -s /tmp/vault-ca.crt ]] || fail NO_VAULT_CA "Secret argo/vault-ca is missing: run tpg-aks-infra scripts/run.sh --only vault"
  args+=(--vault-addr "$addr" --vault-ca-file /tmp/vault-ca.crt --vault-auth-mount "k8s-${C}" --vault-auth-role tpg-vso)
fi
[[ "$DRY" == "true" ]] && args+=(--dry-run)
git_clone "$WORK/repo"
args+=(--fleet-dir "$WORK/repo")
rc=0
out="$(bash /scripts/helm-addons.sh "${args[@]}")" || rc=$?
summary="$(awk '$1 == "ADDON" {printf "%s%s=%s", (n++ ? " " : ""), $2, $3}' <<<"$out")"
if [[ "$rc" -ne 0 ]]; then
  blocked="$(awk '$1 == "ADDON" && $3 == "BLOCKED" {$1=$3=""; sub(/^ +/, ""); print; exit}' <<<"$out")"
  fail HELM_RELEASE_FAILED "${summary:-$COMPONENTS}${blocked:+; blocked: ${blocked}}"
fi
if [[ "$DRY" == "true" ]]; then
  record "$KEY" SUCCEEDED DRY_RUN "${summary:-$COMPONENTS}"
  exit 0
fi

# Monitoring integration with the hub, for a new cluster as for an existing one
case "$option" in
  standalone)
    if [[ ",${COMPONENTS}," == *",monitoring,"* ]]; then
      # The hub Prometheus is queried through the API service proxy (Role
      # monitoring/tpg-workflow-prometheus-query, created by the addons step).
      monitoring_flowing kubectl "$C" "${MONITORING_FLOW_TIMEOUT:-300}" tk \
        || fail MONITORING_NOT_FLOWING "${summary:-$COMPONENTS}; no metrics from ${C} on the hub Prometheus after ${MONITORING_FLOW_TIMEOUT:-300}s: check the target Prometheus remote-write errors above and the hub gateway (kubectl -n monitoring logs deploy/tpg-remote-write)"
      summary="${summary:+${summary} }metrics=FLOWING"
    fi ;;
  azure)
    # The managed Prometheus add-on is an AKS setting, enabled with az by the
    # tpg-aks-infra addons step; here only its agent pods are checked.
    if [[ -n "$(tk -n kube-system get pods -l rsName=ama-metrics -o name 2>/dev/null)" ]]; then
      pods_watch kube-system 600 --kubectl tk --selector rsName=ama-metrics --label "Azure Monitor metrics agent" \
        || fail MONITORING_NOT_FLOWING "ama-metrics pods on ${C}: ${POD_WATCH_REASON} ${POD_WATCH_DETAIL}"
      summary="${summary:+${summary} }ama-metrics=READY"
    else
      fail MONITORING_NOT_FLOWING "no Azure Monitor metrics agent (ama-metrics) on ${C}: run tpg-aks-infra scripts/run.sh ... --only addons (MONITORING_OPTION=azure) to enable the managed Prometheus add-on for this cluster"
    fi ;;
esac
record "$KEY" SUCCEEDED "" "${summary:-$COMPONENTS}"
