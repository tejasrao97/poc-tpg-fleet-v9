# tpg-fleet

GitOps repository for the **Tanzu for Postgres on AKS GitOps POC**. Argo CD reads this repository to deploy the Tanzu for Postgres operator and Postgres instances to every target AKS cluster. Argo Workflows on the hub runs the ordered, gated Day 0 and Day 1 operations defined here.

The Azure infrastructure, the Argo installation and the cluster prerequisites live in the companion repository `tpg-aks-infra`.

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Tanzu for Postgres operator chart | v4.5.0 | `clusters/fleet.yaml` (`clusters.<cluster>.operator.version`, written by `tpg-day0`) |
| Argo CD / chart | v3.5.3 / 10.9.1 | `tpg-aks-infra/argo` |
| Argo Workflows / chart | v4.1.3 / 2.0.6 | `tpg-aks-infra/argo` |
| cert-manager chart | v1.21.2 | `workflows/scripts/helm-addons.sh` (Helm release `cert-manager`) |
| kube-state-metrics chart | 8.5.0 | `bootstrap/monitoring/azure`, `workflows/scripts/helm-addons.sh` (standalone) |
| kube-prometheus-stack chart | 91.4.0 | `workflows/scripts/helm-addons.sh` (Helm release `kps`, standalone) |
| HashiCorp Vault / chart | 2.0.4 / 0.34.1 | `workflows/scripts/helm-addons.sh` (Helm release `vault`, hub), `vault/vault-values.yaml` |
| Vault Secrets Operator chart | 1.5.1 | `workflows/scripts/helm-addons.sh` (Helm release `vault-secrets-operator`) |
| Remote-write gateway image | `nginxinc/nginx-unprivileged:1.27-alpine` | `monitoring/standalone/hub/remote-write-gateway.yaml` (standalone monitoring) |
| Workflow tools image | `alpine/k8s:1.35.8` | `toolsImage` parameter of every WorkflowTemplate |
| Azure CLI image | `mcr.microsoft.com/azure-cli:2.90.0` | `azCliImage` parameter of `tpg-rotate-credential` |

## Repository layout

```text
tpg-fleet/
  bootstrap/
    project-tpg.yaml                 AppProject tpg (the target Applications; only workflow-bot syncs them)
    project-tpg-hub.yaml             AppProject tpg-hub (hub Applications, hub destination only)
    app-hub-workflows.yaml           Hub Application for workflows/ (project tpg-hub, automated sync)
    appsets/                         platform, operator (multi-source: OCI chart + fleet value files),
                                     instances (manual sync)
    monitoring/azure/                Option A: kube-state-metrics + azmonitoring monitors
  platform/base/                     StorageClass tpg-data-retain (disk SKU from Terraform, Retain;
                                     the tpg-platform ApplicationSet patches skuName per cluster),
                                     regsecret for the operator namespace (from Vault)
  vault/                             Helm values, server config (shamir and azure-keyvault),
                                     VaultConnection/VaultAuth, policies (tpg-admin, tpg-workflow,
                                     tpg-argocd, tpg-target)
  charts/tpg-instance/               Postgres + PostgresBackupLocation (Azure Blob; enableSSL from
                                     backup.enableSSL, default false)
    patches/                         instance patch files (tpg-patch), read by the chart with .Files.Get
  patches/operator/                  operator patch files (tpg-patch): chart values, manifest patches
  clusters/
    _template/cluster.yaml           cluster defaults for every cluster (maxReadReplicas, backup)
    _template/instance.yaml          instance defaults for every instance (sizes, HA, resources)
    fleet.yaml                       per cluster: operator.version, overrides, instances.<name> overrides,
                                     patch file references; ships empty (clusters: {})
    fleet.example.yaml               a filled-in example (not read by Argo CD or the workflows)
    deleted/<cluster>/<i>-<time>     instance entries removed by the delete workflows
  docs/
    workflow-commands.md             argo and argocd commands for every workflow: input types, clusterMap,
                                     examples
  workflows/
    kustomization.yaml               WorkflowTemplates, CronWorkflows, RBAC, admission policies,
                                     tpg-scripts ConfigMap
    rbac.yaml                        ServiceAccount tpg-workflow
    admission/                       ValidatingAdmissionPolicies: tpg-workflow-parameters (input types,
                                     generated), tpg-application-sync (only workflow-bot syncs target apps)
    params/                          types.yaml (input types) and generate.py; cluster-map-keys.yaml
                                     (the keys clusterMap accepts)
    scripts/                         step scripts mounted at /scripts (helm-addons.sh is also run by tpg-aks-infra)
      common.sh                      shared with tpg-aks-infra scripts/lib/common.sh: retries, pod watch,
                                     Helm release pre-check, metrics flow check
      lib.sh                         workflow functions: run results, Git, Vault, the Argo CD sync engine,
                                     clusterMap accessors, operator manifest patches (server-side apply)
      clustermap.py                  clusterMap validation and normalization
    vault-agent/                     Vault Agent templates (ConfigMap tpg-vault-agent) for the workflow pods
    templates/                       tpg-lib, tpg-day0, tpg-upgrade, tpg-patch, tpg-scale-instance, tpg-backup,
                                     tpg-backup-retention, tpg-restore, tpg-rotate-credential,
                                     tpg-delete-instance, tpg-delete-apps, tpg-helm-addons
    cron/                            tpg-backup-full (Sun 00:00 UTC), tpg-backup-incr (Mon-Sat 00:00 UTC),
                                     tpg-backup-retention (daily 02:00 UTC)
  monitoring/
    ksm/values.yaml                  custom resource state metrics for Postgres, backups, restores
    azure/, standalone/              monitors, kube-prometheus-stack values, 5 dashboards, PrometheusRules,
                                     the hub remote-write gateway (standalone)
    grafana/                         generate.py, Grafana alert rules, Azure import script, SMTP examples
    prometheus/                      Alertmanager SMTP example
  scripts/                           set-repo-url.sh, validate.sh
  tests/
    cli-flags/                       flags the pinned CLIs no longer accept (rules.yaml, fixtures)
    helm4/                           helm-addons.sh end to end against a Helm 4 CLI (stub helm, kubectl)
    shared-lib/                      the shared common.sh block: identical in both repositories, retries, pod watch
    sync-engine/                     the Argo CD sync engine against a scripted Argo CD API
    rollout/                         rolloutMode (canary, batches, all) of the batch planner
    params/                          input types, generated policy, templates and docs agree
    cluster-map/                     clusterMap validation per workflow, the tpg-day0 version rule
    patch/                           tpg-patch planning (refused fields, patchMode, dry run)
    admission/, ssa/                 the admission policies and server-side apply on a real kube-apiserver
    envtest/                         starts etcd and kube-apiserver from the envtest binaries
    run-all.sh                       every suite, plus tpg-aks-infra/tests/verify and tests/argocd-rbac
                                     when it is a sibling
```

