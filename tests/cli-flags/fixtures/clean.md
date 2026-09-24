# Fixture: correct commands

Nothing in this file may be reported. It exists so the checker is exercised on
Markdown code blocks and inline code spans, and so a rule that is too broad
fails the self-test instead of passing silently.

Every release state, on Helm 3 and Helm 4 alike:

```bash
helm list -A --deployed --failed --pending --superseded --uninstalled --uninstalling -o json
helm --kube-context aks-tpg-hub -n vault status vault -o json
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io \
  --version v1.21.2 -n cert-manager --create-namespace -f values.yaml --wait --timeout 15m
helm registry login tanzu-sql-postgres.packages.broadcom.com --username "$U" --password-stdin
helm get values kps -n monitoring -o yaml
helm template orders-db charts/tpg-instance -f values.yaml --namespace pg-orders-db
```

An all-namespaces listing is `helm list -A`, and a cascading delete is
`kubectl delete application tpg-x --cascade=foreground`.

```bash
kubectl --context aks-tpg-poc-01 get storageclass tpg-data-retain -o jsonpath='{.parameters.skuName}'
kubectl rollout status deploy/argocd-server -n argocd --timeout=10s
argo submit --from workflowtemplate/tpg-day0 -p clusters=all -p dryRun=true --watch
argocd app sync tpg-aks-tpg-poc-01-platform --grpc-web
```
