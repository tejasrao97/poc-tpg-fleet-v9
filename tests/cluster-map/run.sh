#!/usr/bin/env bash
# clusterMap and the list inputs: workflows/scripts/validate-params.sh (with
# clustermap.py and workflows/params/cluster-map-keys.yaml), the clusterMap
# accessors of lib.sh, and fleet-day0.sh (tpg-day0 values and the version rule).
#
# validate-params.sh runs with the real lib.sh and a stub kubectl that lists the
# registered clusters. fleet-day0.sh runs with the real lib.sh and stubs for
# Git, the run ConfigMap and the target clusters (what each one runs), as a dry
# run, so the planned clusters/fleet.yaml is read from /tmp/fleet.json.
#
# Requires: bash 4, python3, jq, yq (mikefarah).
# ok() and bad() always return 0; single-quoted snippets are jq, yq or YAML.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq; do command -v "$t" >/dev/null || { echo "SKIP tests/cluster-map: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/cluster-map: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }

# ---- stub kubectl: registered clusters
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"get secret -l tpg.fleet/cluster"* ]]; then
  printf '{"items":[%s]}' "$(for c in aks-tpg-poc-01 aks-tpg-poc-02 aks-tpg-poc-03; do
    printf '{"metadata":{"labels":{"tpg.fleet/cluster":"%s"}}},' "$c"; done | sed 's/,$//')"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
sed "s#source /scripts/lib.sh#source $ROOT/workflows/scripts/lib.sh#" "$ROOT/workflows/scripts/validate-params.sh" > "$TMP/validate.sh"

vp() {  # vp MODE VAR=VALUE... -> runs validate-params.sh; output in $OUT, status in $RC
  local mode="$1"; shift
  rm -rf "$TMP/work"
  RC=0; OUT="$(cd "$TMP" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TPG_WORK="$TMP/work" "$@" \
    bash "$TMP/validate.sh" "$mode" 2>&1)" || RC=$?
}
valid() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
invalid() {  # invalid LABEL TEXT...
  local t
  [[ "$RC" -ne 0 ]] || { bad "$1 (accepted)" "$OUT"; return; }
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (no '$t')" "$OUT"; return; }; done
  ok "$1"
}

MAP_OK='aks-tpg-poc-01:
  operatorVersion: 4.5.0
  instances:
    orders-db:
      postgresVersion: 16.10
      highAvailability: true
      storageSize: 50Gi
      cpu: "2"
    billing-db:
      postgresVersion: postgres-17.6
      highAvailability: false
      enableSSL: true
aks-tpg-poc-02:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 2}'

# ---- tpg-day0
vp day0 P_CLUSTER_MAP="$MAP_OK" P_PUSH_MODE=direct
valid "day0: a YAML clusterMap with per-instance keys is valid"
[[ "$(cat /tmp/selection)" == "aks-tpg-poc-01,aks-tpg-poc-02" && "$(jq -c . /tmp/clusters.json)" == '["aks-tpg-poc-01","aks-tpg-poc-02"]' ]] \
  && ok "day0: the selection and the cluster list come from the map" || bad "day0 selection" "$(cat /tmp/selection) $(cat /tmp/clusters.json)"
jq -e '.["aks-tpg-poc-01"].instances["orders-db"].postgresVersion == "postgres-16.10" and .["aks-tpg-poc-01"].operatorVersion == "v4.5.0"' \
  "$TMP/work/cmap.json" >/dev/null && ok "day0: an unquoted 16.10 stays postgres-16.10; 4.5.0 becomes v4.5.0" || bad "day0 normalize" "$(cat "$TMP/work/cmap.json")"