## One template for every cluster

There is no folder per cluster. Every cluster renders the same chart with the same two template files, and `clusters/fleet.yaml` holds only what differs:

```yaml
clusters:
  aks-tpg-poc-01:                  # registered cluster (Argo CD label tpg.fleet/managed=true)
    operator:
      version: v4.5.0              # required; tpg-day0 and tpg-upgrade write it
    cluster:
      maxReadReplicas: 5           # optional override of _template/cluster.yaml
    instances:
      orders-db:                   # namespace pg-orders-db, Application tpg-aks-tpg-poc-01-orders-db
        instance:
          postgresVersion: postgres-17.6
          highAvailability: {enabled: true, readReplicas: 2}
      billing-db:
        instance:
          postgresVersion: postgres-17.6
```

| Value | Source |
|---|---|
| Which clusters exist, and their wave | Cluster registration in `tpg-aks-infra` (Secret labels `tpg.fleet/managed`, `tpg.fleet/wave`) |
| Operator version, instances and their overrides | `clusters/fleet.yaml` |
| Defaults | `clusters/_template/cluster.yaml`, `clusters/_template/instance.yaml`, then `charts/tpg-instance/values.yaml` |
| `cluster.name`, backup container `pg-backups-<cluster>` | Set by the `tpg-instances` ApplicationSet |

The `tpg-operator` and `tpg-instances` ApplicationSets combine the registered clusters with `clusters/fleet.yaml` (matrix generator with a list generator per cluster). A registered cluster without an entry gets only `tpg-<cluster>-platform` until `tpg-day0` adds it. You normally never edit `fleet.yaml` by hand: the workflows write it, with `pushMode=direct` or `pushMode=pr`.

`clusters/fleet.yaml` ships empty (`clusters: {}`), because an entry declares what a cluster should run and an example left there would look like real state; `clusters/fleet.example.yaml` shows a filled-in file, including patch references. tpg-day0 compares its version inputs with what runs on each target, not with `fleet.yaml`: a version that nothing runs yet is replaced (`FLEET_OVERRIDDEN`), and a cluster that runs another version is blocked (`UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN`) until tpg-upgrade moves it.

## Get started

These steps run **before** the first `tpg-aks-infra/scripts/run.sh`. That script
reads this repository from disk (`FLEET_LOCAL_DIR`), not from GitHub: its
`vault`, `addons` and `bootstrap` steps apply files from the clone and run
`workflows/scripts/helm-addons.sh` out of it. A clone that still carries the
`<org>` placeholder fails those steps after the clusters have been changed.

1. Create an empty private GitHub repository named `tpg-fleet`, and clone it
   next to `tpg-aks-infra` (the tests in either repository find the other one
   when they are siblings).

2. Set the repository URL everywhere:

   ```bash
   cd tpg-fleet
   ./scripts/set-repo-url.sh https://github.com/<your-org>/tpg-fleet.git
   git grep -n '<org>' || echo "no placeholders left"
   ```

3. Review `clusters/_template/*.yaml`. `clusters/fleet.yaml` starts empty; `tpg-day0` adds clusters and instances from its inputs.

4. Keep the scripts executable and run the checks. Neither needs a cluster:

   ```bash
   chmod +x scripts/*.sh tests/run-all.sh tests/*/run.sh
   tests/run-all.sh        # CLI flags, Helm 4, shared library, sync engine, rollout modes, input types,
                           # clusterMap, tpg-patch, admission policies, server-side apply
   ./scripts/validate.sh   # yamllint, shellcheck, kustomize, helm lint/template, kubeconform
   ```

5. Push, so Argo CD and the workflows read the same content:

   ```bash
   git add -A && git commit -m "Set repository URL"
   git remote add origin https://github.com/<your-org>/tpg-fleet.git
   git push -u origin main
   ```

   The checked-out branch must be the one in `FLEET_REPO_REVISION` (`main` by default).

6. In `tpg-aks-infra`, set `env.sh` (`FLEET_LOCAL_DIR` points at this clone) and run `scripts/run.sh` for your scenario (hub with or without Argo; clusters from Terraform or pre-created). Its `addons` step installs the Helm add-ons and its `bootstrap` step applies `bootstrap/`.

### Helm 4

