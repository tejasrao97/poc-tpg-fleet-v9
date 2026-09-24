#!/usr/bin/env bash
# workflows/scripts/helm-addons.sh against a Helm 4 CLI.
#
# The stubs in tests/helm4/bin parse flags the way Helm 4 and kubectl do and
# serve cluster state from a JSON file, so the add-on pre-check runs end to end
# with no cluster. A Helm-3-only flag (helm list -a) makes the stub exit 1 with
# helm's own "unknown shorthand flag" message, which fails the case it appears
# in. That is the regression this suite guards.
#
# Requires: bash, python3, yq (mikefarah v4), jq, diff.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ADDONS="${ROOT}/workflows/scripts/helm-addons.sh"

for c in python3 jq yq; do command -v "$c" >/dev/null || { echo "SKIP tests/helm4: $c not installed" >&2; exit 0; }; done
yq --version 2>/dev/null | grep -q mikefarah || { echo "SKIP tests/helm4: yq is not the mikefarah build" >&2; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PATH="${HERE}/bin:${PATH}"
export STUB_HELM_LOG="$TMP/helm.log" STUB_KUBECTL_LOG="$TMP/kubectl.log"
PASS=0; FAIL=0

# case NAME EXPECTED_ADDON_LINE -- helm-addons.sh args...
case_run() {
  local name="$1" expect="$2"; shift 2; [[ "$1" == "--" ]] && shift
  : > "$STUB_HELM_LOG"; : > "$STUB_KUBECTL_LOG"
  local out rc=0
  out="$(bash "$ADDONS" "$@" 2>"$TMP/stderr")" || rc=$?
  if grep -q "unknown shorthand flag\|unknown flag" "$TMP/stderr"; then
    printf 'FAIL %-42s a flag this Helm does not accept: %s\n' "$name" \
      "$(grep -m1 'unknown .*flag' "$TMP/stderr")"; FAIL=$((FAIL + 1)); return
  fi
  if grep -q "unbound variable" "$TMP/stderr"; then
    printf 'FAIL %-42s unset variable under set -u: %s\n' "$name" \
      "$(grep -m1 'unbound variable' "$TMP/stderr")"; FAIL=$((FAIL + 1)); return
  fi
  if grep -qF "$expect" <<<"$out"; then
    printf 'ok   %-42s %s\n' "$name" "$expect"; PASS=$((PASS + 1))
  else
    printf 'FAIL %-42s expected %-32s got: %s (exit %s)\n' "$name" "$expect" \
      "$(grep '^ADDON' <<<"$out" | paste -sd'; ' - || echo '<no ADDON line>')" "$rc"
    sed 's/^/       | /' "$TMP/stderr" | tail -5
    FAIL=$((FAIL + 1))
  fi
}

state() { cat > "$TMP/$1.json"; }
use() { export STUB_HELM_STATE="$TMP/$1.json" STUB_KUBECTL_STATE="$TMP/$2.json"; }

# ------------------------------------------------------------------ fixtures
state empty-helm     <<< '{"releases": []}'
state empty-cluster  <<< '{"crds": [], "deployments": [], "statefulsets": [], "secrets": [], "services": []}'
state ours-current   <<< '{"releases": [{"name": "cert-manager", "namespace": "cert-manager",
  "chart": "cert-manager-v1.21.2", "app_version": "v1.21.2", "status": "deployed", "revision": 2,
  "values": {"crds": {"enabled": true}}}]}'
state ours-old       <<< '{"releases": [{"name": "cert-manager", "namespace": "cert-manager",
  "chart": "cert-manager-v1.16.0", "app_version": "v1.16.0", "status": "deployed", "revision": 1,
  "values": {"crds": {"enabled": true}}}]}'
state ours-newer     <<< '{"releases": [{"name": "cert-manager", "namespace": "cert-manager",
  "chart": "cert-manager-v1.99.0", "app_version": "v1.99.0", "status": "deployed", "revision": 1,
  "values": {"crds": {"enabled": true}}}]}'
state superseded     <<< '{"releases": [{"name": "cert-manager", "namespace": "cert-manager",
  "chart": "cert-manager-v1.21.2", "app_version": "v1.21.2", "status": "superseded", "revision": 1,
  "values": {"crds": {"enabled": true}}}]}'
state foreign-cm     <<< '{"crds": ["certificates.cert-manager.io"], "statefulsets": [], "secrets": [], "services": [],
  "deployments": [{"namespace": "security", "name": "cert-manager",
    "image": "quay.io/jetstack/cert-manager-controller:v1.20.1", "availableReplicas": 1}]}'