vp day0 P_CLUSTER_MAP='{"aks-tpg-poc-01":{"operatorVersion":"v4.5.0","instances":{"orders-db":{"postgresVersion":"17.6","highAvailability":true}}}}' P_PUSH_MODE=pr
valid "day0: a JSON clusterMap is valid"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders_db: {postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: orders_db is refused with a valid name suggested" "clusterMap.aks-tpg-poc-01.instances.orders_db" "(for example orders-db)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-1:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: an unregistered cluster is refused with the closest registered one" "cluster 'aks-tpg-poc-1' is not registered (did you mean aks-tpg-poc-01?)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVerison: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: a misspelled key is refused with the closest key" "unknown key postgresVerison (did you mean postgresVersion?)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {operatorVersion: v4.5.0, postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: operatorVersion on an instance is refused (a cluster key)" "operatorVersion is a cluster key: put it next to instances" "operatorVersion is required"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' P_OPERATOR_VERSION=v4.5.0 P_PUSH_MODE=direct
valid "day0: the operatorVersion input is the default of a cluster without the key"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", replicas: 2, highAvailability: yes}' P_PUSH_MODE=direct
invalid "day0: a key of another workflow and a bad boolean are refused" "replicas: not used by tpg-day0 (used by tpg-scale-instance)" "'yes' must be true or false"
vp day0 P_CLUSTER_MAP="$MAP_OK" P_CLUSTERS=all P_PUSH_MODE=direct
invalid "day0: clusterMap and clusters together are refused" "clusterMap and clusters cannot be used together"
vp day0 P_CLUSTERS=all P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0: the list inputs without clusterMap stay valid"
vp day0 P_CLUSTER_MAP='just words' P_PUSH_MODE=direct
invalid "day0: a clusterMap that is not a mapping is refused" "clusterMap must be a mapping"

# ---- tpg-scale-instance
vp scale P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_INSTANCES=orders-db,billing-db P_REPLICAS=2 P_PUSH_MODE=direct
valid "scale: clusters and instances lists are valid"
vp scale P_CLUSTERS=all P_INSTANCES=orders-db P_REPLICAS=2 P_PUSH_MODE=direct
invalid "scale: clusters=all is refused" "clusters does not accept all"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "scale: replicas is required (map key or input)" "orders-db: replicas is required (the map key replicas or the workflow input replicas)"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {replicas: 3, enableHAIfNeeded: false}, billing-db: {}}}' P_REPLICAS=1 P_PUSH_MODE=direct
valid "scale: the replicas input is the default of an instance without the key"

# ---- tpg-backup and tpg-backup-retention
vp backup P_CLUSTERS=all
valid "backup: clusters=all (the CronWorkflows) is valid"
vp backup P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {backupType: incremental, backupTimeoutSeconds: 600}}}'
valid "backup: a clusterMap with backupType and backupTimeoutSeconds is valid"
vp backup P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {backupType: weekly}}}'
invalid "backup: an unknown backupType is refused" "'weekly' must be one of full, incremental, differential"
vp backup-retention P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {retentionDays: 0}}}'
invalid "backup-retention: retentionDays 0 is refused" "'0' must be a positive integer"

# ---- tpg-delete-instance and tpg-delete-apps
vp delete-instance P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_INSTANCES=orders-db,billing-db P_CONFIRM=billing-db,orders-db
valid "delete-instance: confirm repeats the instances (any order)"
vp delete-instance P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_CONFIRM=orders
invalid "delete-instance: a confirm that differs is refused" "confirm must repeat the instances value"
vp restore P_SOURCE_CLUSTER=aks-tpg-poc-01 P_INSTANCE=orders-db P_MODE=backup P_BACKUP_NAME=orders-db-full-1
invalid "restore: mode=backup without targetInstance is refused before the run" "mode=backup restores only inside the source namespace" "targetInstance=orders-db"
vp restore P_SOURCE_CLUSTER=aks-tpg-poc-01 P_INSTANCE=orders-db P_MODE=backup P_BACKUP_NAME=orders-db-full-1 P_TARGET_INSTANCE=orders-db P_CONFIRM=orders-db
valid "restore: mode=backup in place with confirm is valid"
vp delete-apps P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_APPS='{"aks-tpg-poc-01":["tpg-operator"],"aks-tpg-poc-02":["tpg-operator"]}' P_CONFIRM=aks-tpg-poc-02,aks-tpg-poc-01 P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_PUSH_MODE=direct
valid "delete-apps: confirm repeats the clusters in any order"
vp delete-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {purgeNamespace: true}}}' P_CONFIRM=aks-tpg-poc-01
invalid "delete-instance: purgeNamespace without purgePvcs is refused per instance" "orders-db: purgeNamespace=true needs purgePvcs=true"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03:
  deleteOperator: true
  instances:
    orders-db: {purgePvcs: true, purgeNamespace: true, finalBackup: required}
