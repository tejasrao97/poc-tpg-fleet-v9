#!/usr/bin/env bash
# init-run.sh WORKFLOW_NAME WORKFLOW_UID
# Create the run results ConfigMap, owned by the Workflow so it is deleted with it.
WF="$1"; UID_="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

kubectl -n "$ARGO_NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: $(run_cm)
  labels:
    tpg.fleet/run: "true"
  ownerReferences:
    - apiVersion: argoproj.io/v1alpha1
      kind: Workflow
      name: ${WF}
      uid: ${UID_}
data: {}
YAML
log "created ConfigMap $(run_cm)"

# Fail fast when Vault is sealed: every later step reads its credentials through
# Vault Agent, which would otherwise wait in its init container.
if ! out="$(vault_check)"; then
  record result.vault FAILED "${out%% *}" "${out#* }"
  exit 1
fi
log "Vault initialized and unsealed"
