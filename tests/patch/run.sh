#!/usr/bin/env bash
# tpg-patch planning (workflows/scripts/patch-plan.sh): patch file checks, the
# patchMode edits of clusters/fleet.yaml, the clusterMap postgresVersion guard
# and the dry run of the rendered instance on the target.
#
# Runs the script with the real lib.sh and chart, and stubs for Git, the run
# ConfigMap, the Argo CD API and the target cluster (kubectl apply --dry-run is
# recorded, not sent). The instance is rendered with helm (helm template), so
# the dry-run document carries the patch the chart merged.
#
# Requires: bash 4, python3, jq, yq (mikefarah) and helm (v3 or v4); skipped
# without helm.
# ok() and bad() always return 0; single-quoted snippets are jq, yq or YAML.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/patch: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/patch: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }

# ---- the fleet repository
REPO="$TMP/repo"
mkdir -p "$REPO/clusters" "$REPO/patches/operator"
cp -r "$ROOT/charts" "$REPO/"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
P="$REPO/charts/tpg-instance/patches"
cat > "$REPO/clusters/fleet.base.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-17.6, storageSize: 50Gi}}
      billing-db: {instance: {postgresVersion: postgres-16.9}}
YAML
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  resources:\n    data:\n      limits: {memory: 8Gi}\n' > "$P/mem.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevel: Debug\n' > "$P/log.yaml"
printf 'backup:\n  fullRetention: 8\n' > "$P/retention.yaml"
printf 'kind: Postgres\nspec:\n  highAvailability: {enabled: false}\n' > "$P/ha.yaml"
printf 'kind: Postgres\nspec:\n  storageSize: 10Gi\n' > "$P/shrink.yaml"
printf 'kind: Postgres\nmetadata: {name: other}\nspec: {}\n' > "$P/meta.yaml"
printf 'instance:\n  postgresVersion: postgres-18.0\n' > "$P/badvalues.yaml"
printf 'backup:\n  additionalParameters: {process-max: "4"}\n' > "$P/ignored.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: postgres-operator}\nspec:\n  template:\n    spec:\n      nodeSelector: {pool: system}\n' > "$REPO/patches/operator/placement.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: postgres-operator}\nspec:\n  template:\n    spec:\n      containers:\n        - {name: operator, image: evil/image:1}\n' > "$REPO/patches/operator/image.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: not-in-the-chart}\ndata: {a: b}\n' > "$REPO/patches/operator/foreign.yaml"
printf 'operatorImage: evil/operator:1\n' > "$REPO/patches/operator/image-values.yaml"

cat > "$TMP/prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
set +e
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; cp "$TMP/fleet.yaml" "\$1/clusters/fleet.yaml"; }
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > "$TMP/result"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
run_data() { [[ "\$1" == inventory ]] && printf '%s' '[{"name":"c1","wave":0,"instances":[{"name":"orders-db"},{"name":"billing-db"}]}]'; }
appset_refresh() { :; }
git_commit_push() { cp "\$1/clusters/fleet.yaml" "$TMP/pushed.yaml"; PUSHED_REVISION=abc123def456; }
use_cluster() { CLUSTER="\$1"; }
app_get() { printf '%s' '{"status":{"resources":[{"kind":"Deployment","name":"postgres-operator"},{"kind":"Service","name":"postgres-operator-webhook-service"}]}}'; }
tk() {
  case "\$*" in
    *readyz*) return 0 ;;
    *"--dry-run=server"*) cat >> "$TMP/dryrun.yaml"; echo "applied (server dry run)" ;;
    *"get postgres"*) [[ "\$*" == *jsonpath* ]] && printf 'postgres-17.6'; return 0 ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/prelude.sh#" "$ROOT/workflows/scripts/patch-plan.sh" > "$TMP/patch-plan.sh"
plan() {  # plan VAR=VALUE... (fleet.yaml from $TMP/fleet.yaml; result fleet in $PUSHED)
  rm -rf "$TMP/work" "$TMP/records" "$TMP/dryrun.yaml" "$TMP/pushed.yaml"; : > "$TMP/records"; : > "$TMP/dryrun.yaml"
  OUT="$(env PATH="$PATH" P_PUSH_MODE=direct "$@" bash "$TMP/patch-plan.sh" wf 2>&1)" || true
  PUSHED="$(cat "$TMP/pushed.yaml" 2>/dev/null || cat "$TMP/fleet.yaml")"
}
rec() { grep -F "$1" "$TMP/records" || true; }
cp "$REPO/clusters/fleet.base.yaml" "$TMP/fleet.yaml"