aks-tpg-poc-02:
  deleteOperator: true
  instances: {}' P_CONFIRM=aks-tpg-poc-02,aks-tpg-poc-03 P_DRY_RUN=true P_PUSH_MODE=direct
valid "delete-apps: a clusterMap with an operator-only cluster is valid"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03: {instances: {orders-db: {}}}' P_CONFIRM=aks-tpg-poc-03 P_DRY_RUN=true P_PUSH_MODE=direct
invalid "delete-apps: purgePvcs has no default" "orders-db: purgePvcs is required"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03: {instances: {}}' P_CONFIRM=aks-tpg-poc-03 P_DRY_RUN=true P_PUSH_MODE=direct
invalid "delete-apps: a cluster with nothing to delete is refused" "nothing to do on this cluster"

# ---- tpg-patch
vp patch P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorManifestPatchFilePath: patches/operator/debug.yaml
  instances:
    orders-db: {postgresPatchFilePath: [charts/tpg-instance/patches/mem.yaml, charts/tpg-instance/patches/log.yaml]}' P_PUSH_MODE=direct
valid "patch: a clusterMap with a list of patch files is valid"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: patches/mem.yaml}}}' P_PUSH_MODE=direct
invalid "patch: an instance patch outside the chart is refused" "'patches/mem.yaml' must be under charts/tpg-instance/patches/"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "patch: an instance without any patch file is refused" "no postgresPatchFilePath or valuesPatchFilePath"
vp patch P_CLUSTERS=all P_OPERATOR_MANIFEST_PATCH=patches/operator/debug.yaml P_PUSH_MODE=direct
valid "patch: an operator patch on every cluster (inputs) is valid"
vp patch P_CLUSTERS=all P_PUSH_MODE=direct
invalid "patch: no patch file at all is refused" "no patch file"

# ---- tpg-upgrade
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.1, instances: {orders-db: {postgresVersion: "17.7", allowMajor: true}}}' P_PUSH_MODE=direct
valid "upgrade: operator and Postgres in one clusterMap is valid"
[[ "$(cat /tmp/approval)" == "true" ]] && ok "upgrade: allowMajor in the map asks for batch approval" || bad "upgrade approval $(cat /tmp/approval)"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "upgrade: a map without versions is refused" "nothing to upgrade"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_COMPONENT=postgres P_TARGET_VERSION=17.7 P_PUSH_MODE=direct
valid "upgrade: component=postgres with targetVersion as the default of every instance"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.1}' P_TARGET_VERSION=4.5.1 P_PUSH_MODE=direct
invalid "upgrade: targetVersion without component is refused with clusterMap" "targetVersion needs component=operator or component=postgres with clusterMap"

# ---- lib accessors
cat > "$TMP/acc.sh" <<ACC
export TPG_WORK="$TMP/acc"
source "$ROOT/workflows/scripts/lib.sh"
set +e
printf '%s|' "\$(cmap_ival aks-tpg-poc-01 orders-db storageSize 20Gi)" "\$(cmap_ival aks-tpg-poc-01 billing-db storageSize 20Gi)" \
  "\$(cmap_cval aks-tpg-poc-02 operatorVersion v0)" "\$(cmap_instances aks-tpg-poc-01 | paste -sd,)" "\$(cmap_clusters | paste -sd,)"
ACC
got="$(PATH="$TMP/bin:$PATH" P_CLUSTER_MAP="$MAP_OK" bash "$TMP/acc.sh" 2>/dev/null)"
[[ "$got" == "50Gi|20Gi|v4.5.0|billing-db,orders-db|aks-tpg-poc-01,aks-tpg-poc-02|" ]] \
  && ok "lib: map keys override, the input default applies, instances and clusters listed" || bad "lib accessors" "$got"
