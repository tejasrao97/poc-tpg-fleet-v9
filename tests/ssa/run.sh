#!/usr/bin/env bash
# Operator manifest patches and server-side apply field ownership, on a real
# kube-apiserver (tests/envtest/apiserver.sh), with the functions the workflows
# use (operator_patch_docs, operator_patches_apply, operator_patch_diffs in
# workflows/scripts/lib.sh).
#
# Argo CD itself does not run here. Its two kinds of sync are reproduced with
# the same server-side apply Argo CD performs (field manager argocd-controller,
# --force-conflicts):
#   sync with RespectIgnoreDifferences   the chart manifest, with the live value
#                                        of every field tpg-patch owns and that
#                                        differs (what controller/sync.go
#                                        normalizeTargetResources builds, v3.5.3)
#   sync without it (tpg-upgrade)        the chart manifest as rendered
# The steps:
#   1 chart applied; two patch files for the same Deployment are merged in list
#     order (the later file wins) and applied by tpg-patch
#   2 a sync with RespectIgnoreDifferences keeps every patched value, and a field
#     the chart does not render (nodeSelector) stays owned by tpg-patch
#   3 an operator upgrade: the sync without RespectIgnoreDifferences takes the
#     chart fields back; operator_patch_diffs lists what the patch overrides; the
#     patch applied again restores it and the diffs are empty
#   4 a patch file removed: after the co-owning sync, the release keeps the chart
#     fields (co-owned) and removes the field only the patch set; the next sync
#     gives the chart values back
#   5 one field manager for every patch: applying the files one by one would have
#     undone the first (shown with a second manager name), which is why they are merged
#
# Requires the envtest binaries, openssl, python3, yq (mikefarah) and jq.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=tests/envtest/apiserver.sh
source "${ROOT}/tests/envtest/apiserver.sh"
if ! envtest_find; then
  echo "SKIP tests/ssa: envtest binaries not found (set KUBEBUILDER_ASSETS)" >&2
  exit 0
fi
for t in openssl python3 yq jq; do command -v "$t" >/dev/null || { echo "SKIP tests/ssa: $t not installed" >&2; exit 0; }; done
ENVTEST_TMP="$(mktemp -d)"
envtest_start "$ENVTEST_TMP"
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -8; FAIL=$((FAIL + 1)); }

export TPG_WORK="$ENVTEST_TMP/work"
# shellcheck source=workflows/scripts/lib.sh
source "$ROOT/workflows/scripts/lib.sh"
set +e
tk() { "$ENVTEST_BIN/kubectl" "$@"; }
k() { "$ENVTEST_BIN/kubectl" "$@"; }
NS="$OPERATOR_NS"
k create namespace "$NS" >/dev/null

# ---- a fleet repository checkout with two patch files
REPO="$ENVTEST_TMP/repo"
mkdir -p "$REPO/clusters" "$REPO/patches/operator"
cat > "$REPO/patches/operator/a.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-operator
spec:
  template:
    spec:
      nodeSelector:
        tpg.fleet/pool: system
      containers:
        - name: operator
          args: ["--log-level=debug"]
          resources:
            limits:
              memory: 1Gi
YAML
cat > "$REPO/patches/operator/b.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-operator
spec:
  template:
    spec:
      containers:
        - name: operator
          resources:
            limits:
              memory: 2Gi