`toolsImage` is `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, takes a registry
domain without a path for `helm registry login`, and no longer runs an
executable path passed to `--post-renderer`. Both repositories are free of those
flags, and `tests/cli-flags` fails the build when one comes back. Commands here
work on Helm 3 and Helm 4 alike: the shared Helm helpers select release states with
`--deployed --failed --pending --superseded --uninstalled --uninstalling`
(`HR_LIST_ALL` in `workflows/scripts/common.sh`), which both versions accept.

## How delivery works

- **ApplicationSets** generate one Application per cluster and component: `tpg-<cluster>-platform`, `-operator`, and `tpg-<cluster>-<instance>`. They carry the labels `tpg.fleet/cluster`, `tpg.fleet/wave` and `tpg.fleet/component`.
- **Helm releases** outside Argo CD: `cert-manager` and `vault-secrets-operator` on every target, `vault` and `vault-secrets-operator` on the hub, and for standalone monitoring `kps` on the hub and `kps` + `tpg-ksm` on targets (`helm list -A`). Every install runs a pre-check first: an existing release of ours is compared (chart version and values) and upgraded, kept or skipped; a compatible foreign cert-manager or Vault Secrets Operator is reused; anything else blocks the run with what it found.
- **No automated sync** on those Applications. Workflows sync them through the Argo CD API as `workflow-bot`, cluster by cluster, canary first (or every cluster at once with `rolloutMode=all`).
- **Only the workflows sync the target Applications** (project `tpg`). Argo CD RBAC denies people `sync` (which also covers rollback), `override`, `update` and `delete` on `tpg/*` (a marked block in `policy.csv`, written by `tpg-aks-infra`). The hub admission policy `tpg-application-sync` refuses a new operation unless argocd-server writes it for `workflow-bot`, and refuses automated sync, which also covers a `kubectl edit`. Each workflow sync reports a sync started elsewhere as the warning `MANUAL_SYNC_DETECTED`. The hub Applications are in project `tpg-hub` and stay manageable.
- **Typed inputs.** Every WorkflowTemplate input has a type (`List`, `String`, `Boolean`, `Integer`, `Enum`, `Map`, ...) in `workflows/params/types.yaml`. The generated admission policy `tpg-workflow-parameters` rejects a Workflow whose inputs do not match, before it exists, with the input and its type in the message.
- **clusterMap.** day0, upgrade, patch, scale, backup, backup-retention, delete-instance and delete-apps take an optional `clusterMap` (YAML or JSON): the targets, with values per cluster and per instance. The keys, their types and the workflows that accept them are listed in `workflows/params/cluster-map-keys.yaml`; the validate step checks every key and suggests the closest one for a typo.
- **Patches without copies.** `tpg-patch` changes settings no other workflow owns, with patch files kept in this repository; `fleet.yaml` holds only references. The instance chart reads its patch files itself (`.Files.Get`), the operator Application loads value files as `$fleet/<path>` (multi-source), and operator manifest patches are applied with server-side apply as field manager `tpg-patch`, which the operator Application ignores (`managedFieldsManagers`, `RespectIgnoreDifferences=true`). Fields another workflow owns are refused with the name of that workflow.
- **One sync engine for every workflow** (`app_sync_wait` in `workflows/scripts/lib.sh`). It syncs the fleet commit the workflow pushed, follows only the operation its own request started, fails at once on a permanent error (admission webhook denied, invalid or immutable field) with Argo CD's message, syncs again with backoff on a transient one, and records `SUCCEEDED` only when the Application is Synced and the target is ready. Result reasons: `SYNC_REJECTED`, `SYNC_FAILED`, `SYNC_TIMEOUT`, `SYNC_DRIFT`, `SYNC_BUSY`, `HEALTH_TIMEOUT`, `POD_<REASON>`.
- **Health means Running.** Argo CD has a health check for the `Postgres` kind (`tpg-aks-infra/argo/argocd-values.yaml`): Healthy only when `status.currentState` is `Running`. While the workflows wait, they print the pods of the namespace every 5 seconds and stop at once when one cannot start (`CreateContainerConfigError`, `InvalidImageName`), or when `CrashLoopBackOff`, `ImagePullBackOff`, `Error` or `OOMKilled` lasts 60 seconds, or a pod stays unschedulable for 5 minutes; the failure prints the pod's events and logs.
- **The version of a running instance belongs to the PostgresVersionUpgrade.** The `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion` (`RespectIgnoreDifferences=true`): Git records the version, a new instance is created with it, and `tpg-upgrade` changes it. Argo CD applying the field made the operator's admission webhook reject the sync while an upgrade was being finished.
- **API calls are retried.** Every `kubectl`, `helm`, `az` and Argo CD API call in the scripts goes through `tpg_retry` (`workflows/scripts/common.sh`): a timeout, a dropped connection or an HTTP 429/502/503/504 from the AKS API server is retried up to 5 times (5, 10, 20, 40 s); anything else fails at once.
- **Databases are never pruned.** Postgres resources carry `Prune=false,Delete=false`, and the Postgres CR sets `persistentVolumeClaimPolicy: retain`.
- **Defaults the CRD drops are not declared.** `PostgresBackupLocation` serializes `spec.additionalParameters` and `spec.storage.azure.forcePathStyle` with `omitempty`, so the API server keeps nothing for an empty map or for `false`. An Application that declares them compares a desired object holding the keys with a live object that does not, and stays OutOfSync with a diff no sync can settle. The chart writes `forcePathStyle` only when it is true and `additionalParameters` only when it is non-empty (`charts/tpg-instance/values.yaml`), and the `tpg-instances` ApplicationSet lists those two paths under `ignoreDifferences` for clusters whose operator drops or adds them anyway.
- **`enableSSL` of the backup location is a parameter.** `backup.enableSSL` (default `false`: plain HTTP to Azure Blob) is set in `clusters/_template/cluster.yaml`, per cluster or per instance in `clusters/fleet.yaml`, or with the `tpg-day0` input `backupEnableSSL`. The chart always writes it, and the ApplicationSet ignores it because the CRD drops `false` too. `false` needs a storage account that accepts HTTP (Terraform `backup_storage_https_only = false`, the default).
- **High availability needs a data pool that can hold it.** `highAvailability=true` places a primary, a standby and the read replicas on different nodes and zones, so the pre-check refuses a cluster whose data pool does not span 3 zones with 3 Ready nodes. Single-node instances run on any pool shape.
- `tpg-hub-workflows` (templates, scripts, RBAC, admission policies) and the Azure monitoring Applications use automated sync because they hold no data.

## Secrets

No credential is stored in this repository or in a Kubernetes Secret that someone creates by hand. Three values live in HashiCorp Vault on the hub (`tpg/shared/broadcom-registry`, `github-read`, `github-push`, `backup-storage`), installed and filled by `tpg-aks-infra` (`scripts/steps/35-vault.sh`, `40-hub-secrets.sh`):

| Consumer | How it reads Vault |
|---|---|
| Argo Workflows steps | Vault Agent (injector on the hub) renders `/vault/secrets/*.json` before the step container starts, from the templates in the ConfigMap `tpg-vault-agent` (`workflows/vault-agent/`). Steps that need no credential set `vault.hashicorp.com/agent-inject: "false"` |
| Argo CD repositories | Two `VaultStaticSecret` objects in `argocd` build the repository Secrets for this Git repository and the Broadcom OCI registry |
| Operator and instance namespaces | `charts/tpg-instance/templates/vault-secrets.yaml` and `platform/base/vault-secrets.yaml` create a `VaultStaticSecret` for `regsecret` (image pull) and `backup-storage` (the key the `PostgresBackupLocation` uses), in sync wave -1 so the Secrets exist before the Postgres resources |

The Vault Secrets Operator keeps each Kubernetes Secret in step with Vault, and Argo CD reports a `VaultStaticSecret` as Healthy only once the Secret is synced, so the Postgres sync wave waits for it.

## Workflows

All workflows run in the `argo` namespace as `tpg-workflow`, write per-target results to the ConfigMap `tpg-run-<workflow-name>` (deleted with the workflow), and end with a report printed by the exit handler. When any target is `FAILED` or `TIMEOUT`, the report step fails so the run is flagged in the Argo UI and in the controller metrics.

Inputs are typed: a Workflow whose inputs do not match their types is rejected when it is submitted. Mandatory inputs have no default: the first step (`validate`) fails with the list of missing or invalid inputs and the registered cluster names. Where the table says "or `clusterMap`", the map replaces `clusters` and `instances` and can carry the other values per target. **[docs/workflow-commands.md](docs/workflow-commands.md) lists every input with its type, the `clusterMap` keys, several `argo submit` examples per workflow, and the related `argocd` commands.**

| Workflow | Purpose | Mandatory inputs |
|---|---|---|
| `tpg-day0` | Write the inputs to `fleet.yaml`, pre-check, install cert-manager, deploy operator and instances in waves | `clusters` and `instances` (or `clusterMap`), `highAvailability`, `operatorVersion`, `postgresVersion` (inputs or map keys), `pushMode` |
| `tpg-upgrade` | Upgrade the operator or Postgres instances in waves | `component`, `targetVersion`, `clusters`, `instances` (postgres), or `clusterMap` with versions; `pushMode` |
| `tpg-patch` | Apply patch files to deployed instances (Postgres spec, chart values) and operators (chart values, manifest patches) in waves | `clusters` (or `clusterMap`), one patch file input or map key, `instances` for instance files, `pushMode` |
| `tpg-scale-instance` | Set read replicas of the listed instances on the listed clusters | `clusters` and `instances` (or `clusterMap`), `replicas` (input or map key), `pushMode` |
| `tpg-delete-apps` | Delete instances and/or the operator and its CRDs per cluster | `clusters` and `apps` (or `clusterMap`), `confirm`, `dryRun`, `purgePvcs`, `purgeNamespace`, `pushMode` |
| `tpg-delete-instance` | Guarded delete of the listed instances on the listed clusters | `clusters` and `instances` (or `clusterMap`), `confirm` |
| `tpg-helm-addons` | cert-manager, the Vault Secrets Operator and the standalone monitoring agent Helm releases on targets | `clusters` |
| `tpg-backup` | On-demand backups, full or incremental (CronWorkflows run it on a schedule) | none (`backupType`, `clusters` default; `instances` or `clusterMap` narrow it) |
| `tpg-backup-retention` | Expire backup chains older than the retention window | none (`clusters`, `retentionDays`, `dryRun` default; `instances` or `clusterMap` narrow it) |
| `tpg-restore` | Restore an instance: point in time, latest, a named backup, an LSN or a transaction ID, into a new or an existing instance on the same or another cluster | `sourceCluster`, `instance`, `mode` and the recovery point of that mode |
| `tpg-rotate-credential` | Rotate registry, storage or Git credentials | `secretType` |

### Day 0: deploy

```bash
# Dry run: fleet.yaml diff and pre-checks (operator, CRDs, same-named instances, versions)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch

# Deploy: wave 0 canary alone, then later waves in batches of maxParallel (2)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# Every selected cluster at once, no canary
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p rolloutMode=all --watch
```

`rolloutMode` (also on `tpg-upgrade`): `canary` (default) runs the wave-0 cluster alone first, then the later waves in batches of `maxParallel`; `batches` skips the canary; `all` runs every selected cluster in one batch. One failing cluster does not stop the others of its batch; a failed batch stops the later ones.

| Pre-check status | Meaning |
|---|---|
| `PASSED` | Nothing Tanzu Postgres related on the cluster |
| `MANAGED` | Existing objects are tracked by this Argo CD (safe re-run) |
| `BLOCKED` | Foreign operator, foreign CRDs, same-named instance, missing Postgres version, a data pool that cannot hold an HA instance (`PGDATA_POOL_NOT_HA_CAPABLE`), or unreachable. The cluster is not changed |

### Day 1: upgrade, scale, backup, restore, rotate

```bash
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.7 -p clusters=all -p instances=all -p pushMode=pr --watch
argo submit -n argo --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p replicas=2 -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=orders-db -p pushMode=direct \
  -p postgresPatchFilePath=charts/tpg-instance/patches/example-postgres-resources.yaml --watch
argo submit -n argo --from workflowtemplate/tpg-backup -p backupType=full -p clusters=aks-tpg-poc-01 --watch
argo submit -n argo --from workflowtemplate/tpg-backup-retention -p clusters=all -p dryRun=true --watch
argo submit -n argo --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=time \
  -p targetTime=2026-09-15T08:30:00Z --watch
```

- **Upgrade:** minor or major is detected per instance; major needs `allowMajor=true` and pauses for `argo resume` before every batch after the canary. A full backup runs first (`preUpgradeBackup=true`). The `PostgresVersionUpgrade` is followed with the instance pods printed every 5 seconds; then the workflow waits for the operator to set `spec.postgresVersion.name`, writes the version to `fleet.yaml` and syncs at that commit. An instance whose Application does not end Synced is `FAILED` (with Argo CD's message), not `SUCCEEDED`, and later batches do not run.
- **Operator upgrade and manifest patches:** the upgrade sync runs once without `RespectIgnoreDifferences`, so the new chart applies cleanly. With `operatorPatches=keep` (default) every field the patch overrides is reported (`OPERATOR_PATCH_OVERRIDES`) and the patches are applied again; `operatorPatches=drop` removes the manifest patch references and releases the patched objects.
- **Patch:** `tpg-patch` checks the files, writes the references to `fleet.yaml`, dry-runs the result on every target (`--dry-run=server`), commits once, then syncs canary first. A refused file or a failed dry run blocks that cluster only (`PATCH_REFUSED`). `patchMode` `append` (default), `replace` or `remove` edits the lists.
- **Backups:** one full backup on Sunday, an incremental one on the other days. Every incremental backup belongs to the chain of the last full backup, so a chain is only ever expired as a whole. If the previous backup is still `Pending` or `Running`, the workflow waits 2 minutes and reports `SKIPPED_IN_PROGRESS`. Instances with `backupSchedule=none` are skipped by the CronWorkflows.
- **Retention:** `tpg-backup-retention` runs daily. It groups the backups of each instance into chains (a full backup and the incrementals that follow it), expires every chain whose newest backup is older than `retentionDays` (35 by default, `backup.retentionDays` per cluster or instance), and always keeps the newest chain, whatever its age. `dryRun=true` reports what it would expire.
- **Restore:** `tpg-restore` restores into a new instance (a one-off clone on the same cluster, or a cluster member added to `clusters/fleet.yaml` and adopted by Argo CD on another cluster) or into an existing one (in place or another instance, which requires `confirm=<instance>` because it overwrites data). For a restore into another namespace or cluster, the workflow creates a read-only copy of the source backup location so `backupSync` lists the source backups there.
- **Credential rotation:** update the value in Vault, then run `tpg-rotate-credential` with `secretType` `broadcom-registry`, `backup-storage`, `git-push` or `git-read`. The workflow verifies that the new value reached every consumer (VaultStaticSecrets, Argo CD repository connection, image pull, backup location, the Blob container).

### Day 2: delete

```bash
# Plan, then run with dryRun=false
argo submit -n argo --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03 -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03 -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch
```

Instances leave `clusters/fleet.yaml` (a copy goes to `clusters/deleted/<cluster>/`), the Applications are removed without cascading (`preserveResourcesOnDeletion`), and the workflow deletes the objects in order. With `tpg-operator` it also deletes the operator and the `sql.tanzu.vmware.com` CRDs, refusing while other Postgres instances exist unless `force=true`. The backup repository is never deleted.

## Workflow logs

Every step's log is archived to Azure Blob when the step ends (`archiveLogs`, container `argo-logs` in the backup storage account), through the namespace default artifact repository `argo/artifact-repositories` that `tpg-aks-infra` creates in its `hub-secrets` step, with the account key from Vault (`VaultStaticSecret argo/argo-artifacts`). The Argo UI shows the logs of a finished step even after its pod is gone, for as long as the Workflow exists (7 days); `tpg-aks-infra/scripts/wf-logs.sh <workflow>` reads them afterwards, until the lifecycle rule deletes them (90 days by default).

## Monitoring

| Option | Apply | Dashboards and alerts |
|---|---|---|
| A: Azure Monitor | `MONITORING_OPTION=azure` in `tpg-aks-infra/env.sh`, `enable_azure_monitor = true` in Terraform. The `addons` step enables the managed Prometheus add-on on any cluster that lacks it (a new or pre-created cluster), checks its `ama-metrics` pods and the Grafana role on the workspace | Imported by the `addons` step, or `monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc` |
| B: Standalone | `MONITORING_OPTION=standalone`; the `addons` step installs Helm release `kps` and the remote-write gateway on the hub, and `kps` + `tpg-ksm` on every target, then checks that each target's metrics reach the hub | Provisioned automatically (dashboard ConfigMaps in the folder Tanzu Postgres, `grafana.alerting` values) |

**How the targets reach the hub (standalone).** Each target's Prometheus writes to the hub gateway `tpg-remote-write` (nginx, `monitoring/standalone/hub/remote-write-gateway.yaml`): https on port 8443 with a certificate from the Vault CA, basic auth with the credential in Vault `tpg/shared/monitoring-remote-write` (synced to each target as `monitoring/tpg-remote-write`), and only `/api/v1/write` forwarded to the hub Prometheus. Its load balancer is internal or public (restricted to the target egress CIDRs), from the `tpg-aks-infra` inventory `monitoring.remoteWriteExposure`. A new cluster is wired the same way by `tpg-day0` (`installAddons=true`) and `tpg-helm-addons`, and both fail with `MONITORING_NOT_FLOWING` when its metrics do not reach the hub within 5 minutes. Grafana's data sources (Prometheus `uid prometheus`, Alertmanager `uid alertmanager`) are set explicitly in `monitoring/standalone/hub/kps-values.yaml`.

Both options scrape the `postgres-exporter` container that the operator runs in every Postgres pod with a `PodMonitor` every 10 seconds (`scrapeTimeout` 8s), and both watch Vault on the hub (`servicemonitor-vault.yaml`, alert `tpg-vault-sealed`: a sealed or unreachable Vault stops every credential from being renewed).

Five dashboards, all with the data source and cluster variables, in the folder **Tanzu Postgres**:

| Dashboard | Shows |
|---|---|
| Tanzu Postgres Fleet (`tpg-fleet`) | Instances per cluster, healthy and unhealthy instances, ready and desired replicas, backup and restore counts, backup workflow results, hours since the last backup, replication lag, WAL archive failures, connection usage, active alerts |
| Instance overview (`tpg-instance`) | Per instance: operator state, exporter and `pg_up` per pod, connections (used % and by state), transactions, cache hit ratio, rows, database size, locks, deadlocks, longest transaction, volume usage, CPU, memory and restarts of the Postgres pods |
| Replication and HA (`tpg-replication`) | Role per pod, pods ready against desired, desired read replicas, replication lag against the 30 s alert threshold, WAL archived and failed, restarts |
| Backup, WAL and restore (`tpg-backup`) | Hours since the newest full and the newest backup, backups by phase and type, backups in the last 24 hours, backup and retention workflow results, WAL archiving, restores by phase and restore workflow results |
| Alerts (`tpg-alerts`) | The firing and pending alerts, the Prometheus `ALERTS` series, and one panel per configured rule with its expression over time and the threshold as a line |

Alert and dashboard definitions live in `monitoring/grafana/generate.py`. After changing them, regenerate the Grafana provisioning values, the API payloads, the PrometheusRule and the dashboards:

```bash
python3 monitoring/grafana/generate.py
```

Email notifications are optional: see `monitoring/grafana/smtp/` (Grafana SMTP for both options) and `monitoring/prometheus/alertmanager-smtp-values.yaml` (Prometheus alerts through Alertmanager). For the standalone hub, pass them with `KPS_HUB_EXTRA_VALUES` to `tpg-aks-infra/scripts/run.sh --only addons`.

## Adding a cluster or an instance

- **Instance:** run `tpg-day0 -p clusters=<cluster> -p instances=<name> ...`. It adds the instance to `clusters/fleet.yaml` and deploys it.
- **Cluster:** create it with `tpg-aks-infra` (`target_cluster_count`) or add a pre-created cluster to `inventory/clusters.yaml` with `wave: 1` or higher, run `tpg-aks-infra/scripts/run.sh` again, then run `tpg-day0 -p clusters=<cluster> ...`. No file or folder is added by hand.

## Static validation

`scripts/validate.sh` runs the same checks used before delivery: `yamllint`, `shellcheck`, `kustomize build`, the `clusters/fleet.yaml` structure, `helm lint` and `helm template` of the instance chart for every `fleet.yaml` instance (with the values the ApplicationSet passes), `kubeconform` (Kubernetes, Argo and Prometheus Operator schemas from the CRDs catalog), and JSON parsing of the dashboard and alert payloads. It also checks that the chart renders `enableSSL` (false by default, true when set), that the `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion`, and that the five dashboards exist and are in the hub kustomization. It checks `clusters/fleet.yaml` and `clusters/fleet.example.yaml` alike (structure, and that every referenced patch file exists), renders the chart with the example patch files (`chart: patch files are merged`), and fails when `workflows/admission/workflow-parameters.yaml` is not what `workflows/params/generate.py` makes of `types.yaml`. It ends with `tests/run-all.sh`.

`tests/run-all.sh` runs on its own too, and needs no cluster. Suites that need a binary that is not installed (`helm`, the envtest API server, the `argocd` CLI) print `SKIP` and pass; `tests/README.md` says what each needs:

- `tests/cli-flags` reads every command in both repositories and fails on a flag the pinned CLI version no longer accepts (`rules.yaml` says which, why and what to write instead). Its fixtures plant one violation per rule, so a rule that stops matching fails the suite. `--against-cli` additionally asks each installed binary for its own flags and reports anything it does not know.
- `tests/helm4` runs `workflows/scripts/helm-addons.sh` against a stub Helm 4 CLI through every pre-check outcome (`DRY_RUN`, `UP_TO_DATE`, `SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING`, `BLOCKED`). The stub rejects `-a` on `helm list` the way Helm 4 does.
- `tests/shared-lib` checks that the shared block of `workflows/scripts/common.sh` is identical to the one in `tpg-aks-infra`, and drives the retries and the pod watch with stubs.
- `tests/sync-engine` drives the Argo CD sync engine with scripted API answers: an old operation is not the answer, a webhook denial fails at once, a transient error is retried, drift and timeouts are reported.
- `tests/rollout` checks the batches of each `rolloutMode`.
- `tests/params` checks that the input types, the generated admission policy, the WorkflowTemplates (names, defaults, enums), the clusterMap key registry and the Type columns of `docs/workflow-commands.md` agree.
- `tests/cluster-map` drives the validate step of every workflow that takes `clusterMap` (unknown keys with suggestions, types, required values, exclusive inputs, `confirm`), and runs `fleet-day0.sh` against stub clusters for the version rule of tpg-day0.
- `tests/patch` runs the tpg-patch plan with the real chart and stubs: refused fields, `patchMode`, the postgresVersion guard, the dry-run document (needs `helm`).
- `tests/admission` evaluates both admission policies on a real kube-apiserver with the Argo CD and Argo Workflows CRDs; `tests/ssa` proves the field ownership of operator manifest patches through syncs with and without `RespectIgnoreDifferences`, an upgrade and a release (both need the envtest binaries).
- `tpg-aks-infra/tests/argocd-rbac` evaluates the RBAC deny block with the real `argocd admin settings rbac can`: people cannot sync, override, update or delete a tpg Application, `workflow-bot` can sync, and the functions `check-argo.sh` uses (`scripts/lib/argo-rbac.sh`) find every subject that can still act on project `tpg` and merge the marked block into an existing `policy.csv`.
- `tpg-aks-infra/tests/verify` drives `scripts/steps/60-verify.sh` against a stubbed cluster and asserts that a missing object is named as missing rather than reported as a wrong field value, and that the summary groups each resource with the clusters it fails on.

## Items to validate in the lab

The Tanzu for Postgres custom resources have no public JSON schema, so confirm these on the first lab cluster:

| # | Item | How |
|---|---|---|
| V1 | `spec.storage.azure` fields and `backup-storage` keys (`accountName`, `accountKey`) | `kubectl explain postgresbackuplocation.spec.storage.azure`, then one manual backup |
| V2 | Minor upgrades through `PostgresVersionUpgrade`, and whether the operator updates `spec.postgresVersion.name` | Upgrade a test instance by one minor version |
| V3 | Operator upgrade by Argo CD, including CRD updates and instance pod rollout | Run `tpg-upgrade -p component=operator` on the canary |
| V4 | In-place PITR with `pitr.type: time` on an existing instance | Restore a disposable instance with `inPlace=true` |
| V5 | kube-state-metrics timestamp gauges exported as unix seconds | `curl` the `tpg-ksm` metrics endpoint, grep `tanzu_postgres_` |
| V6 | postgres-exporter metric names used in alerts | Port-forward 9187 on a data pod and grep `pg_` |
| V7 | Argo Workflows custom metric names (`argo_workflows_tpg_*_total`) | `curl` the workflow controller metrics Service |
| V8 | `alpine/k8s:1.35.8` and `azure-cli:2.90.0` tags pullable from the hub | `kubectl run` a test pod with each image |
| V9 | Re-creating a deleted instance reattaches retained PVCs | Delete with defaults, then run `tpg-day0` for the instance again |
| V10 | `tpg-delete-apps` with `tpg-operator` removes all 7 `sql.tanzu.vmware.com` CRDs and leftover webhooks | Run on a lab cluster; `kubectl get crd,validatingwebhookconfigurations` |
| V11 | ApplicationSet matrix with `elementsYaml` renders one Application per `fleet.yaml` instance | `argocd appset get tpg-instances`; `argocd app list -l tpg.fleet/component=instance` |
| V12 | Pull request mode with the fine-grained PAT (Pull requests: Read and write) | `tpg-scale-instance -p pushMode=pr -p dryRun=false` on a test instance |
| V13 | `VaultStaticSecret` status conditions of Vault Secrets Operator 1.5.1 (`Ready` and/or `SecretSynced`), which the Argo CD health check reads | `kubectl -n argocd get vaultstaticsecret repo-tpg-fleet -o yaml`; `argocd app get` shows the resource health |
| V14 | Vault Agent injection in the workflow pods: `/vault/secrets/*.json` present and readable | `argo submit --from workflowtemplate/tpg-backup -p dryRun=true`, then `kubectl -n argo exec <pod> -- ls /vault/secrets` |
| V15 | `PostgresBackup.spec.expire` expires the whole chain of a full backup, and `status.phase` afterwards | `tpg-backup-retention -p dryRun=false` on a disposable instance with several chains |
| V16 | `PostgresRestore` with `pitr.type: time`, `latest`, `lsn` and `transaction`, and `sourceBackupLocation.stanzaName` of a copied backup location | `tpg-restore` in each mode on a disposable instance |
| V17 | `backupSync` on the read-only copy of a source backup location lists the source backups in the target namespace | Cross-namespace `tpg-restore`, then `kubectl -n pg-<target> get postgresbackup` |
| V18 | Deleting the copied backup location (label `tpg.fleet/restore-source`) removes only the synced objects | Delete it after a validated restore and check the source namespace |
| V19 | Auto-unseal with the Azure Key Vault key after a `vault-0` restart (`vault_unseal_mode = "azure-keyvault"`) | `kubectl -n vault delete pod vault-0`, then `kubectl -n vault exec vault-0 -- vault status` |
| V20 | Helm version in the tools image, and `helm list` without `-a` | `kubectl -n argo run helmcheck --rm -it --image=alpine/k8s:1.35.8 --restart=Never -- helm version --short` and `... -- helm list -A` |
| V21 | `PostgresBackupLocation` stays Synced: the applied object carries neither `additionalParameters` nor `storage.azure.forcePathStyle`, and the Application reports Synced after two refreshes | `kubectl -n pg-orders-db get postgresbackuplocation orders-db-backup-location -o yaml`; `argocd app get tpg-<cluster>-orders-db --hard-refresh` |
| V22 | `60-verify.sh` names a missing object instead of reporting a wrong value | Delete `storageclass tpg-data-retain` on a lab target, run `scripts/run.sh ... --only verify`, then re-apply it |
| V23 | A step that fails before it records a result reports `UNEXPECTED_ERROR` with the line number, not `UNKNOWN` | Revoke the workflow ServiceAccount's access to `configmap/tpg-run-<workflow>` mid-run, or `kubectl -n argo delete secret kubeconfig-<cluster>` before a `tpg-backup` run; read `kubectl -n argo get configmap tpg-run-<workflow> -o yaml` |
| V24 | Argo CD reports a new instance Progressing until `status.currentState` is `Running`, then Healthy (Postgres health check) | `argocd app get tpg-<cluster>-orders-db` during `tpg-day0` |
| V25 | The pod watch stops a run on a pod that cannot start, and prints its events and logs | Deploy an instance with a wrong `storageClassName` (unschedulable) or break `regsecret`, read the step log |
| V26 | `tpg-upgrade component=postgres` ends Synced with no webhook rejection: the operator writes `spec.postgresVersion.name`, and Argo CD ignores the field | Minor upgrade of a test instance; the log shows `spec.postgresVersion.name is postgres-<target>`; `argocd app get` shows Synced |
| V27 | The sync engine pins the fleet commit and reports a rejected sync as `SYNC_REJECTED` | Break an instance spec by hand in Git, run `tpg-scale-instance`, read `tpg-run-<workflow>` |
| V28 | `rolloutMode=all` starts every cluster in the same batch | `tpg-day0 -p rolloutMode=all -p dryRun=false`; `argo get @latest` shows one batch |
| V29 | Archived logs: the Argo UI shows the log of a step whose pod was deleted, and `scripts/wf-logs.sh` reads it after the Workflow is deleted | Run any workflow, `argo delete` it, then `tpg-aks-infra/scripts/wf-logs.sh <workflow>` |
| V30 | `enableSSL: false` backups work against the storage account (HTTP accepted), and `true` works with HTTPS | One backup per setting on a disposable instance |
| V31 | Standalone: each target's metrics reach the hub through the gateway (basic auth, Vault CA); Grafana lists the two data sources and the folder Tanzu Postgres | `count by (cluster) (up)` in Grafana Explore; `kubectl -n monitoring logs deploy/tpg-remote-write` shows 204 |
| V32 | Azure option: a pre-created cluster without the managed Prometheus add-on gets it from the `addons` step, and its data appears in Managed Grafana | `az aks show --query azureMonitorProfile.metrics.enabled`; `Tanzu Postgres - Instance overview` |
| V33 | The five dashboards show data with the exporter's metric names on the operator 4.5 image (`pg_stat_database_*`, `pg_locks_count`, `pg_replication_is_replica`, `pg_stat_archiver_*`) | Open each dashboard; a panel with no data points to a metric name to adjust in `generate.py` |
| V34 | The admission policy `tpg-workflow-parameters` rejects a Workflow whose input has the wrong type and names the input | `argo submit --from workflowtemplate/tpg-day0 -p maxParallel=abc ...`: rejected, no Workflow created |
| V35 | The admission policy `tpg-application-sync` refuses a sync from the Argo CD UI and accepts the workflows' syncs; the username the workflows produce is `workflow-bot` or `workflow-bot:apiKey` | Sync a target Application in the UI; run `tpg-scale-instance`; `argocd app get <app> -o json \| jq .status.operationState.operation.initiatedBy` |
| V36 | The RBAC block denies people `sync`, `rollback`, `terminate-op` and `set` on `tpg/*` and leaves `tpg-hub-workflows` manageable | Each command as admin on a target Application; `argocd app sync tpg-hub-workflows` |
| V37 | `check-argo.sh --yes` finds every subject that can act on project `tpg` on an existing hub (SSO groups, `policy.default`) and closes the gap | `--only hub` on an existing hub with an SSO group role, then again without `--yes`: no `ARGO_RBAC_MISSING` |
| V38 | The operator Application renders from two sources: the OCI chart with `$fleet` value files | `tpg-patch` with `operatorValuesPatchFilePath` on the canary; `argocd app get <app> -o json \| jq .spec.sources`; `argocd app manifests` |
| V39 | A sync with `RespectIgnoreDifferences` keeps the fields owned by the `tpg-patch` field manager | `tpg-patch` with `patches/operator/example-operator-placement.yaml`, then any workflow sync of the operator Application: the `nodeSelector` stays |
| V40 | `operatorPatches=keep` reports `OPERATOR_PATCH_OVERRIDES` and applies the patches again; `drop` releases them | `tpg-upgrade component=operator` on the canary with a manifest patch, once with each value |
| V41 | A Postgres patch (resources) rolls out through the operator without `SYNC_REJECTED` | `tpg-patch -p postgresPatchFilePath=charts/tpg-instance/patches/example-postgres-resources.yaml` on a disposable instance |
| V42 | `tpg-day0` reports `FLEET_OVERRIDDEN` where nothing runs and blocks a cluster that runs another operator version | Declare a version by hand for an empty cluster and run `tpg-day0` with another; repeat on a running cluster (`UPGRADE_REQUIRED` or `DOWNGRADE_NOT_ALLOWED`) |
| V43 | `scripts/validate.sh` passes with the `helm` binary (`helm lint` and `helm template` with the example patch files) | On a workstation with Helm 3 or 4: `./scripts/validate.sh` |