rm -rf "$TMP/acc"
got="$(PATH="$TMP/bin:$PATH" P_CLUSTER_MAP="" bash "$TMP/acc.sh" 2>/dev/null)"
[[ "$got" == "20Gi|20Gi|v0|||" ]] && ok "lib: without clusterMap every accessor returns the default" || bad "lib no map" "$got"

# ---- fleet-day0.sh: values and the version rule (dry run)
REPO="$TMP/repo"
mkdir -p "$REPO/clusters/_template"
cp "$ROOT/clusters/_template/"*.yaml "$REPO/clusters/_template/"
cat > "$REPO/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-16.9}}
  aks-tpg-poc-02:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-16.9}}
  aks-tpg-poc-03:
    operator: {version: v4.4.0}
YAML
# live state per cluster: operator image tag ("" = not installed) and running instances
cat > "$TMP/live.json" <<'JSON'
{"aks-tpg-poc-01": {"operator": "", "instances": {}},
 "aks-tpg-poc-02": {"operator": "v4.5.0", "instances": {"orders-db": "postgres-16.9"}},
 "aks-tpg-poc-03": {"operator": "v4.4.0", "instances": {}},
 "aks-tpg-poc-04": {"operator": "latest", "instances": {}}}
JSON
cat > "$TMP/day0-prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/day0work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; }
record() { printf '%s %s %s %s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > /tmp/result; RESULT_RECORDED=1; }
record_entry() { printf '%s %s %s %s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
appset_refresh() { :; }
git_commit_push() { :; }
use_cluster() { CLUSTER="\$1"; }
tk() {
  local live; live="\$(jq -c --arg c "\$CLUSTER" '.[\$c]' "$TMP/live.json")"
  case "\$*" in
    *readyz*) return 0 ;;
    *"get deploy -A -l app=postgres-operator"*)
      jq -c '{items: (if .operator == "" then [] else [{spec: {template: {spec: {containers: [{image: ("reg.example/postgres-operator:" + .operator)}]}}}}] end)}' <<<"\$live" ;;
    *"get postgres"*)
      local i; i="\$(sed -E 's/.*get postgres ([a-z0-9-]+).*/\1/' <<<"\$*")"
      local v; v="\$(jq -r --arg i "\$i" '.instances[\$i] // ""' <<<"\$live")"
      [[ -n "\$v" ]] || return 1
      [[ "\$*" == *jsonpath* ]] && printf '%s' "\$v"
      return 0 ;;
  esac
}
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/day0-prelude.sh#" "$ROOT/workflows/scripts/fleet-day0.sh" > "$TMP/fleet-day0.sh"
day0() {  # day0 CLUSTERS_JSON VAR=VALUE... -> planned fleet.yaml JSON in $FLEET, records in $TMP/records
  rm -rf "$TMP/day0work" "$TMP/records" /tmp/fleet.json; : > "$TMP/records"
  RC=0; OUT="$(env PATH="$TMP/bin:$PATH" P_DRY_RUN=true P_PUSH_MODE=direct "${@:2}" bash "$TMP/fleet-day0.sh" wf "$1" 2>&1)" || RC=$?
  FLEET="$(cat /tmp/fleet.json 2>/dev/null || echo '{}')"
}
day0 '["aks-tpg-poc-01","aks-tpg-poc-02","aks-tpg-poc-03"]' P_INSTANCES=orders-db P_HA=true \
  P_OPERATOR_VERSION=4.4.0 P_POSTGRES_VERSION=17.6
[[ "$RC" -eq 0 ]] && ok "item 8: the run goes ahead with a blocked cluster" || bad "item 8 rc" "$OUT"
jq -e '.clusters["aks-tpg-poc-01"].operator.version == "v4.4.0" and .clusters["aks-tpg-poc-01"].instances["orders-db"].instance.postgresVersion == "postgres-17.6"' <<<"$FLEET" >/dev/null \
  && grep -q "FLEET_OVERRIDDEN aks-tpg-poc-01 operator v4.5.0 -> v4.4.0 (not installed on the cluster)" <<<"$OUT" \
  && ok "item 8: nothing runs on aks-tpg-poc-01, so the input replaces the fleet.yaml versions (FLEET_OVERRIDDEN)" || bad "item 8 override" "$OUT"
