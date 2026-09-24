#!/usr/bin/env bash
# Import the dashboards (fleet, instance overview, replication and HA,
# backup/WAL/restore, alerts) and the Grafana-managed alert rules into Azure
# Managed Grafana (monitoring option azure). Also run by tpg-aks-infra
# scripts/steps/45-helm-addons.sh when the inventory names the Grafana.
# Usage: monitoring/grafana/import-azure-grafana.sh <resource-group> <grafana-name>
# Requires: az (with the amg extension), curl, jq, sed. Your identity needs the
# Grafana Admin role on the instance (Terraform assigns it to the deploying user).
set -euo pipefail

RG="${1:?resource group}"
NAME="${2:?Azure Managed Grafana name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

az extension add --name amg --upgrade --only-show-errors >/dev/null
ENDPOINT="$(az grafana show -g "$RG" -n "$NAME" --query properties.endpoint -o tsv)"
# Entra ID token for the Azure Managed Grafana resource application
TOKEN="$(az account get-access-token --resource ce34e7e5-485f-4d76-964f-b3d2b16d1e4f --query accessToken -o tsv)"
api() { curl -sS --fail-with-body -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"; }

DS_UID="$(api "${ENDPOINT}/api/datasources" | jq -r '[.[] | select(.type == "prometheus" and (.name | startswith("Managed_Prometheus")))][0].uid // empty')"
[[ -n "$DS_UID" ]] || { echo "No Managed_Prometheus data source found; link the Azure Monitor workspace first" >&2; exit 1; }
echo "Using data source ${DS_UID}"

if ! api "${ENDPOINT}/api/folders/tpg-postgres" >/dev/null 2>&1; then
  api -X POST "${ENDPOINT}/api/folders" -d '{"uid":"tpg-postgres","title":"Tanzu Postgres"}' >/dev/null
fi

# Every dashboard of the standalone option (fleet, instance overview,
# replication and HA, backup/WAL/restore, alerts) into the Tanzu Postgres folder.
# Their data source variable picks the Managed_Prometheus data source.
for d in "${ROOT}"/monitoring/standalone/hub/dashboards/*.json; do
  az grafana dashboard import -g "$RG" -n "$NAME" --overwrite true --folder tpg-postgres \
    --definition "@${d}" >/dev/null
  echo "imported dashboard $(jq -r '.title' "$d")"
done

for f in "${ROOT}"/monitoring/grafana/alerts/api/*.json; do
  uid="$(jq -r '.uid' "$f")"
  body="$(sed "s/\${DATASOURCE_UID}/${DS_UID}/g" "$f")"
  if api "${ENDPOINT}/api/v1/provisioning/alert-rules/${uid}" >/dev/null 2>&1; then
    api -X PUT -H "X-Disable-Provenance: true" "${ENDPOINT}/api/v1/provisioning/alert-rules/${uid}" -d "$body" >/dev/null
    echo "updated ${uid}"
  else
    api -X POST -H "X-Disable-Provenance: true" "${ENDPOINT}/api/v1/provisioning/alert-rules" -d "$body" >/dev/null
    echo "created ${uid}"
  fi
done
echo "Done: ${ENDPOINT}/dashboards/f/tpg-postgres"
