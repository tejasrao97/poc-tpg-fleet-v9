#!/usr/bin/env bash
# Fixture, not part of the fleet. Every line below is a CLI mistake that
# check_cli_flags.py has to find; tests/cli-flags/run.sh asserts the exact set.
# Keep one violation per rule id, and add a line here with every new rule.
set -euo pipefail

# helm4-list-all: -a was removed in Helm 4
helm list -A -a -o json

# helm4-list-all through the h() wrapper used by helm-addons.sh
h() { helm "$@"; }
h list -n monitoring -a -o json

# helm4-atomic
helm upgrade --install kps kube-prometheus-stack -n monitoring --atomic --timeout 15m

# helm4-force
helm upgrade --install cert-manager cert-manager -n cert-manager --force

# helm4-create-pods
helm install vault hashicorp/vault -n vault --create-pods

# helm4-post-renderer-path
helm template orders-db charts/tpg-instance --post-renderer=./kustomize-wrapper.sh

# helm4-registry-login-path: Helm 4 takes the domain only
helm registry login tanzu-sql-postgres.packages.broadcom.com/tanzu-postgres --username u

# kubectl-export
kubectl get configmap tpg-settings -n argo --export -o yaml

# kubectl-run-generator
kubectl run probe --image=busybox --generator=run-pod/v1

# kubectl-delete-cascade-bool
kubectl delete application tpg-aks-tpg-poc-01-orders-db -n argocd --cascade=false

# kubectl-rollout-status-watch-false (warning)
kubectl rollout status deploy/argocd-server -n argocd -w=false

# argo-submit-instanceid-flag (warning)
argo submit --from workflowtemplate/tpg-day0 --instanceid tpg -p clusters=all