grep -q "^block.aks-tpg-poc-02 BLOCKED DOWNGRADE_NOT_ALLOWED operator v4.5.0 runs on aks-tpg-poc-02" "$TMP/records" \
  && jq -e '.clusters["aks-tpg-poc-02"].operator.version == "v4.5.0"' <<<"$FLEET" >/dev/null \
  && ok "item 8: aks-tpg-poc-02 runs v4.5.0: v4.4.0 is BLOCKED (DOWNGRADE_NOT_ALLOWED) and fleet.yaml is kept" || bad "item 8 downgrade" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-02"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-02 BLOCKED UPGRADE_REQUIRED orders-db runs postgres-16.9 on aks-tpg-poc-02: use tpg-upgrade component=postgres targetVersion=postgres-17.6 instances=orders-db" "$TMP/records" \
  && ok "item 8: a running instance on another version is BLOCKED with the tpg-upgrade command" || bad "item 8 instance" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-03"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-03 BLOCKED UPGRADE_REQUIRED operator v4.4.0 runs on aks-tpg-poc-03: use tpg-upgrade component=operator targetVersion=v4.5.0" "$TMP/records" \
  && ok "item 8: a newer operator input on a running cluster is BLOCKED (UPGRADE_REQUIRED)" || bad "item 8 upgrade" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-04"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-04 BLOCKED VERSION_UNKNOWN an operator runs on aks-tpg-poc-04 but its version cannot be read" "$TMP/records" \
  && ok "item 8: an operator whose version cannot be read is BLOCKED (VERSION_UNKNOWN)" || bad "item 8 unknown" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-02"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=16.9 P_STORAGE_SIZE=40Gi
jq -e '.clusters["aks-tpg-poc-02"].instances["orders-db"].instance.storageSize == "40Gi"' <<<"$FLEET" >/dev/null && ! grep -q '^block' "$TMP/records" \
  && ok "item 8: the versions the cluster runs are accepted and other inputs are written" || bad "item 8 same version" "$OUT $(cat "$TMP/records")"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  maxReadReplicas: 4
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 4, cpu: "2", memory: 8Gi, enableSSL: true}
    reporting-db: {postgresVersion: "17.6", highAvailability: false, readReplicas: 2, backupSchedule: none}' P_HA=true
jq -e '.clusters["aks-tpg-poc-01"] as $c
  | $c.cluster.maxReadReplicas == 4
  and $c.instances["orders-db"].instance.resources.data.requests.cpu == "2" and $c.instances["orders-db"].instance.resources.data.limits.cpu == "2"
  and $c.instances["orders-db"].instance.resources.data.limits.memory == "8Gi"
  and $c.instances["orders-db"].instance.highAvailability.readReplicas == 4
  and $c.instances["orders-db"].backup.enableSSL == true
  and $c.instances["reporting-db"].instance.highAvailability == {"enabled": false, "readReplicas": 0}
  and $c.instances["reporting-db"].backup.scheduled == false
  and $c.instances["reporting-db"].backup.enableSSL == false' <<<"$FLEET" >/dev/null \
  && ok "day0 clusterMap: every key lands on its fleet.yaml paths (cpu twice, no replicas without HA, backupSchedule none)" \
  || bad "day0 clusterMap write" "$(jq -c '.clusters["aks-tpg-poc-01"]' <<<"$FLEET") $OUT"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 5}}}'
[[ "$RC" -ne 0 ]] && grep -q "readReplicas 5 exceeds maxReadReplicas 3" "$TMP/records" \
  && ok "day0 clusterMap: readReplicas above maxReadReplicas fails the step" || bad "day0 max" "$(cat "$TMP/records") $OUT"

echo
echo "tests/cluster-map: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
