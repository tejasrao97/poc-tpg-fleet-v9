#!/usr/bin/env bash
# The two hub admission policies in workflows/admission/, evaluated by a real
# kube-apiserver (tests/envtest/apiserver.sh) with the real CRDs of Argo
# Workflows v4.1.3 (Workflow) and Argo CD v3.5.3 (Application):
#
#   workflow-parameters.yaml  input types of the tpg WorkflowTemplates
#     - a correct run is accepted; the default of every input of every template
#       passes (a Workflow with all defaults is created per template)
#     - a wrong type, an unknown input, an old input name and a malformed
#       clusterMap are rejected, with the input and its type in the message
#     - Workflows of other templates are not affected
#   application-sync.yaml     only the workflows sync tpg target Applications
#     - a new operation is accepted only from argocd-server on behalf of
#       workflow-bot (or workflow-bot:apiKey)
#     - the controller clearing the operation, status and annotation updates and
#       hub Applications are not affected; automated sync is refused
#
# Requires the envtest binaries (etcd, kube-apiserver, kubectl; KUBEBUILDER_ASSETS
# or PATH), openssl, python3, yq (mikefarah) and jq. Skipped when envtest is missing.
# ok() and bad() always return 0; single-quoted jq and yq programs are not shell.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=tests/envtest/apiserver.sh
source "${ROOT}/tests/envtest/apiserver.sh"
if ! envtest_find; then
  echo "SKIP tests/admission: envtest binaries not found (set KUBEBUILDER_ASSETS)" >&2
  exit 0
fi
for t in openssl python3 yq jq; do command -v "$t" >/dev/null || { echo "SKIP tests/admission: $t not installed" >&2; exit 0; }; done
k() { "$ENVTEST_BIN/kubectl" "$@"; }
ENVTEST_TMP="$(mktemp -d)"
envtest_start "$ENVTEST_TMP"
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -8; FAIL=$((FAIL + 1)); }

k apply -f "$HERE/crds/" >/dev/null
k wait --for=condition=Established crd/workflows.argoproj.io crd/applications.argoproj.io --timeout=60s >/dev/null
k create namespace argo >/dev/null
k create namespace argocd >/dev/null
k apply -f "$ROOT/workflows/admission/workflow-parameters.yaml" -f "$ROOT/workflows/admission/application-sync.yaml" >/dev/null
# the policies are enforced shortly after they are created
sleep 3

