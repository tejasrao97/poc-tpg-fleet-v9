#!/usr/bin/env bash
# day0-precheck.sh WORKFLOW_NAME CLUSTER
# Read-only. Records precheck.<cluster> = PASSED | MANAGED | BLOCKED (design decision D5).
WF="$1"; C="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

# A version the cluster already runs differently (fleet-day0.sh): not changed by this run
blocked="$(run_data "block.${C}")"
if [[ -n "$blocked" ]]; then
  record "precheck.${C}" BLOCKED "$(jq -r '.reason' <<<"$blocked")" "$(jq -r '.detail' <<<"$blocked")"
  exit 0
fi

if ! use_cluster "$C" || ! tk get --raw=/readyz >/dev/null 2>&1; then
  record "precheck.${C}" BLOCKED UNREACHABLE "API server not reachable from the hub"
  exit 0
fi

STATUS=PASSED; MANAGED=false; REASONS=()
tracked_by() {  # tracked_by JSON APP -> 0 when the object is tracked by that Argo CD app
  jq -e --arg a "$2:" '(.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($a)' <<<"$1" >/dev/null
}
block() { STATUS=BLOCKED; REASONS+=("$1"); }

# 1. Postgres operator
while read -r d; do
  [[ -z "$d" ]] && continue
  if tracked_by "$d" "tpg-${C}-operator"; then MANAGED=true
  else block "FOREIGN_OPERATOR:$(jq -r '.metadata.namespace + "/" + .metadata.name' <<<"$d")"; fi
done < <(tk get deploy -A -l app=postgres-operator -o json | jq -c '.items[]')

# 2. Postgres CRDs
while read -r c; do
  [[ -z "$c" ]] && continue
  if tracked_by "$c" "tpg-${C}-operator"; then MANAGED=true
  else block "FOREIGN_CRD:$(jq -r '.metadata.name' <<<"$c")"; fi
done < <(tk get crd -o json | jq -c '.items[] | select(.metadata.name | endswith(".sql.tanzu.vmware.com"))')

# 3. Same-named Postgres instances (instances declared in Git for this cluster)
if tk get crd postgres.sql.tanzu.vmware.com >/dev/null 2>&1; then
  ALL="$(tk get postgres -A -o json)"
  for i in $(inventory_instances "$C"); do
    while read -r p; do
      [[ -z "$p" ]] && continue
      tracked_by "$p" "tpg-${C}-${i}" || block "INSTANCE_NAME_IN_USE:${i}"
    done < <(jq -c --arg n "$i" '.items[] | select(.metadata.name == $n)' <<<"$ALL")
  done
fi

# 4. Declared Postgres versions exist (only possible once the operator is installed)
if [[ "$STATUS" == "PASSED" && "$MANAGED" == "true" ]]; then
  while read -r v; do
    [[ -z "$v" ]] && continue
    tk get postgresversion "$v" >/dev/null 2>&1 || block "VERSION_NOT_AVAILABLE:${v}"
  done < <(inventory_cluster "$C" | jq -r '.instances[].postgresVersion' | sort -u)
fi

# 5. High availability needs a pgdata pool that spans three zones with three nodes.
#    The rule applies to the pgdata pool only, and only when this run deploys an
#    HA instance; a single-node instance runs on any pool shape.
if [[ "$(inventory_cluster "$C" | jq '[.instances[] | select(.highAvailability)] | length')" -gt 0 ]]; then
  nodes="$(tk get nodes -l tpg.fleet/pool=postgres -o json 2>/dev/null | jq -c '.items')"
  [[ "$(jq 'length' <<<"${nodes:-[]}")" -gt 0 ]] \
    || nodes="$(tk get nodes -l agentpool=pgdata -o json 2>/dev/null | jq -c '.items')"
  if [[ "$(jq 'length' <<<"${nodes:-[]}")" -eq 0 ]]; then
    # No labelled data pool (a pre-created cluster may not use one): fall back to
    # every schedulable node that does not carry the system-pool taint.
    nodes="$(tk get nodes -o json 2>/dev/null | jq -c '[.items[]
      | select(any(.spec.taints[]? ; .key == "CriticalAddonsOnly") | not)]')"
  fi
  ready="$(jq '[.[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${nodes:-[]}")"
  zones="$(jq -r '[.[] | .metadata.labels["topology.kubernetes.io/zone"] // empty] | unique | length' <<<"${nodes:-[]}")"
  if [[ "${ready:-0}" -lt 3 || "${zones:-0}" -lt 3 ]]; then
    block "PGDATA_POOL_NOT_HA_CAPABLE:${ready:-0} Ready nodes in ${zones:-0} zone(s), highAvailability needs 3 nodes across 3 zones"
  fi
fi

[[ "$STATUS" == "PASSED" && "$MANAGED" == "true" ]] && STATUS=MANAGED
record "precheck.${C}" "$STATUS" "$(IFS=,; echo "${REASONS[*]:-}")"
