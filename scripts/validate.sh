#!/usr/bin/env bash
# Static validation of tpg-fleet. Requires: yamllint, shellcheck, kustomize,
# helm, kubeconform, python3 (PyYAML), jq, yq v4.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

echo "== yamllint";   yamllint -s .
echo "== shellcheck"; shellcheck -x -e SC1091 workflows/scripts/*.sh scripts/*.sh tests/*.sh tests/*/*.sh monitoring/grafana/import-azure-grafana.sh

# Flags the pinned CLIs no longer accept (helm list -a under Helm 4, and the
# rest of tests/cli-flags/rules.yaml), plus helm-addons.sh against a Helm 4 CLI.
echo "== tests"; tests/run-all.sh

echo "== kustomize build"
for d in workflows platform/base monitoring/azure/targets monitoring/azure/hub monitoring/standalone/targets monitoring/standalone/hub; do
  kustomize build "$d" > "$OUT/$(tr / _ <<<"$d").yaml"
  echo "ok $d"
done

echo "== workflow input types (generated admission policy up to date)"
python3 workflows/params/generate.py --check
echo "ok workflows/admission/workflow-parameters.yaml"

echo "== fleet.yaml structure (clusters/fleet.yaml and clusters/fleet.example.yaml)"
for ff in clusters/fleet.yaml clusters/fleet.example.yaml; do
  yq -e '.clusters | type == "!!map"' "$ff" >/dev/null
  for c in $(yq -r '.clusters | keys | .[]' "$ff"); do
    C="$c" yq -e '.clusters[strenv(C)].operator.version | type == "!!str"' "$ff" >/dev/null \
      || { echo "${ff}: clusters.${c}.operator.version is required" >&2; exit 1; }
    for f in $(C="$c" yq -r '(.clusters[strenv(C)].operator.patches // {}) | (.values // []) + (.manifests // []) | .[]' "$ff"); do
      [[ -f "$f" ]] || { echo "${ff}: clusters.${c}.operator.patches references ${f}, which does not exist" >&2; exit 1; }
    done
    for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$ff"); do
      C="$c" I="$i" yq -e '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion | test("^postgres-[0-9]")' "$ff" >/dev/null \
        || { echo "${ff}: clusters.${c}.instances.${i}.instance.postgresVersion is required (postgres-<version>)" >&2; exit 1; }
      for f in $(C="$c" I="$i" yq -r '(.clusters[strenv(C)].instances[strenv(I)].patches // {}) | (.postgres // []) + (.values // []) | .[]' "$ff"); do
        [[ -f "charts/tpg-instance/$f" ]] || { echo "${ff}: ${c}/${i} references charts/tpg-instance/${f}, which does not exist" >&2; exit 1; }
      done
    done
  done
  echo "ok ${ff}"
done

# values_for FLEET_FILE CLUSTER INSTANCE -> the Helm values the tpg-instances ApplicationSet passes
# shellcheck disable=SC2016  # yq variables, not shell
values_for() {
  C="$2" I="$3" yq '.clusters[strenv(C)] as $c | ($c.instances[strenv(I)] // {}) as $i
    | ($c | with_entries(select(.key != "instances" and .key != "operator")))
    * {"cluster": {"name": strenv(C)}, "backup": {"container": "pg-backups-" + strenv(C)}}
    * $i * {"instance": {"name": strenv(I)}}' "$1"
}

