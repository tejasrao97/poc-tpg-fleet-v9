#!/usr/bin/env bash
# upgrade-cluster.sh WORKFLOW_NAME CLUSTER
# tpg-upgrade, one cluster: the operator first, then the Postgres instances.
#   Without clusterMap: component=operator runs operator-upgrade.sh with
#   targetVersion; component=postgres runs postgres-upgrade.sh with targetVersion
#   and instances.
#   With clusterMap: the cluster's operatorVersion (else targetVersion when
#   component=operator) upgrades the operator; the instances with postgresVersion
#   (else targetVersion when component=postgres) are upgraded next. component,
#   when set, limits the run to that part.
# Exits 1 when a part failed; the Postgres part does not start after a failed
# operator upgrade.
WF="$1"; C="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
TIMEOUT="${P_TIMEOUT:-1800}"
COMP="${P_COMPONENT:-}"

if ! cmap_set; then
  if [[ "$COMP" == "operator" ]]; then
    exec bash /scripts/operator-upgrade.sh "$WF" "$C" "$P_TARGET_VERSION" "$TIMEOUT"
  fi
  exec bash /scripts/postgres-upgrade.sh "$WF" "$C" "$P_TARGET_VERSION" "$P_INSTANCES" "$TIMEOUT"
fi

rc=0
if [[ "$COMP" != "postgres" ]]; then
  opv="$(cmap_cval "$C" operatorVersion "$([[ "$COMP" == "operator" ]] && printf '%s' "${P_TARGET_VERSION:-}")")"
  if [[ -n "$opv" ]]; then
    bash /scripts/operator-upgrade.sh "$WF" "$C" "$opv" "$TIMEOUT" || rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
  fi
fi
if [[ "$COMP" != "operator" ]]; then
  default_pgv=""; [[ "$COMP" != "postgres" ]] || default_pgv="${P_TARGET_VERSION:-}"
  sel=()
  for i in $(cmap_instances "$C"); do
    [[ -n "$(cmap_ival "$C" "$i" postgresVersion "$default_pgv")" ]] && sel+=("$i")
  done
  if [[ "${#sel[@]}" -gt 0 ]]; then
    # postgres-upgrade.sh reads each instance's target, preUpgradeBackup and
    # allowMajor from clusterMap, with targetVersion and the inputs as defaults
    bash /scripts/postgres-upgrade.sh "$WF" "$C" "$default_pgv" "$(IFS=,; echo "${sel[*]}")" "$TIMEOUT" || rc=$?
  fi
fi
exit "$rc"