# ---- 1 append through clusterMap
plan P_CLUSTER_MAP='c1:
  instances:
    orders-db:
      postgresPatchFilePath: [charts/tpg-instance/patches/mem.yaml, charts/tpg-instance/patches/log.yaml]
      valuesPatchFilePath: charts/tpg-instance/patches/retention.yaml'
[[ "$(yq -o=json -I=0 '.clusters.c1.instances["orders-db"].patches' <<<"$PUSHED")" == '{"postgres":["patches/mem.yaml","patches/log.yaml"],"values":["patches/retention.yaml"]}' ]] \
  && ok "1 fleet.yaml references the files (chart-relative), in order; no content copied" || bad "1 references" "$PUSHED $OUT"
rec "precheck.c1|PASSED" | grep -q "instances: orders-db" && ok "1 the cluster passes its checks and dry run" || bad "1 precheck" "$(cat "$TMP/records") $OUT"
yq -e 'select(.kind == "Postgres") | .spec.resources.data.limits.memory == "8Gi" and .spec.logLevel == "Debug"' "$TMP/dryrun.yaml" >/dev/null \
  && ok "1 the dry-run Postgres carries both patches, merged by the chart" || bad "1 dry run doc" "$(cat "$TMP/dryrun.yaml")"
yq -e 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.number == 8' "$TMP/dryrun.yaml" >/dev/null \
  && ok "1 the values patch reaches the PostgresBackupLocation" || bad "1 values patch" "$(yq 'select(.kind == "PostgresBackupLocation")' "$TMP/dryrun.yaml")"
rec "revision|SET" | grep -q abc123 && rec "result.git|SUCCEEDED" | grep -q abc123 \
  && ok "1 the commit is recorded for the sync steps" || bad "1 revision" "$(cat "$TMP/records")"
rec "plan.c1|PLANNED" | grep -q '"instances":\["orders-db"\]' && ok "1 plan.c1 lists orders-db only" || bad "1 plan" "$(cat "$TMP/records")"

# ---- 2 the same run again: nothing to change
cp "$TMP/pushed.yaml" "$TMP/fleet.yaml"
plan P_CLUSTER_MAP='c1: {instances: {orders-db: {postgresPatchFilePath: charts/tpg-instance/patches/mem.yaml}}}'
rec "result.git|SUCCEEDED|NO_CHANGE" | grep -q . && ok "2 appending a file already listed changes nothing (still synced and verified)" || bad "2 no change" "$(cat "$TMP/records")"

# ---- 3 replace and remove
plan P_CLUSTER_MAP='c1: {instances: {orders-db: {postgresPatchFilePath: charts/tpg-instance/patches/log.yaml, patchMode: replace}}}'
[[ "$(yq -o=json -I=0 '.clusters.c1.instances["orders-db"].patches.postgres' <<<"$PUSHED")" == '["patches/log.yaml"]' ]] \
  && ok "3 replace: the file becomes the whole postgres list; the values list stays" || bad "3 replace" "$PUSHED"
cp "$TMP/pushed.yaml" "$TMP/fleet.yaml"
plan P_CLUSTER_MAP='c1: {instances: {orders-db: {postgresPatchFilePath: charts/tpg-instance/patches/log.yaml, valuesPatchFilePath: charts/tpg-instance/patches/retention.yaml, patchMode: remove}}}'
[[ "$(yq '.clusters.c1.instances["orders-db"] | has("patches")' <<<"$PUSHED")" == "false" ]] \
  && ok "3 remove: the last files leave; empty patches entries are pruned" || bad "3 remove" "$PUSHED"
cp "$REPO/clusters/fleet.base.yaml" "$TMP/fleet.yaml"