# ------------------------------------------------------------------ Workflow parameters
N=0
wf() {  # wf TEMPLATE PARAMS_JSON -> creates a Workflow; output in $OUT, status in $RC
  N=$((N + 1))
  local doc
  doc="$(jq -cn --arg t "$1" --argjson p "$2" --arg n "t-${N}" '{apiVersion: "argoproj.io/v1alpha1", kind: "Workflow",
    metadata: {name: $n, namespace: "argo"}, spec: {workflowTemplateRef: {name: $t}, arguments: {parameters: $p}}}')"
  RC=0; OUT="$(k create -f - <<<"$doc" 2>&1)" || RC=$?
}
params() {  # params NAME=VALUE... -> JSON list of parameters
  local a out="[]"
  for a in "$@"; do out="$(jq -c --arg n "${a%%=*}" --arg v "${a#*=}" '. + [{name: $n, value: $v}]' <<<"$out")"; done
  printf '%s' "$out"
}
accepted() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
rejected() {  # rejected LABEL TEXT...: refused, and the message has every TEXT
  local t
  if [[ "$RC" -eq 0 ]]; then bad "$1 (accepted)" "$OUT"; return; fi
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (message lacks '$t')" "$OUT"; return; }; done
  ok "$1"
}

wf tpg-day0 "$(params clusters=all instances=orders-db,billing-db highAvailability=true operatorVersion=v4.5.0 \
  postgresVersion=postgres-17.6 pushMode=direct maxParallel=2 storageSize=50Gi rolloutMode=batches)"
accepted "tpg-day0: a correct run is accepted"
wf tpg-day0 "$(params clusters=all maxParallel=abc)"
rejected "tpg-day0: maxParallel=abc is refused as an Integer" 'maxParallel="abc" must be an Integer (1 or more)'
wf tpg-day0 "$(params highAvailability=yes)"
rejected "tpg-day0: highAvailability=yes is refused as a Boolean" 'highAvailability="yes" must be a Boolean (true or false)'
wf tpg-day0 "$(params clusters=Aks_01)"
rejected "tpg-day0: clusters=Aks_01 is refused as a List" 'clusters="Aks_01" must be a List'
wf tpg-day0 "$(params clusters=all instances=orders_db)"
rejected "tpg-day0: instances=orders_db is refused" 'instances="orders_db" must be a List'
wf tpg-day0 "$(params clusters=all fooBar=1)"
rejected "tpg-day0: an unknown input is refused" 'fooBar is not an input of tpg-day0'
wf tpg-day0 "$(params 'clusterMap=aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' pushMode=direct)"
accepted "tpg-day0: a YAML clusterMap is accepted"
wf tpg-day0 "$(params 'clusterMap={"aks-tpg-poc-01": {"instances": {"orders-db": {}}}}' pushMode=pr)"
accepted "tpg-day0: a JSON clusterMap is accepted"
wf tpg-day0 "$(params 'clusterMap=just some text')"
rejected "tpg-day0: clusterMap that is not a map is refused" 'clusterMap="just some text" must be a Map'
wf tpg-day0 "$(params clusters=all pushMode=)"
accepted "tpg-day0: an empty mandatory input passes the type check (the validate step reports it)"
wf tpg-scale-instance "$(params cluster=aks-tpg-poc-01 instance=orders-db replicas=2 pushMode=direct)"
rejected "tpg-scale-instance: the old single cluster/instance inputs are refused" 'cluster is not an input of tpg-scale-instance' 'instance is not an input'
wf tpg-scale-instance "$(params clusters=aks-tpg-poc-01,aks-tpg-poc-02 instances=orders-db replicas=2 pushMode=direct)"
accepted "tpg-scale-instance: clusters and instances lists are accepted"
wf tpg-scale-instance "$(params clusters=all instances=orders-db replicas=2)"
rejected "tpg-scale-instance: clusters=all is refused (a list of names only)" 'clusters="all" must be a List (comma-separated names)'
wf tpg-patch "$(params clusters=aks-tpg-poc-01 instances=orders-db postgresPatchFilePath=charts/tpg-instance/patches/a.yaml pushMode=direct)"
accepted "tpg-patch: a path list is accepted"
wf tpg-patch "$(params postgresPatchFilePath=/etc/passwd)"
rejected "tpg-patch: a path that is not a .yaml file in the repository is refused" 'postgresPatchFilePath="/etc/passwd" must be a List of .yaml paths'
wf tpg-restore "$(params sourceCluster=aks-tpg-poc-01 instance=orders-db mode=time targetTime=2026-09-15)"
rejected "tpg-restore: targetTime without the time of day is refused" 'targetTime="2026-09-15" must be a UTC time'
wf tpg-upgrade "$(params component=operator targetVersion=4.5.1 clusters=all pushMode=direct operatorPatches=keep)"
accepted "tpg-upgrade: operatorPatches=keep is accepted"
wf tpg-upgrade "$(params component=database)"
rejected "tpg-upgrade: component outside its enum is refused" 'component="database" must be one of operator, postgres'
# A value written as a YAML number in a manifest is read as its text
N=$((N + 1))
RC=0; OUT="$(k create -f - <<YAML 2>&1
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: t-${N}, namespace: argo}
spec:
  workflowTemplateRef: {name: tpg-backup}
  arguments:
    parameters:
      - {name: backupTimeoutSeconds, value: 3600}
      - {name: scheduledOnly, value: true}
YAML
)" || RC=$?
accepted "tpg-backup: numbers and booleans written unquoted are accepted"
wf other-template "$(params anything=goes)"
accepted "a Workflow of a non-tpg template is not affected"
wf tpg-unknown "$(params x=1)"
rejected "a tpg-* template without declared types is refused" 'has no parameter types'

