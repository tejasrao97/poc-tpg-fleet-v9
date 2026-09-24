#!/usr/bin/env bash
# Every offline test suite. Usage: tests/run-all.sh [--against-cli]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"

echo "=== tests/cli-flags"
bash "${HERE}/cli-flags/run.sh" ${ARG:+"$ARG"}
for suite in helm4 shared-lib sync-engine rollout params cluster-map patch admission ssa; do
  echo
  echo "=== tests/${suite}"
  bash "${HERE}/${suite}/run.sh"
done

INFRA="${FLEET_SIBLING:-$(cd "${HERE}/../.." && pwd)/tpg-aks-infra}"
if [[ -x "${INFRA}/tests/verify/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/verify"
  FLEET_LOCAL_DIR="$(cd "${HERE}/.." && pwd)" bash "${INFRA}/tests/verify/run.sh"
fi
if [[ -f "${INFRA}/tests/argocd-rbac/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/argocd-rbac"
  bash "${INFRA}/tests/argocd-rbac/run.sh"
fi
echo
echo "All test suites passed"