state foreign-old-cm <<< '{"crds": ["certificates.cert-manager.io"], "statefulsets": [], "secrets": [], "services": [],
  "deployments": [{"namespace": "security", "name": "cert-manager",
    "image": "quay.io/jetstack/cert-manager-controller:v1.10.0", "availableReplicas": 1}]}'
state foreign-kps    <<< '{"crds": ["prometheuses.monitoring.coreos.com"], "statefulsets": [], "secrets": [], "services": [],
  "deployments": [{"namespace": "obs", "name": "prom-operator",
    "image": "quay.io/prometheus-operator/prometheus-operator:v0.80.0", "availableReplicas": 1}]}'

T=(--cluster aks-tpg-poc-01 --role target --components cert-manager --fleet-dir "$ROOT" --dry-run --existing skip)
H=(--cluster aks-tpg-hub --role hub --components monitoring --fleet-dir "$ROOT" --dry-run --existing skip)

# ------------------------------------------------------------------ cases
use empty-helm empty-cluster
case_run "not installed -> DRY_RUN install" "ADDON cert-manager DRY_RUN" -- "${T[@]}"

use ours-current empty-cluster
case_run "our release, same chart -> UP_TO_DATE" "ADDON cert-manager UP_TO_DATE" -- "${T[@]}"

use ours-old empty-cluster
case_run "our release, older chart -> SKIPPED_EXISTS" "ADDON cert-manager SKIPPED_EXISTS" -- "${T[@]}"

use ours-old empty-cluster
case_run "our release, older chart, upgrade -> DRY_RUN" "ADDON cert-manager DRY_RUN" -- \
  --cluster aks-tpg-poc-01 --role target --components cert-manager --fleet-dir "$ROOT" --dry-run --existing upgrade

use ours-newer empty-cluster
case_run "installed chart newer -> SKIPPED_NEWER" "ADDON cert-manager SKIPPED_NEWER" -- "${T[@]}"

# Only a superseded revision exists. Helm 3 needed -a to see it; Helm 4 lists it
# by default and the explicit state flags select it on both.
use superseded empty-cluster
case_run "superseded revision is seen" "ADDON cert-manager" -- "${T[@]}"

use empty-helm foreign-cm
case_run "foreign cert-manager v1.20.1 -> REUSED" "ADDON cert-manager REUSED_EXISTING" -- "${T[@]}"

use empty-helm foreign-old-cm
case_run "foreign cert-manager v1.10.0 -> BLOCKED" "ADDON cert-manager BLOCKED" -- "${T[@]}"

use empty-helm foreign-kps
case_run "foreign kube-prometheus-stack -> BLOCKED" "ADDON kps BLOCKED" -- "${H[@]}"

# KPS_HUB_EXTRA_VALUES unset: helm-addons.sh runs with set -u, so an unguarded
# ${KPS_HUB_EXTRA_VALUES//,/ } aborts the hub monitoring install before anything
# is installed. monitoring_hub() reads it through a defaulted local for that reason.
unset KPS_HUB_EXTRA_VALUES || true
use empty-helm empty-cluster
case_run "hub monitoring, extra values unset" "ADDON kps DRY_RUN" -- "${H[@]}"

export KPS_HUB_EXTRA_VALUES="monitoring/grafana/smtp/grafana-smtp-values.yaml"
case_run "hub monitoring, extra values set" "ADDON kps DRY_RUN" -- "${H[@]}"
unset KPS_HUB_EXTRA_VALUES

# ------------------------------------------------------------------ guard
# The stub rejects helm list -a exactly as Helm 4 does. Prove the guard works,
# so a passing suite cannot mean "the stub accepts anything".
if PATH="${HERE}/bin:$PATH" helm list -A -a -o json >/dev/null 2>"$TMP/guard"; then
  printf 'FAIL %-42s the stub accepted "helm list -a"\n' "stub rejects Helm 3 flags"; FAIL=$((FAIL + 1))
elif grep -q "unknown shorthand flag: 'a'" "$TMP/guard"; then
  printf 'ok   %-42s helm list -a is rejected as in Helm 4\n' "stub rejects Helm 3 flags"; PASS=$((PASS + 1))
else
  printf 'FAIL %-42s unexpected stub error: %s\n' "stub rejects Helm 3 flags" "$(cat "$TMP/guard")"; FAIL=$((FAIL + 1))
fi

echo
echo "helm4: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