# Every template's defaults pass the policy
for f in "$ROOT"/workflows/templates/*.yaml; do
  t="$(yq -r '.metadata.name' "$f")"
  [[ "$t" == "tpg-lib" ]] && continue
  wf "$t" "$(yq -o=json -I=0 '[.spec.arguments.parameters[] | {"name": .name, "value": (.value // "")}]' "$f")"
  accepted "${t}: a Workflow with every input at its default is accepted"
done

# ------------------------------------------------------------------ Application sync
app_doc() {  # app_doc NAME COMPONENT -> Application JSON
  jq -cn --arg n "$1" --arg c "$2" '{apiVersion: "argoproj.io/v1alpha1", kind: "Application",
    metadata: ({name: $n, namespace: "argocd"} + (if $c != "" then {labels: {"tpg.fleet/component": $c}} else {} end)),
    spec: {project: "tpg", destination: {server: "https://example.invalid", namespace: "pg-orders-db"},
           source: {repoURL: "https://github.com/example/tpg-fleet.git", path: "charts/tpg-instance", targetRevision: "main"}}}'
}
op() {  # op APP USER AS [automated]: set a new sync operation initiated by USER, as AS (a kubectl --as user or "")
  local who="$2" as="$3" auto="${4:-false}" patch
  patch="$(jq -cn --arg u "$who" --argjson a "$auto" '{operation: {sync: {revision: "HEAD"},
    initiatedBy: (if $a then {automated: true} else {username: $u} end)}}')"
  RC=0; OUT="$(k -n argocd patch application "$1" --type merge -p "$patch" ${as:+--as="$as"} 2>&1)" || RC=$?
}
clear_op() { k -n argocd patch application "$1" --type json -p '[{"op":"remove","path":"/operation"}]' \
  --as=system:serviceaccount:argocd:argocd-application-controller >/dev/null 2>&1 || true; }
SERVER=system:serviceaccount:argocd:argocd-server

RC=0; OUT="$(k create -f - <<<"$(app_doc tpg-aks-tpg-poc-01-orders-db instance)" 2>&1)" || RC=$?
accepted "Application: a target Application without an operation can be created (ApplicationSet controller)"
op tpg-aks-tpg-poc-01-orders-db workflow-bot "$SERVER"
accepted "Application: argocd-server may start a sync for workflow-bot"
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' --as="$SERVER" 2>&1)" || RC=$?
accepted "Application: an update that keeps the running operation is not affected"
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type json \
  -p '[{"op":"remove","path":"/operation"}]' --as=system:serviceaccount:argocd:argocd-application-controller 2>&1)" || RC=$?
accepted "Application: the controller may remove the finished operation"
op tpg-aks-tpg-poc-01-orders-db workflow-bot:apiKey "$SERVER"
accepted "Application: workflow-bot:apiKey (API token subject) is accepted"
clear_op tpg-aks-tpg-poc-01-orders-db
op tpg-aks-tpg-poc-01-orders-db admin "$SERVER"
rejected "Application: a sync started by admin in the UI or CLI is refused" 'only the tpg workflows (Argo CD account workflow-bot) may sync tpg-aks-tpg-poc-01-orders-db' 'requested by admin'
op tpg-aks-tpg-poc-01-orders-db workflow-bot ""
rejected "Application: an operation written with kubectl, even naming workflow-bot, is refused" 'through admin'
op tpg-aks-tpg-poc-01-orders-db "" "system:serviceaccount:argocd:argocd-application-controller" true
rejected "Application: an automated operation is refused" 'requested by an unknown user'
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false}}}}' 2>&1)" || RC=$?
rejected "Application: switching on automated sync is refused" 'automated sync cannot be enabled on tpg-aks-tpg-poc-01-orders-db'
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}' 2>&1)" || RC=$?
accepted "Application: automated with enabled=false is accepted"
RC=0; OUT="$(k create -f - <<<"$(app_doc tpg-aks-tpg-poc-01-operator operator | jq -c '.operation = {sync: {revision: "HEAD"}, initiatedBy: {username: "admin"}}')" 2>&1)" || RC=$?
rejected "Application: creating a target Application with an operation by someone else is refused" 'only the tpg workflows'
RC=0; OUT="$(k create -f - <<<"$(app_doc tpg-hub-workflows "")" 2>&1)" || RC=$?
accepted "Application: a hub Application (no tpg.fleet/component) can be created"
op tpg-hub-workflows admin "$SERVER"
accepted "Application: a hub Application can still be synced by an admin"

echo
echo "tests/admission: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