echo "== helm lint / template (every instance of fleet.yaml and fleet.example.yaml, patch files included)"
mkdir -p "$OUT/values"
for ff in clusters/fleet.yaml clusters/fleet.example.yaml; do
for c in $(yq -r '.clusters | keys | .[]' "$ff"); do
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$ff"); do
    values_for "$ff" "$c" "$i" > "$OUT/values/$c-$i.yaml"
    set -- -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml -f "$OUT/values/$c-$i.yaml"
    helm lint charts/tpg-instance "$@" >/dev/null
    helm template "$i" charts/tpg-instance "$@" --namespace "pg-$i" > "$OUT/chart_${c}_${i}.yaml"
    # PostgresBackupLocation must not carry the two fields the CRD drops on
    # apply (spec.additionalParameters when empty, spec.storage.azure.forcePathStyle
    # when false). Rendering them makes the Application OutOfSync for good.
    if yq 'select(.kind == "PostgresBackupLocation") | .spec
           | ((has("additionalParameters") and ((.additionalParameters // {}) | length) == 0),
              ((.storage.azure | has("forcePathStyle")) and .storage.azure.forcePathStyle != true))' \
         "$OUT/chart_${c}_${i}.yaml" | grep -qx true; then
      echo "PostgresBackupLocation for ${c}/${i} renders an empty additionalParameters or forcePathStyle: false;" >&2
      echo "the CRD drops both on apply and the Application never reaches Synced" >&2
      exit 1
    fi
    echo "ok ${ff}: ${c}/${i}"
  done
done
done

echo "== chart: patch files are merged"
# The example patches of clusters/fleet.example.yaml reach the rendered objects
got="$(helm template orders-db charts/tpg-instance -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml \
  -f "$OUT/values/aks-tpg-poc-01-orders-db.yaml" --namespace pg-orders-db \
  | yq 'select(.kind == "Postgres") | .spec.resources.data.limits.memory')"
[[ "$got" == "8Gi" ]] || { echo "postgres patch not merged: limits.memory is '${got}', expected 8Gi" >&2; exit 1; }
got="$(helm template orders-db charts/tpg-instance -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml \
  -f "$OUT/values/aks-tpg-poc-02-orders-db.yaml" --namespace pg-orders-db \
  | yq 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.number')"
[[ "$got" == "6" ]] || { echo "values patch not merged: fullRetention is '${got}', expected 6" >&2; exit 1; }
echo "ok postgres and values patch files"

echo "== chart: enableSSL of the backup location"
# Always rendered, false by default (clusters/_template/cluster.yaml and the
# chart), true when a cluster or instance sets backup.enableSSL: true.
base=(-f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml
      --set cluster.name=c1 --set instance.name=i1 --set instance.postgresVersion=postgres-17.6
      --set backup.container=pg-backups-c1)
for want in false true; do
  extra=(); [[ "$want" == "false" ]] || extra=(--set backup.enableSSL=true)
  got="$(helm template i1 charts/tpg-instance "${base[@]}" "${extra[@]}" --namespace pg-i1 \
    | yq 'select(.kind == "PostgresBackupLocation") | .spec.storage.azure.enableSSL')"
  [[ "$got" == "$want" ]] || { echo "PostgresBackupLocation enableSSL renders '${got}', expected ${want}" >&2; exit 1; }
  echo "ok enableSSL ${want}"
done
# The ApplicationSet must leave spec.postgresVersion of a running instance to
# the PostgresVersionUpgrade (tpg-upgrade), and ignore enableSSL false.
yq -e '.spec.template.spec.ignoreDifferences[] | select(.kind == "Postgres") | .jsonPointers[] | select(. == "/spec/postgresVersion")' \
  bootstrap/appsets/tpg-instances.yaml >/dev/null
yq -e '.spec.template.spec.syncPolicy.syncOptions[] | select(. == "RespectIgnoreDifferences=true")' \
  bootstrap/appsets/tpg-instances.yaml >/dev/null
echo "ok tpg-instances ignores Postgres spec.postgresVersion (RespectIgnoreDifferences)"

echo "== kubeconform"
cp bootstrap/*.yaml bootstrap/appsets/*.yaml "$OUT/"
for f in bootstrap/monitoring/*/*.yaml; do cp "$f" "$OUT/$(tr / _ <<<"$f")"; done
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default -schema-location "$CATALOG" "$OUT"/*.yaml

echo "== JSON"
for d in tpg-fleet tpg-instance tpg-replication tpg-backup tpg-alerts; do
  jq -e --arg u "$d" '.uid == $u and (.panels | length > 0)' "monitoring/standalone/hub/dashboards/${d}.json" >/dev/null \
    || { echo "dashboard ${d} is missing or empty (run monitoring/grafana/generate.py)" >&2; exit 1; }
  grep -q "dashboards/${d}.json" monitoring/standalone/hub/kustomization.yaml \
    || { echo "dashboard ${d} is not in monitoring/standalone/hub/kustomization.yaml" >&2; exit 1; }
done
for f in monitoring/grafana/alerts/api/*.json; do jq -e '.uid and .data' "$f" >/dev/null; done
echo "ok dashboards and alert payloads"

echo "== generated files are up to date"
python3 monitoring/grafana/generate.py >/dev/null
git diff --quiet -- monitoring || { echo "run monitoring/grafana/generate.py and commit the result" >&2; exit 1; }
echo "All checks passed"