YAML
fleet() {  # fleet FILE...: clusters.c1.operator.patches.manifests
  printf 'clusters:\n  c1:\n    operator:\n      version: v4.5.0\n' > "$REPO/clusters/fleet.yaml"
  [[ $# -eq 0 ]] || printf '      patches:\n        manifests: [%s]\n' "$(IFS=,; echo "$*")" >> "$REPO/clusters/fleet.yaml"
}
chart() {  # chart ARGS MEMORY: the Deployment as the chart renders it
  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-operator
  namespace: ${NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: postgres-operator}}
  template:
    metadata: {labels: {app: postgres-operator}}
    spec:
      containers:
        - name: operator
          image: example.invalid/postgres-operator:v4.5.0
          args: $1
          resources:
            limits: {cpu: "1", memory: $2}
YAML
}
argo_apply() { k apply --server-side --field-manager=argocd-controller --force-conflicts -f - >/dev/null; }
live() { k -n "$NS" get deploy postgres-operator -o json --show-managed-fields; }
owners() {  # owners JQ_PATH_IN_FIELDSV1 -> managers owning it
  live | jq -r --arg p "$1" '[.metadata.managedFields[]? | select(.fieldsV1 | tostring | contains($p)) | .manager] | unique | join(",")'
}

# ---- 1
chart '["--log-level=info"]' 512Mi | argo_apply
fleet patches/operator/a.yaml patches/operator/b.yaml
docs="$(operator_patch_docs "$REPO" patches/operator/a.yaml patches/operator/b.yaml)"
[[ "$(wc -l <<<"$docs")" -eq 1 ]] && ok "1 two files for one Deployment merge into one document" || bad "1 merged documents" "$docs"
operator_patches_apply "$REPO" c1 && ok "1 operator_patches_apply succeeds" || bad "1 operator_patches_apply" "$OPERATOR_PATCH_DETAIL"
j="$(live)"
[[ "$(jq -r '.spec.template.spec.containers[0].resources.limits.memory' <<<"$j")" == "2Gi" ]] \
  && ok "1 the later file wins (memory 2Gi)" || bad "1 later file wins" "$(jq -c '.spec.template.spec.containers[0]' <<<"$j")"
[[ "$(jq -r '.spec.template.spec.containers[0].args[0]' <<<"$j")" == "--log-level=debug" && \
   "$(jq -r '.spec.template.spec.nodeSelector["tpg.fleet/pool"]' <<<"$j")" == "system" && \
   "$(jq -r '.spec.template.spec.containers[0].resources.limits.cpu' <<<"$j")" == "1" ]] \
  && ok "1 args and nodeSelector patched, cpu from the chart kept" || bad "1 patched fields" "$(jq -c '.spec.template.spec' <<<"$j")"
[[ -z "$(operator_patch_diffs "$REPO" c1)" ]] && ok "1 operator_patch_diffs is empty after the apply" || bad "1 diffs" "$(operator_patch_diffs "$REPO" c1)"

# ---- 2 sync with RespectIgnoreDifferences: the chart with the live values of the patched fields
chart '["--log-level=debug"]' 2Gi | argo_apply
j="$(live)"
[[ "$(jq -r '.spec.template.spec.containers[0].resources.limits.memory' <<<"$j")" == "2Gi" && \
   "$(jq -r '.spec.template.spec.nodeSelector["tpg.fleet/pool"]' <<<"$j")" == "system" ]] \
  && ok "2 the sync keeps the patched values and the field the chart does not render" || bad "2 sync" "$(jq -c '.spec.template.spec' <<<"$j")"
[[ "$(owners 'f:nodeSelector')" == "tpg-patch" ]] && ok "2 nodeSelector is owned by tpg-patch only" || bad "2 nodeSelector owners: $(owners 'f:nodeSelector')"
[[ "$(owners 'f:args')" == "argocd-controller,tpg-patch" ]] && ok "2 args are co-owned after the sync" || bad "2 args owners: $(owners 'f:args')"

# ---- 3 operator upgrade: sync without RespectIgnoreDifferences, report, apply again
chart '["--log-level=info","--new-flag"]' 768Mi | argo_apply
j="$(live)"
[[ "$(jq -c '.spec.template.spec.containers[0].args' <<<"$j")" == '["--log-level=info","--new-flag"]' && \
   "$(jq -r '.spec.template.spec.nodeSelector["tpg.fleet/pool"]' <<<"$j")" == "system" ]] \
  && ok "3 the new chart takes its fields back; nodeSelector stays" || bad "3 clean sync" "$(jq -c '.spec.template.spec' <<<"$j")"
d="$(operator_patch_diffs "$REPO" c1)"
grep -q 'Deployment/postgres-operator spec.template.spec.containers.operator.args live=\["--log-level=info","--new-flag"\] patch=\["--log-level=debug"\]' <<<"$d" \
  && grep -q 'resources.limits.memory live="768Mi" patch="2Gi"' <<<"$d" \
  && ok "3 operator_patch_diffs names each field the patch overrides (OPERATOR_PATCH_OVERRIDES)" || bad "3 overrides" "$d"
operator_patches_apply "$REPO" c1 >/dev/null
[[ -z "$(operator_patch_diffs "$REPO" c1)" ]] && ok "3 applied again: no difference left" || bad "3 re-apply" "$(operator_patch_diffs "$REPO" c1)"

# ---- 4 remove a.yaml: co-owning sync, release, sync
chart '["--log-level=debug"]' 2Gi | argo_apply                     # 2a: sync with RespectIgnoreDifferences
fleet patches/operator/b.yaml
operator_patches_apply "$REPO" c1 --old "patches/operator/a.yaml patches/operator/b.yaml" \
  && ok "4 the smaller merged patch is applied" || bad "4 apply" "$OPERATOR_PATCH_DETAIL"
j="$(live)"
[[ "$(jq -r '.spec.template.spec.nodeSelector // {} | length' <<<"$j")" == "0" ]] \
  && ok "4 nodeSelector (set only by the patch) is removed" || bad "4 nodeSelector" "$(jq -c '.spec.template.spec.nodeSelector' <<<"$j")"
[[ "$(jq -r '.spec.template.spec.containers[0].args[0]' <<<"$j")" == "--log-level=debug" ]] \
  && ok "4 args that left the patch keep their value until the next sync (co-owned)" || bad "4 args" "$(jq -c '.spec.template.spec.containers[0]' <<<"$j")"
chart '["--log-level=info"]' 2Gi | argo_apply                      # 2c: args no longer ignored
[[ "$(jq -r '.spec.template.spec.containers[0].args[0]' <<<"$(live)")" == "--log-level=info" && \
   "$(jq -r '.spec.template.spec.containers[0].resources.limits.memory' <<<"$(live)")" == "2Gi" ]] \
  && ok "4 the next sync gives args back to the chart; memory (still patched) stays" || bad "4 final" "$(live | jq -c '.spec.template.spec.containers[0]')"
fleet
operator_patches_apply "$REPO" c1 --old "patches/operator/b.yaml" >/dev/null
[[ "$OPERATOR_PATCH_DETAIL" == *"(released)"* ]] && ok "4 the last patch removed: the object is released" || bad "4 release" "$OPERATOR_PATCH_DETAIL"
! owners 'f:memory' | grep -q tpg-patch && ok "4 tpg-patch owns nothing after the release" || bad "4 owners $(owners 'f:memory')"

# ---- 5 why the files are merged: one manager, applied one by one
k -n "$NS" delete deploy postgres-operator >/dev/null
chart '["--log-level=info"]' 512Mi | argo_apply
for f in a b; do
  yq -o=json -I=0 ".metadata.namespace = \"$NS\"" "$REPO/patches/operator/${f}.yaml" \
    | k apply --server-side --field-manager=tpg-demo --force-conflicts -f - >/dev/null
done
[[ "$(jq -r '.spec.template.spec.nodeSelector // {} | length' <<<"$(live)")" == "0" ]] \
  && ok "5 applying the files one by one with one manager drops the first file's fields (hence the merge)" \
  || bad "5 one-by-one apply" "$(live | jq -c '.spec.template.spec')"

echo
echo "tests/ssa: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