# ---- 4 refused files
plan P_CLUSTER_MAP='c1: {instances: {orders-db: {postgresPatchFilePath: [charts/tpg-instance/patches/ha.yaml, charts/tpg-instance/patches/shrink.yaml, charts/tpg-instance/patches/meta.yaml]}}}'
r="$(rec "precheck.c1|BLOCKED|PATCH_REFUSED")"
grep -q "spec.highAvailability is changed by tpg-scale-instance" <<<"$r" \
  && grep -q "spec.storageSize 10Gi is smaller than the current 50Gi" <<<"$r" \
  && grep -q "only apiVersion, kind and spec can be patched (found metadata)" <<<"$r" \
  && ok "4 guarded fields are refused with the workflow that owns them" || bad "4 guarded" "$r $OUT"
[[ ! -f "$TMP/pushed.yaml" ]] && ok "4 nothing is pushed for a refused cluster" || bad "4 pushed" "$(cat "$TMP/pushed.yaml")"
rec "result.c1.orders-db|FAILED|PATCH_REFUSED" | grep -q . && ok "4 the instance is FAILED PATCH_REFUSED" || bad "4 instance" "$(cat "$TMP/records")"
plan P_CLUSTER_MAP='c1: {instances: {orders-db: {valuesPatchFilePath: [charts/tpg-instance/patches/badvalues.yaml, charts/tpg-instance/patches/nothere.yaml]}}}'
r="$(rec "precheck.c1|BLOCKED")"
grep -q "instance.postgresVersion cannot be set by a values patch" <<<"$r" && grep -q "nothere.yaml does not exist in the fleet repository" <<<"$r" \
  && ok "4 a values patch with a version, and a missing file, are refused" || bad "4 values" "$r"
plan P_CLUSTER_MAP='c1: {instances: {orders-db: {valuesPatchFilePath: [charts/tpg-instance/patches/ignored.yaml]}}}'
r="$(rec "precheck.c1|BLOCKED")"
grep -q "backup.additionalParameters is ignored by Argo CD on a running instance" <<<"$r" \
  && ok "4 a values patch of a field tpg-instances ignores is refused" || bad "4 ignored field" "$r"

# ---- 5 operator patches
plan P_CLUSTERS=c1 P_OPERATOR_MANIFEST_PATCH=patches/operator/placement.yaml
[[ "$(yq -o=json -I=0 '.clusters.c1.operator.patches.manifests' <<<"$PUSHED")" == '["patches/operator/placement.yaml"]' ]] \
  && yq -e 'select(.kind == "Deployment") | .spec.template.spec.nodeSelector.pool == "system"' "$TMP/dryrun.yaml" >/dev/null \
  && ok "5 an operator manifest patch is referenced and dry-run applied" || bad "5 manifest" "$PUSHED $(cat "$TMP/dryrun.yaml") $OUT"
plan P_CLUSTERS=c1 P_OPERATOR_MANIFEST_PATCH=patches/operator/image.yaml,patches/operator/foreign.yaml
r="$(rec "precheck.c1|BLOCKED")"
grep -q "Deployment/postgres-operator: image fields follow the operator version" <<<"$r" \
  && grep -q "ConfigMap/not-in-the-chart is not an object of the operator Application tpg-c1-operator" <<<"$r" \
  && ok "5 an image field and an object the operator chart does not render are refused" || bad "5 refused" "$r $OUT"
plan P_CLUSTERS=c1 P_OPERATOR_VALUES_PATCH=patches/operator/image-values.yaml
rec "precheck.c1|BLOCKED" | grep -q "operatorImage and postgresImage follow the operator version" \
  && ok "5 operatorImage in an operator values patch is refused" || bad "5 values" "$(cat "$TMP/records")"

# ---- 6 the clusterMap postgresVersion guard
plan P_CLUSTER_MAP='c1: {instances: {billing-db: {postgresVersion: "16.9", postgresPatchFilePath: charts/tpg-instance/patches/mem.yaml}}}'
rec "result.c1.billing-db|SKIPPED_VERSION_MISMATCH" | grep -q "clusterMap postgresVersion is postgres-16.9, the live instance runs postgres-17.6" \
  && [[ ! -f "$TMP/pushed.yaml" ]] \
  && ok "6 an instance that runs another version is skipped and not referenced" || bad "6 guard" "$(cat "$TMP/records") $OUT"

echo
echo "tests/patch: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
