# Workflow command reference

Every tpg operation is an Argo Workflows `WorkflowTemplate` in the `argo` namespace on the hub. You start a run with the **argo CLI** (`argo submit --from workflowtemplate/<name>`). Argo CD does not start workflows: the workflows call the Argo CD API to refresh and sync Applications. The **argocd CLI** commands at the end of this page inspect what the workflows did; people cannot sync the tpg target Applications themselves (section 16).

Every input has a type (section 2). A Workflow whose inputs do not match their types is rejected when it is submitted, and no Workflow is created. Mandatory inputs have no default: a run without them fails in its first step (`validate`), which lists every missing or invalid input, including the registered cluster names.

## Contents

1. [Set up the CLIs](#1-set-up-the-clis)
2. [Input types and conventions](#2-input-types-and-conventions)
3. [clusterMap](#3-clustermap)
4. [tpg-day0](#4-tpg-day0)
5. [tpg-upgrade](#5-tpg-upgrade)
6. [tpg-patch](#6-tpg-patch)
7. [tpg-scale-instance](#7-tpg-scale-instance)
8. [tpg-delete-apps](#8-tpg-delete-apps)
9. [tpg-delete-instance](#9-tpg-delete-instance)
10. [tpg-helm-addons](#10-tpg-helm-addons)
11. [tpg-backup](#11-tpg-backup)
12. [tpg-backup-retention](#12-tpg-backup-retention)
13. [tpg-restore](#13-tpg-restore)
14. [tpg-rotate-credential](#14-tpg-rotate-credential)
15. [Follow, approve, stop and clean up runs](#15-follow-approve-stop-and-clean-up-runs)
16. [argocd CLI: inspect the sync steps behind the workflows](#16-argocd-cli-inspect-the-sync-steps-behind-the-workflows)

---

## 1. Set up the CLIs

```bash
# Kubeconfig written by tpg-aks-infra/scripts/run.sh (context aks-tpg-hub)
export KUBECONFIG=~/src/tpg-aks-infra/.work/kubeconfig
export ARGO_NAMESPACE=argo            # every command below then works without -n argo

argo version
argo template list
```

To use the Argo Workflows server instead of the Kubernetes API (for example from a laptop without cluster access), see `tpg-aks-infra/docs/README-argo-on-aks.md` and set `ARGO_SERVER`, `ARGO_HTTP1=true`, `ARGO_SECURE=true` and `ARGO_TOKEN`.

```bash
# argocd CLI against the hub (port-forward works without a public UI)
kubectl --context aks-tpg-hub -n argocd port-forward svc/argocd-server 18080:443 >/dev/null 2>&1 &
argocd login localhost:18080 --username admin --insecure --grpc-web \
  --password "$(kubectl --context aks-tpg-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

## 2. Input types and conventions

Argo Workflows passes every input as a string. The types below are declared once in `workflows/params/types.yaml` and enforced by the hub's Kubernetes API server (ValidatingAdmissionPolicy `tpg-workflow-parameters`, generated from that file). The check applies to `argo submit`, the Argo UI, the API and CronWorkflows alike. A rejected submission names every wrong input and its type, for example:

```text
tpg-day0: maxParallel="abc" must be an Integer (1 or more); dryRun="yes" must be a Boolean (true or false). See docs/workflow-commands.md
tpg-scale-instance: cluster is not an input of tpg-scale-instance. See docs/workflow-commands.md
```

| Type | Accepted values | Example |
|---|---|---|
| `List` | Comma-separated names (lowercase DNS labels). Where the table says so, `all` selects every registered cluster or every declared instance. `components` takes `auto`, or a list of `cert-manager`, `vso` and `monitoring` | `aks-tpg-poc-01,aks-tpg-poc-02`, `all` |
| `List (paths)` | Comma-separated `.yaml` or `.yml` paths in the tpg-fleet repository, relative to its root | `charts/tpg-instance/patches/a.yaml,charts/tpg-instance/patches/b.yaml` |
| `String` | Any text | `alpine/k8s:1.35.8` |
| `String (name)` | One lowercase DNS label (a Kubernetes object name for `backupName`) | `orders-db` |
| `String (version)` | Operator: `v4.5.0` (`4.5.0` is accepted). Postgres: `postgres-17.6` (`17.6` is accepted; the version must exist in `kubectl get postgresversion`) | `v4.5.1`, `postgres-16.10` |
| `String (quantity)` | A Kubernetes quantity | `20Gi`, `500m`, `2` |
| `String (UTC time)` | `YYYY-MM-DDThh:mm:ssZ` | `2026-09-15T08:30:00Z` |
| `String (LSN)` | A log sequence number | `0/3000060` |
| `Boolean` | `true` or `false` | `true` |
| `Integer` | Digits only. Counts can be 0; timeouts and `maxParallel` start at 1 | `3`, `1800` |
| `Enum` | One of the values in the Description column | `direct` |
| `Map` | YAML or JSON (section 3) | `{"aks-tpg-poc-01": {"instances": {"orders-db": {"replicas": 2}}}}` |
| `Map (JSON)` | A JSON object | `{"aks-tpg-poc-01": ["tpg-operator"]}` |

Inputs used by several workflows:

| Common input | Type | Values | Used by |
|---|---|---|---|
| `clusters` | `List` | Registered clusters, or `all` where accepted | every workflow except restore |
| `instances` | `List` | Declared instances, or `all` where accepted | day0, upgrade, patch, scale, backup, backup-retention, delete-instance |
| `clusterMap` | `Map` | Targets with per-cluster and per-instance values (section 3); replaces `clusters` and `instances` | day0, upgrade, patch, scale, backup, backup-retention, delete-instance, delete-apps |
| `pushMode` | `Enum` | `direct`: push the `clusters/fleet.yaml` change to the fleet branch. `pr`: push a branch, open a GitHub pull request and continue once it is merged (`prTimeoutSeconds`, default 3600) | day0, upgrade, patch, scale, delete-apps, delete-instance, restore |
| `dryRun` | `Boolean` | `true`: validate and record the plan; change nothing | day0, upgrade, patch, scale, delete-apps, helm-addons, backup-retention |
| `rolloutMode` | `Enum` | `canary` (default): the wave-0 cluster alone, then the other waves in batches of `maxParallel`. `batches`: no canary, batches of `maxParallel` in wave order. `all`: every selected cluster in one batch | day0, upgrade, patch |

- Put values that contain commas, spaces or JSON in single quotes.
- `-p name=value` sets one input. `--parameter-file inputs.yaml` reads several from a file (examples in each section). In a parameter file, quote `true`, `false` and numbers, and write `clusterMap` as a block (`clusterMap: |`).
- `--watch` follows the run in the terminal. Without it, the command prints the workflow name.
- `--name` or `--generate-name` sets the workflow name, which is also the results ConfigMap `tpg-run-<name>`.
- Every run ends with a report (exit handler). `argo logs @latest -c main | sed -n '/tpg run report/,$p'` prints it again. Warnings (section 15) have their own part of the report.
- Instance lists are checked against `clusters/fleet.yaml` before anything changes: an instance that is not declared on a selected cluster fails the run with `UNKNOWN_INSTANCE` and the list of declared instances.
- While a step waits for pods (Helm releases, the operator, instances, upgrades, scale, patch, restore), it prints the pod table of the namespace every 5 seconds and stops as soon as a pod cannot start. The failure reason is `POD_<REASON>` (for example `POD_CRASHLOOPBACKOFF`, `POD_CREATECONTAINERCONFIGERROR`, `POD_UNSCHEDULABLE`), followed in the log by the pod's status, events and the logs of the failing container. `CreateContainerConfigError`, `CreateContainerError`, `InvalidImageName` and `RunContainerError` fail at once; `CrashLoopBackOff`, `ImagePullBackOff`/`ErrImagePull`, `Error` and `OOMKilled` after 60 seconds; an unschedulable or Pending pod after 5 minutes.
- Transient API errors (timeouts, connection resets, HTTP 429/502/503/504) of `kubectl`, `helm`, `az` and the Argo CD API are retried up to 5 times with 5, 10, 20 and 40 seconds between attempts (`TPG_RETRY_ATTEMPTS`, `TPG_RETRY_DELAY`); the log shows `<tool> <verb>: transient error (attempt n/5), retrying in Ns: <error>`.
- Argo CD syncs are made at the fleet commit the run pushed; a sync the API server rejects (admission webhook, invalid field) fails the step at once with Argo CD's message.
- `toolsImage` (`String`, default `alpine/k8s:1.35.8`) is the image every step runs in. It is an input of every workflow and is not listed in the tables below.

---

## 3. clusterMap

`clusterMap` selects the targets of a run (clusters, and the instances on each) and carries values that differ per cluster or per instance. It is optional. A run takes either `clusterMap` or the `clusters` and `instances` inputs, not both. The other inputs stay the defaults of every target, and a map key overrides them for one cluster or one instance.

```yaml
<cluster>:                  # a registered cluster
  <cluster key>: <value>
  instances:
    <instance>:             # an instance (namespace pg-<instance>)
      <instance key>: <value>
```

It is written as YAML or JSON. Values can be YAML booleans and numbers (`true`, `2`); a Postgres version written as a number (`16.10`) keeps its trailing zero. The accepted keys are listed in `workflows/params/cluster-map-keys.yaml`; adding a key is one entry there. The `validate` step checks the whole map before anything changes:

- every cluster is registered, and every name is a DNS label;
- every key exists and the workflow accepts it (an unknown key names the closest known one: `replica` gives "did you mean replicas?"; an invalid name shows a valid form: `orders_db` gives "for example orders-db"; an unregistered cluster names the closest registered one);
- every value has the key's type;
- every required value is present, from the map key or from the workflow input of the same name;
- day0, backup, backup-retention, scale and delete-instance need at least one instance per cluster. In upgrade, patch and delete-apps, a cluster without instances must carry its cluster-level action (`operatorVersion`, an operator patch file, `deleteOperator`).

Cluster keys:

| Key | Type | Workflows | Meaning |
|---|---|---|---|
| `operatorVersion` | `String (version)` | day0 (required: key or input), upgrade | Operator chart version of the cluster |
| `maxReadReplicas` | `Integer` | day0 | `clusters.<c>.cluster.maxReadReplicas` (template default 3); no workflow input |
| `operatorValuesPatchFilePath` | `List (paths)` | patch | Operator chart value files under `patches/operator/` |
| `operatorManifestPatchFilePath` | `List (paths)` | patch | Operator manifest patches under `patches/operator/` |
| `patchMode` | `Enum` | patch | `append`, `replace` or `remove`, for the operator files of this cluster |
| `deleteOperator` | `Boolean` | delete-apps | `true` deletes the operator and its CRDs after the listed instances |
| `force` | `Boolean` | delete-apps | As the `force` input, for this cluster |

Instance keys:

| Key | Type | Workflows | Meaning |
|---|---|---|---|
| `postgresVersion` | `String (version)` | day0 (required), upgrade; a guard in patch, scale, backup, backup-retention, delete-instance and delete-apps | day0 and upgrade: the version to deploy or upgrade to. Guard: when set, an instance that runs another version is skipped (`SKIPPED_VERSION_MISMATCH`) and nothing is changed for it |
| `highAvailability` | `Boolean` | day0 (required) | As the input |
| `readReplicas`, `storageSize`, `walStorageSize`, `storageClass`, `cpu`, `memory`, `backupSchedule` | as the inputs | day0 | As the tpg-day0 inputs |
| `enableSSL` | `Boolean` | day0 | As `backupEnableSSL` |
| `postgresPatchFilePath`, `valuesPatchFilePath` | `List (paths)` | patch | Instance patch files under `charts/tpg-instance/patches/` |
| `patchMode` | `Enum` | patch | For the instance files of this instance |
| `preUpgradeBackup`, `allowMajor` | `Boolean` | upgrade | As the inputs |
| `replicas` | `Integer` | scale (required: key or input) | Read replicas |
| `enableHAIfNeeded` | `Boolean` | scale | As the input |
| `backupType` | `Enum` | backup | As the input |
| `backupTimeoutSeconds` | `Integer` | backup | As the input |
| `retentionDays` | `Integer` | backup-retention | As the input |
| `finalBackup` | `Enum` | delete-instance, delete-apps | As the input |
| `purgePvcs`, `purgeNamespace` | `Boolean` | delete-instance, delete-apps | As the inputs |

A map in a parameter file:

```yaml
# scale.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {replicas: 2}
      billing-db: {replicas: 0}
  aks-tpg-poc-02:
    instances:
      orders-db: {replicas: 3, postgresVersion: postgres-17.6}
```

```bash
argo submit --from workflowtemplate/tpg-scale-instance --parameter-file scale.yaml --watch
# the same map inline as JSON
argo submit --from workflowtemplate/tpg-scale-instance -p pushMode=direct \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"replicas":2},"billing-db":{"replicas":0}}}}' --watch
```

---

## 4. tpg-day0

Writes the inputs to `clusters/fleet.yaml`, pre-checks every selected cluster, installs cert-manager (and the standalone monitoring agent) as Helm releases, then syncs the operator and instance Applications: by default wave 0 alone first, then the other waves in batches of `maxParallel` (`rolloutMode`).

The operator step waits until the Postgres CRDs are Established and the operator Deployment is available on the target, then hard-refreshes the Application, so it does not wait for the Argo CD cache. When the cluster has operator manifest patches (section 6), they are applied again after the operator sync. An instance is ready when the Postgres resource reports `Running` and its StatefulSets are ready; Argo CD shows it Progressing until then.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | yes, without `clusterMap` | | Instances to deploy on every selected cluster (namespace `pg-<instance>`) |
| `clusterMap` | `Map` | no | | Targets and per-target values (section 3); replaces `clusters` and `instances` |
| `highAvailability` | `Boolean` | yes (input or map key) | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `operatorVersion` | `String (version)` | yes (input or map key) | | Operator chart version |
| `postgresVersion` | `String (version)` | yes (input or map key) | | PostgresVersion name |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `readReplicas` | `Integer` | no | `1` | Read replicas when `highAvailability=true` (0 to `maxReadReplicas`, default 3) |
| `storageSize`, `walStorageSize` | `String (quantity)` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | `String (name)` | no | template (`tpg-data-retain`) | StorageClass |
| `cpu`, `memory` | `String (quantity)` | no | template (requests 1/2Gi, limits 2/4Gi) | Request and limit per Postgres pod |
| `backupSchedule` | `Enum` | no | `fleet` | `fleet`: included in `tpg-backup-full` and `tpg-backup-incr`; `none`: excluded |
| `installAddons` | `Boolean` | no | `true` | Install or upgrade cert-manager (and the standalone monitoring agent) |
| `existingAddons` | `Enum` | no | `skip` | A Helm release that differs: `skip` or `upgrade` (section 10) |
| `monitoringOption` | `Enum` | no | `tpg-settings` | Override: `none`, `azure`, `standalone` |
| `backupEnableSSL` | `Boolean` | no | `false` | `enableSSL` of the instances' `PostgresBackupLocation`: `false` uses HTTP to Azure Blob (the storage account must accept HTTP, Terraform `backup_storage_https_only = false`), `true` uses HTTPS |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Show the `fleet.yaml` change and run the pre-check only |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Timeouts |

The pre-check reports a cluster `BLOCKED` when it finds a foreign operator or CRDs, an instance name already in use, a Postgres version that does not exist, or a data pool that cannot hold an HA instance (`PGDATA_POOL_NOT_HA_CAPABLE`: `highAvailability=true` needs 3 Ready nodes across zones 1, 2 and 3 in the pool labelled `tpg.fleet/pool=postgres`). A blocked cluster is not changed and the run continues with the others.

**Versions: the cluster decides, not `fleet.yaml`.** `clusters/fleet.yaml` starts empty (`clusters: {}`); `clusters/fleet.example.yaml` shows a filled-in file. For each cluster, tpg-day0 compares the requested operator and Postgres versions with what runs on the target:

| On the target | Result |
|---|---|
| The operator (or the instance) does not run yet | The input is written to `fleet.yaml`, replacing any version declared there. The result carries `FLEET_OVERRIDDEN` with the old value |
| It runs the requested version | Nothing to change on the cluster; a different version declared in `fleet.yaml` is replaced (`FLEET_OVERRIDDEN`) |
| It runs an older version | `BLOCKED` `UPGRADE_REQUIRED`: use tpg-upgrade |
| It runs a newer version | `BLOCKED` `DOWNGRADE_NOT_ALLOWED` |
| The running version cannot be read | `BLOCKED` `VERSION_UNKNOWN`, unless `fleet.yaml` already declares the requested operator version |

A blocked cluster keeps its `fleet.yaml` entry as it was; the other clusters go ahead.

```bash
# 1. Dry run on every registered cluster: validation, fleet.yaml diff, pre-check
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 \
  -p pushMode=direct -p dryRun=true --watch

# 2. Deploy orders-db with HA and 2 read replicas on all clusters, direct push
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true -p readReplicas=2 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# 3. Two single-node instances on one new cluster, sized, reviewed through a pull request
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-04 -p instances=billing-db,reporting-db -p highAvailability=false \
  -p operatorVersion=4.5.0 -p postgresVersion=17.6 \
  -p storageSize=100Gi -p walStorageSize=20Gi -p cpu=2 -p memory=8Gi \
  -p pushMode=pr -p prTimeoutSeconds=7200 --watch

# 4. Lab instance excluded from scheduled backups; cert-manager already installed
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-03 -p instances=scratch-db -p highAvailability=false \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=none -p installAddons=false --watch

# 5. Three batches of 3 clusters after the canary, longer sync timeout
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p maxParallel=3 -p syncTimeoutSeconds=3600 --watch

# 6. Every cluster at once (no canary), backups over HTTPS
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p rolloutMode=all -p backupEnableSSL=true --watch
```

With a parameter file:

```yaml
# day0-orders.yaml
clusters: aks-tpg-poc-01,aks-tpg-poc-02,aks-tpg-poc-03
instances: orders-db
highAvailability: "true"
readReplicas: "1"
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-orders.yaml --watch
```

Different settings per cluster and instance, with `clusterMap`. The inputs are the defaults (here `operatorVersion`, `postgresVersion` and `highAvailability`), and each map key overrides them:

```yaml
# day0-map.yaml
pushMode: direct
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
highAvailability: "true"
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {readReplicas: 2, memory: 8Gi}
      billing-db: {highAvailability: false, backupSchedule: none}
  aks-tpg-poc-02:
    maxReadReplicas: 5
    instances:
      orders-db: {postgresVersion: postgres-16.10, storageSize: 50Gi}
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-map.yaml -p dryRun=true --watch
```

---

## 5. tpg-upgrade

Upgrades the operator (`component=operator`) or Postgres instances (`component=postgres`), canary first, and writes the new version to `clusters/fleet.yaml`. With `clusterMap`, one run can upgrade the operator and instances to versions that differ per cluster and per instance.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `component` | `Enum` | yes, without `clusterMap` | | `operator` or `postgres`. With `clusterMap`: limits the run to that part, and makes `targetVersion` its default version |
| `targetVersion` | `String (version)` | yes, without `clusterMap` | | Operator: `v4.5.1`; Postgres: `postgres-17.6` |
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | yes for `postgres`, without `clusterMap` | | Instances or `all`; not allowed for `operator` |
| `clusterMap` | `Map` | no | | `operatorVersion` per cluster, `postgresVersion`, `preUpgradeBackup` and `allowMajor` per instance (section 3) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `preUpgradeBackup` | `Boolean` | no | `true` | Full backup of each affected instance first |
| `allowMajor` | `Boolean` | no | `false` | Allow major Postgres upgrades; pauses for approval before every batch after the canary |
| `operatorPatches` | `Enum` | no | `keep` | Operator manifest patches (section 6) during an operator upgrade: `keep` or `drop` (below) |
| `maxParallel` | `Integer` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2). With `allowMajor=true`, the approval pause comes before every batch after the first |
| `dryRun` | `Boolean` | no | `false` | Record the planned upgrade (minor or major, current and target) per target |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per cluster (operator) or per instance (Postgres) |

Minor or major is detected per instance. Downgrades fail. Instances not selected are reported as `SKIPPED_NOT_SELECTED`. With `clusterMap`, every listed instance must be declared on its cluster, and on each cluster the operator is upgraded first; the Postgres part does not start on a cluster whose operator upgrade failed.

A Postgres upgrade of one instance runs in this order:

1. Full backup (`preUpgradeBackup=true`).
2. `PostgresVersionUpgrade` created on the target and followed with the instance pods printed every 5 seconds; `Failed` or `PreCheckFailed` ends the instance as `FAILED` with the operator's message.
3. The instance is `Running` with the target `status.dbVersion` (`DB_VERSION_MISMATCH` otherwise).
4. The workflow waits up to 5 minutes for the operator to set `spec.postgresVersion.name` to the target (each poll is logged); if it does not, it logs that and goes on, because Argo CD ignores that field.
5. The version is written to `clusters/fleet.yaml`, pushed, and the Application is synced at that commit.
6. `SUCCEEDED` only when the Application is Synced. Otherwise the instance is `FAILED` with the sync reason (`SYNC_REJECTED`, `SYNC_DRIFT`, ...) and the detail "database upgraded to ..., but the Application did not sync", and the later batches do not run.

The `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion` (`RespectIgnoreDifferences=true`), so the operator's admission webhook (`postgresVersion.name cannot be changed ...`) does not reject the sync.

**Operator manifest patches during an operator upgrade.** The `tpg-operator` Application normally leaves the fields owned by the `tpg-patch` field manager alone (section 6). A new chart version may change those fields, so the upgrade sync runs once without `RespectIgnoreDifferences`:

- `operatorPatches=keep`: the new chart applies cleanly. Every patched field whose new chart value differs is reported as the warning `OPERATOR_PATCH_OVERRIDES` (object, field, chart value, patch value). The patches are then applied again and verified (`OPERATOR_PATCH_NOT_APPLIED` when a field does not match).
- `operatorPatches=drop`: the manifest patch references leave `clusters/fleet.yaml` in the version commit, the patched objects are released, and the chart values stay. Operator values patches are chart inputs and are kept.

```bash
# 1. Operator: dry run on all clusters
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct -p dryRun=true --watch

# 2. Operator: canary cluster only, through a pull request
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-01 -p pushMode=pr --watch

# 3. Operator: remaining clusters two at a time, without pre-upgrade backups
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-02,aks-tpg-poc-03 \
  -p pushMode=direct -p maxParallel=2 -p preUpgradeBackup=false --watch

# 4. Postgres minor upgrade of every instance on every cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-16.10 -p clusters=all -p instances=all \
  -p pushMode=direct --watch

# 5. Postgres major upgrade of orders-db, with approval between batches
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.6 -p clusters=all -p instances=orders-db \
  -p allowMajor=true -p pushMode=pr -p timeoutSeconds=7200 --watch
argo resume @latest          # approve the next batch after checking the canary

# 6. Postgres minor upgrade of two instances on one cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=17.7 -p clusters=aks-tpg-poc-02 \
  -p instances='orders-db,billing-db' -p pushMode=direct --watch

# 7. Operator upgrade that removes the operator manifest patches
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-01 \
  -p operatorPatches=drop -p pushMode=direct --watch
```

Different versions per cluster and instance, with `clusterMap`:

```yaml
# upgrade-map.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    operatorVersion: v4.5.1              # operator first, then the instances below
    instances:
      orders-db: {postgresVersion: postgres-17.7}
  aks-tpg-poc-02:
    instances:
      orders-db: {postgresVersion: postgres-17.6, allowMajor: true}
      billing-db: {postgresVersion: postgres-16.10, preUpgradeBackup: false}
```

```bash
argo submit --from workflowtemplate/tpg-upgrade --parameter-file upgrade-map.yaml --watch
```

---

## 6. tpg-patch

Changes settings of deployed operators and instances that no other workflow owns, with patch files kept in this repository. `clusters/fleet.yaml` stores references to the files, never their content. There are four kinds of patch file, each with its own input and `clusterMap` key:

| Input and map key | Level | Folder | Content | How it is applied |
|---|---|---|---|---|
| `postgresPatchFilePath` | instance | `charts/tpg-instance/patches/` | `kind: Postgres` and a `spec` fragment: any field of the Postgres CRD | The tpg-instance chart reads the files itself (`.Files.Get`) and merges them into the rendered Postgres `spec` |
| `valuesPatchFilePath` | instance | `charts/tpg-instance/patches/` | A fragment of the chart values (`values.yaml` keys), for example `backup.fullRetention` | Merged into the instance's values before the chart renders |
| `operatorValuesPatchFilePath` | cluster | `patches/operator/` | Values of the operator chart | Loaded by the `tpg-operator` Application as `$fleet/<path>` value files (multi-source) |
| `operatorManifestPatchFilePath` | cluster | `patches/operator/` | Partial manifests (apiVersion, kind, metadata.name) of objects the operator chart renders, for fields the chart has no value for | Applied by the workflow with server-side apply as field manager `tpg-patch`; the `tpg-operator` Application ignores the fields that manager owns |

References in `clusters/fleet.yaml`:

```yaml
clusters:
  aks-tpg-poc-01:
    operator:
      version: v4.5.0
      patches:
        values: [patches/operator/example-operator-values.yaml]        # repository paths
        manifests: [patches/operator/example-operator-placement.yaml]
    instances:
      orders-db:
        patches:
          postgres: [patches/example-postgres-resources.yaml]           # relative to charts/tpg-instance/
          values: [patches/example-values-backup.yaml]
```

Each key takes a list of files, applied in order: maps merge key by key, any other value (including `false`, `0` and `""`) replaces the earlier one, a list replaces the whole list, and `null` removes a key. For operator manifest patches, all files of a cluster are merged per object into one server-side apply, where `containers`, `env` and `volumes` merge by name and other lists are replaced. Commit and push a patch file before a run references it.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | with an instance patch file, without `clusterMap` | | Instances or `all`, on every selected cluster |
| `clusterMap` | `Map` | no | | Targets, with the patch file keys and `patchMode` per cluster and per instance (section 3) |
| `postgresPatchFilePath` | `List (paths)` | one patch file input or map key | | Postgres patch files for every selected instance |
| `valuesPatchFilePath` | `List (paths)` | one patch file input or map key | | Values patch files for every selected instance |
| `operatorValuesPatchFilePath` | `List (paths)` | one patch file input or map key | | Operator value files for every selected cluster |
| `operatorManifestPatchFilePath` | `List (paths)` | one patch file input or map key | | Operator manifest patches for every selected cluster |
| `patchMode` | `Enum` | no | `append` | `append`: add the files to the end of each list (a file already listed stays where it is). `replace`: the given files become the list of that kind. `remove`: the given files leave the list |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `maxParallel` | `Integer` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Check the files, show the `fleet.yaml` change and run the server-side dry run only |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per cluster, pull request |

The run, in order:

1. **Validate.** The inputs and `clusterMap`; every instance must be declared on its cluster (`UNKNOWN_INSTANCE` otherwise).
2. **Plan** (one step, before anything changes on a cluster). The files are checked, the references are written to `fleet.yaml`, and each cluster gets a dry run: the instance manifests rendered from the new `fleet.yaml`, the operator chart rendered with the new value files, and the manifest patches, each applied to the target with `--dry-run=server`. A cluster whose files are refused or whose dry run fails is `BLOCKED` `PATCH_REFUSED` (its `fleet.yaml` entry stays as it was, its instances `FAILED` `PATCH_REFUSED`); the others go ahead. One commit for all clusters.
3. **Apply**, canary first like tpg-day0, one cluster at a time per mutex:
   - operator values: the operator Application is synced at the pushed commit, then the CRDs and the operator Deployment are checked;
   - operator manifests: when the cluster had manifest patches before, a sync first; then the server-side apply of the merged patches (objects no longer patched are released); then a sync that returns the released fields to the chart. Every patched field is then compared with the live object (`OPERATOR_PATCH_NOT_APPLIED`, `OPERATOR_PATCH_APPLY_FAILED`);
   - instances: each instance Application is synced at the pushed commit, then the pods are watched until `Running`.

A cluster with nothing to apply ends `SUCCEEDED` `NOTHING_TO_PATCH`. With a `postgresVersion` key in `clusterMap`, an instance that runs another version is `SKIPPED_VERSION_MISMATCH` and left out.

**Refused fields.** A field that another workflow owns, or that cannot change on a running instance, is refused, and the message names the workflow to use:

| Kind | Refused |
|---|---|
| Postgres patch | Anything but `apiVersion`, `kind: Postgres` and `spec`; `spec.postgresVersion` (tpg-upgrade); `spec.highAvailability` (tpg-scale-instance); `spec.storageClassName`; a `storageSize` or `walStorageSize` smaller than the current one |
| Values patch | `instance.name`, `instance.postgresVersion` (tpg-upgrade), `instance.highAvailability` (tpg-scale-instance), `instance.storageClassName`, `cluster`, `patches`; smaller sizes; `backup.additionalParameters`, `backup.enableSSL` and `backup.forcePathStyle`, which the `tpg-instances` ApplicationSet ignores on a running instance (set them when the instance is created) |
| Operator values | `operatorImage`, `postgresImage` (the image follows the chart version: tpg-upgrade) |
| Operator manifest | An object the operator Application does not manage; any image field |

```bash
# 1. Dry run: raise the memory of orders-db on every cluster
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=orders-db \
  -p postgresPatchFilePath=charts/tpg-instance/patches/example-postgres-resources.yaml \
  -p pushMode=direct -p dryRun=true --watch

# 2. Apply it, canary first, then two clusters at a time
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=orders-db \
  -p postgresPatchFilePath=charts/tpg-instance/patches/example-postgres-resources.yaml \
  -p pushMode=direct -p maxParallel=2 --watch

# 3. Two values files for two instances on one cluster, in this order (the second wins);
#    backup-retention-8.yaml stands for a file you added and pushed
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db,billing-db \
  -p valuesPatchFilePath='charts/tpg-instance/patches/example-values-backup.yaml,charts/tpg-instance/patches/backup-retention-8.yaml' \
  -p pushMode=pr --watch

# 4. Operator placement (manifest patch) and operator values on two clusters
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p operatorManifestPatchFilePath=patches/operator/example-operator-placement.yaml \
  -p operatorValuesPatchFilePath=patches/operator/example-operator-values.yaml \
  -p pushMode=direct --watch

# 5. Remove a patch from every instance that lists it
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=all -p patchMode=remove \
  -p postgresPatchFilePath=charts/tpg-instance/patches/example-postgres-resources.yaml \
  -p pushMode=direct --watch
```

Different files per cluster and instance, with `clusterMap`:

```yaml
# patch-map.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    operatorManifestPatchFilePath: [patches/operator/example-operator-placement.yaml]
    instances:
      orders-db:
        postgresPatchFilePath: [charts/tpg-instance/patches/example-postgres-resources.yaml]
        postgresVersion: postgres-17.6          # guard: skipped when it runs another version
  aks-tpg-poc-02:
    instances:
      orders-db:
        valuesPatchFilePath: [charts/tpg-instance/patches/example-values-backup.yaml]
        patchMode: replace
```

```bash
argo submit --from workflowtemplate/tpg-patch --parameter-file patch-map.yaml --watch
```

---

## 7. tpg-scale-instance

Sets the read replica count of the selected instances in `clusters/fleet.yaml` (one commit for the run), syncs each instance and verifies it.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | Instances to scale on every listed cluster (`all` is not accepted). Each instance must be declared on each listed cluster |
| `clusterMap` | `Map` | no | | `replicas` and `enableHAIfNeeded` per instance (section 3) |
| `replicas` | `Integer` | yes (input or map key) | | Read replicas, 0 to `maxReadReplicas` |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `enableHAIfNeeded` | `Boolean` | no | `true` | `replicas > 0` on an instance without HA: turn HA on (`true`) or fail (`false`) |
| `dryRun` | `Boolean` | no | `false` | Record the change only |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `900`, `3600` | Per instance, pull request |

An instance that is not declared on one of the listed clusters fails the run with `UNKNOWN_INSTANCE` before anything changes. `replicas=0` removes the read replicas and keeps high availability as declared.

Each instance Application is synced at the pushed commit and waited on until the Postgres resource is `Running`; after a 30-second settle (logged) the workflow checks the pods and StatefulSets with the pod watch. Instances run in parallel, one at a time per instance.

```bash
# 1. Scale out to 2 read replicas
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p replicas=2 -p pushMode=direct --watch

# 2. Dry run of scaling two instances on two clusters to 3
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instances=orders-db,billing-db \
  -p replicas=3 -p pushMode=direct -p dryRun=true --watch

# 3. Scale in to 0 read replicas through a pull request
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p replicas=0 -p pushMode=pr --watch

# 4. Refuse to turn HA on for a single-node instance
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-04 -p instances=reporting-db -p replicas=1 \
  -p enableHAIfNeeded=false -p pushMode=direct --watch
```

A different count per instance: see the `clusterMap` example in section 3.

---

## 8. tpg-delete-apps

Deletes Tanzu Postgres applications per cluster: Postgres instances (`tpg-instances`) and the operator with its CRDs (`tpg-operator`). Deleting the operator removes these CRDs: `postgres`, `postgresbackups`, `postgresbackuplocations`, `postgresbackupschedules`, `postgresrestores`, `postgresversions` and `postgresversionupgrades` (all `.sql.tanzu.vmware.com`).

The applications per cluster come from `apps` (JSON) or from `clusterMap`: the instances listed under a cluster are deleted, and `deleteOperator: true` deletes the operator after them.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters to clean up |
| `apps` | `Map (JSON)` | yes, without `clusterMap` | | Cluster to list of `tpg-instances`, `tpg-instances:<i>[,<i>]`, `tpg-operator`. Every cluster in `clusters` needs an entry |
| `clusterMap` | `Map` | no | | Instances per cluster, `deleteOperator` and `force` per cluster, `finalBackup`, `purgePvcs` and `purgeNamespace` per instance (section 3) |
| `confirm` | `List` | yes | | Repeat the cluster names (`clusters`, or the clusters of `clusterMap`) |
| `dryRun` | `Boolean` | no | `true` | `true` records the plan; `false` deletes (set `false` explicitly to delete) |
| `purgePvcs` | `Boolean` | yes (input or map key per instance) | | `true` deletes PVCs and Azure disks; `false` keeps them |
| `purgeNamespace` | `Boolean` | yes (input or map key per instance) | | `true` deletes `pg-<instance>` (needs `purgePvcs=true`); `false` keeps it |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `force` | `Boolean` | no | `false` | With the operator: also delete Postgres instances not listed, and do not wait for running backups or restores |
| `finalBackup` | `Enum` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Timeouts |

Order per cluster: instances (final backup, `fleet.yaml` removal, Application removal without cascade, Postgres objects, optional PVC and namespace purge), remaining Tanzu Postgres custom resources, operator (`fleet.yaml`, Application, leftover cluster-scoped objects, namespace `tanzu-postgres-operator`), CRDs. The Azure Blob backup repository is never deleted. With a `postgresVersion` key in `clusterMap`, an instance that runs another version is `SKIPPED_VERSION_MISMATCH` and kept.

```bash
# 1. Plan (dry run) a full clean-up of two clusters
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch

# 2. Run it: remove everything, including volumes and namespaces
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct --watch

# 3. Different applications per cluster: one instance on 01, all instances on 02 (keep volumes)
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p apps='{"aks-tpg-poc-01":["tpg-instances:billing-db"],"aks-tpg-poc-02":["tpg-instances"]}' \
  -p confirm=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p dryRun=false -p purgePvcs=false -p purgeNamespace=false -p pushMode=pr --watch

# 4. Operator only, forcing removal of instances created outside Git, no final backups
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-04 -p apps='{"aks-tpg-poc-04":["tpg-operator"]}' -p confirm=aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct \
  -p force=true -p finalBackup=false --watch
```

With a parameter file (easier for JSON):

```yaml
# delete-lab.yaml
clusters: aks-tpg-poc-03
apps: '{"aks-tpg-poc-03": ["tpg-instances:scratch-db,test-db", "tpg-operator"]}'
confirm: aks-tpg-poc-03
dryRun: "false"
purgePvcs: "true"
purgeNamespace: "true"
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-lab.yaml --watch
```

With `clusterMap`, settings per instance:

```yaml
# delete-map.yaml
confirm: aks-tpg-poc-03,aks-tpg-poc-04
dryRun: "false"
pushMode: direct
purgePvcs: "false"            # default of every instance
purgeNamespace: "false"
clusterMap: |
  aks-tpg-poc-03:
    deleteOperator: true
    force: true
    instances:
      scratch-db: {purgePvcs: true, purgeNamespace: true, finalBackup: false}
      test-db: {}
  aks-tpg-poc-04:
    instances:
      billing-db: {finalBackup: required}
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-map.yaml --watch
```

---

## 9. tpg-delete-instance

Guarded delete of instances (the per-instance step that `tpg-delete-apps` uses). Instances are deleted one at a time.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | Instances to delete on every listed cluster. Each instance must be declared on each listed cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `finalBackup`, `purgePvcs` and `purgeNamespace` per instance (section 3) |
| `confirm` | `List` | yes | | Repeat the `instances` value; with `clusterMap`, repeat its cluster names |
| `finalBackup` | `Enum` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `purgePvcs` | `Boolean` | no | `false` | `true` deletes PVCs and Azure disks |
| `purgeNamespace` | `Boolean` | no | `false` | `true` deletes `pg-<instance>` (needs `purgePvcs=true`) |
| `pushMode` | `Enum` | no | `direct` | `direct` or `pr` |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per instance, pull request |

An instance that is not declared on one of the listed clusters fails the run with `UNKNOWN_INSTANCE` before anything is deleted.

```bash
# 1. Delete billing-db, keep volumes and namespace
argo submit --from workflowtemplate/tpg-delete-instance \
  -p clusters=aks-tpg-poc-01 -p instances=billing-db -p confirm=billing-db --watch

# 2. Require a final backup, purge volumes and namespace, through a pull request
argo submit --from workflowtemplate/tpg-delete-instance \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p confirm=orders-db \
  -p finalBackup=required -p purgePvcs=true -p purgeNamespace=true -p pushMode=pr --watch

# 3. Two lab instances on two clusters
argo submit --from workflowtemplate/tpg-delete-instance \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 -p instances=scratch-db,test-db \
  -p confirm=scratch-db,test-db -p finalBackup=false --watch

# 4. Per instance settings, with clusterMap
argo submit --from workflowtemplate/tpg-delete-instance -p confirm=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"billing-db":{}}},"aks-tpg-poc-02":{"instances":{"scratch-db":{"purgePvcs":true,"purgeNamespace":true}}}}' --watch
```

---

## 10. tpg-helm-addons

Installs or upgrades the Helm releases on target clusters: `cert-manager`, `vault-secrets-operator`, and for the standalone monitoring option `kps` (Prometheus agent) and `tpg-ksm`. The hub releases (`vault`, `vault-secrets-operator`, `kps`) are installed by `tpg-aks-infra/scripts/run.sh --only vault` and `--only addons`.

The steps run `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, and takes a registry
domain without a path for `helm registry login`. The shared Helm helpers
(`workflows/scripts/common.sh`, the same block as `tpg-aks-infra/scripts/lib/common.sh`)
select the release states with `--deployed --failed --pending --superseded --uninstalled
--uninstalling` (`HR_LIST_ALL`), which Helm 3 and Helm 4 both accept, so the same script runs on
a workstation with either version. `tpg-fleet/tests/cli-flags` fails the build
when a removed flag comes back.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes | | Registered clusters or `all` |
| `components` | `List` | no | `auto` | `auto` (cert-manager and vso, plus monitoring when `tpg-settings monitoringOption=standalone`), or a list of `cert-manager`, `vso`, `monitoring` |
| `existingAddons` | `Enum` | no | `skip` | A release that exists with another chart version or other values: `skip` (report `SKIPPED_EXISTS`) or `upgrade` |
| `dryRun` | `Boolean` | no | `false` | `helm upgrade --install --dry-run=server` |

Every component is classified before anything is installed, and the result is reported per release:

| Status | Meaning |
|---|---|
| `INSTALLED`, `UPGRADED` | The release was created or upgraded by this run |
| `UP_TO_DATE` | Our release, same chart version, same values |
| `SKIPPED_EXISTS` | Our release differs; rerun with `existingAddons=upgrade` to apply |
| `SKIPPED_NEWER` | The installed chart is newer than the pinned version; never downgraded |
| `REUSED_EXISTING` | A cert-manager or Vault Secrets Operator installed by someone else is recent enough and is used as it is |
| `BLOCKED` | Another installation that cannot be reused (a foreign `kps` or Vault, an operation in progress, a controller too old). The cluster is not changed |

While `helm --wait` runs, the pod watch prints the pods of the release's namespace every 5 seconds and stops the install when one cannot start (section 2).

With standalone monitoring, the target's `kps` writes to the hub gateway over https with basic auth: the step first creates the `VaultStaticSecret monitoring/tpg-remote-write` (Vault `tpg/shared/monitoring-remote-write`) and copies the Vault CA to `monitoring/tpg-remote-write-ca`. After the install, the run checks for 5 minutes (`MONITORING_FLOW_TIMEOUT`) that the hub Prometheus receives series labelled `cluster=<cluster>`; if none arrive the cluster ends `FAILED` with `MONITORING_NOT_FLOWING`, and the step log names what to check (the gateway Service, the target's Prometheus logs, the credential). With the Azure option it checks that the `ama-metrics` pods run.

```bash
# 1. Everything the cluster needs, on every cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all --watch

# 2. cert-manager only on a new cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=aks-tpg-poc-04 -p components=cert-manager --watch

# 3. Dry run of the monitoring agent upgrade on two clusters
argo submit --from workflowtemplate/tpg-helm-addons \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p components=monitoring -p dryRun=true --watch

# 4. Bring existing releases up to the pinned chart versions and values
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all -p existingAddons=upgrade --watch
```

---

## 11. tpg-backup

Creates one `PostgresBackup` per selected instance and waits for it.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `backupType` | `Enum` | no | `full` | `full` starts a new chain; `incremental` holds the changes since the previous backup (the daily schedule); `differential` holds the changes since the last full backup |
| `clusters` | `List` | no | `all` | Registered clusters or `all` |
| `instances` | `List` | no | every instance | Instances or `all`; each must be declared on at least one selected cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `backupType` and `backupTimeoutSeconds` per instance (section 3) |
| `scheduledOnly` | `Boolean` | no | `false` | `true` (used by the CronWorkflows): skip instances with `backup.scheduled: false` |
| `backupTimeoutSeconds` | `Integer` | no | `10800` | Time to wait per backup |

The schedule is one full backup a week and an incremental one on the other days:

| CronWorkflow | Schedule (UTC) | Type |
|---|---|---|
| `tpg-backup-full` | Sunday 00:00 | full |
| `tpg-backup-incr` | Monday to Saturday 00:00 | incremental |
| `tpg-backup-retention` | daily 02:00 | expiry (section 12) |

An incremental backup depends on the full backup and on every incremental before it, so pgBackRest can only expire a whole chain: the full backup and its incrementals go together. That is what makes the retention workflow expire chains rather than single backups. A differential backup depends only on its full backup, which makes single backups expirable but every differential larger than the incremental of the same day; the POC uses incrementals and keeps `differential` available for a manual run.

```bash
# 1. Full backup of every instance on every cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all --watch

# 2. Incremental backup on one cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=incremental -p clusters=aks-tpg-poc-01 --watch

# 3. Same selection as the CronWorkflows (skips backup.scheduled=false instances)
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all -p scheduledOnly=true --watch

# 4. Two instances, wherever they are declared
argo submit --from workflowtemplate/tpg-backup -p instances=orders-db,billing-db --watch

# 5. Different instances and types per cluster
argo submit --from workflowtemplate/tpg-backup \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"backupType":"full"}}},"aks-tpg-poc-02":{"instances":{"billing-db":{"backupType":"incremental"}}}}' --watch

# Run a CronWorkflow now
argo cron list
argo submit --from cronwf/tpg-backup-full --watch
```

```bash
# What exists, per instance
kubectl --context aks-tpg-poc-01 -n pg-orders-db get postgresbackup \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase,STARTED:.status.timeStarted
```

---

## 12. tpg-backup-retention

Expires backups that are older than the retention window. It groups every instance's backups into chains (one full backup and the incrementals that follow it), and expires a chain only when its newest backup is older than the window, so no chain is ever left without its full backup. The newest chain is always kept, however old it is, and a backup that is still running, already expired or marked `Failed` is left alone.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | no | `all` | Registered clusters or `all` |
| `instances` | `List` | no | every instance | Instances or `all`; each must be declared on at least one selected cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `retentionDays` per instance (section 3) |
| `retentionDays` | `Integer` | no | per instance | Override `backup.retentionDays` (`clusters/_template/cluster.yaml`: 35) for this run |
| `dryRun` | `Boolean` | no | `false` | `true`: report the chains that would be expired; change nothing |

```bash
# 1. What the daily run would expire today
argo submit --from workflowtemplate/tpg-backup-retention -p clusters=all -p dryRun=true --watch

# 2. Apply the fleet.yaml retention on every cluster (what the CronWorkflow does)
argo submit --from workflowtemplate/tpg-backup-retention -p clusters=all --watch

# 3. Free space on one cluster: keep two weeks
argo submit --from workflowtemplate/tpg-backup-retention \
  -p clusters=aks-tpg-poc-03 -p retentionDays=14 --watch

# 4. A different window per instance
argo submit --from workflowtemplate/tpg-backup-retention \
  -p clusterMap='{"aks-tpg-poc-03":{"instances":{"scratch-db":{"retentionDays":7},"orders-db":{"retentionDays":21}}}}' --watch
```

The per-instance result reads, for example, `EXPIRED 5 backups in 2 chain(s)`, `DRY_RUN would expire 2 of 3 chain(s) older than 35 days` or `NOTHING_TO_EXPIRE`. Expiry is a request to the operator (`spec.expire` on the full backup of the chain): the repository is cleaned by pgBackRest, and the `PostgresBackup` objects disappear when the operator has finished.

---

## 13. tpg-restore

Restores one instance to a chosen recovery point. Four things are chosen independently: the source instance, the recovery point (`mode`), where it is restored to, and whether that target already exists.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `sourceCluster` | `String (name)` | yes | | Registered cluster that runs the instance to restore from |
| `instance` | `String (name)` | yes | | Source instance (namespace `pg-<instance>`) |
| `mode` | `Enum` | yes | | `time`, `latest`, `backup`, `lsn` or `xid` |
| `targetTime` | `String (UTC time)` | with `mode=time` | | UTC timestamp, for example `2026-09-15T08:30:00Z` |
| `backupName` | `String (name)` | with `mode=backup` | | A `PostgresBackup` name in the source namespace |
| `lsn` | `String (LSN)` | with `mode=lsn` | | Log sequence number |
| `xid` | `Integer` | with `mode=xid` | | Transaction ID |
| `targetCluster` | `String (name)` | no | `sourceCluster` | Registered cluster to restore into |
| `targetInstance` | `String (name)` | no | `<instance>-restore-<yyyymmddhhmm>` | Instance to restore into; the source instance name means in place |
| `confirm` | `String (name)` | when the target instance exists | | Repeat the target instance name: the restore overwrites its data |
| `pushMode` | `Enum` | no | `direct` | Cross-cluster restore to a new instance: how the `clusters/fleet.yaml` entry is published |
| `bestEffort` | `Boolean` | no | `false` | Recover as far as the WAL allows instead of failing |
| `restoreTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `7200`, `3600` | Timeouts |

| Target | What the workflow does |
|---|---|
| New instance, same cluster | A one-off clone in its own namespace, not managed by Argo CD. Delete it when the validation is done, or add it to `clusters/fleet.yaml` |
| New instance, another cluster | The instance is added to `clusters/fleet.yaml` with the source settings, its Secrets (from Vault) and its own backup location are rendered from the chart, and the Argo CD Application adopts it after the restore |
| The same instance (in place) | Destructive; needs `confirm=<instance>` |
| Another existing instance | Destructive; needs `confirm=<instance>` |

Before it starts, the workflow reads the source instance's backup location, stanza and Postgres version, and refuses a `targetTime` that is in the future or older than the oldest full backup (`OUTSIDE_RECOVERY_WINDOW`). For a restore into another namespace or cluster it creates a read-only copy of the source backup location there, so `backupSync` lists the source backups for the restore; `mode=backup` restores only inside the source namespace, because a `PostgresBackup` name is namespaced: it needs `targetInstance=<instance>` and `confirm=<instance>` (in place), and the validate step refuses it without them.

```bash
# 1. Point in time into a new instance on the same cluster
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=time -p targetTime=2026-09-15T08:30:00Z --watch

# 2. Latest recoverable point, in place (destructive)
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=latest \
  -p targetInstance=orders-db -p confirm=orders-db --watch

# 3. From one named backup, in place (mode=backup restores only inside the source
#    namespace, so the target is the source instance; destructive)
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=backup -p backupName=orders-db-full-20260914000000 \
  -p targetInstance=orders-db -p confirm=orders-db --watch

# 4. Clone to another cluster, managed by Argo CD afterwards
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=latest \
  -p targetCluster=aks-tpg-poc-02 -p targetInstance=orders-db-dr -p pushMode=direct --watch

# 5. Up to a transaction ID, best effort
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=xid -p xid=987654 -p bestEffort=true --watch
```

Afterwards:

```bash
kubectl --context aks-tpg-poc-01 -n pg-orders-db-restore-202609151030 get postgres,postgresrestore
# The copy of the source backup location is kept on purpose. Delete it only when the
# restore is validated: deleting it also removes the PostgresBackup objects that were
# synced from the source repository into that namespace.
kubectl --context aks-tpg-poc-01 -n pg-orders-db-restore-202609151030 \
  get postgresbackuplocation -l tpg.fleet/restore-source
```

---

## 14. tpg-rotate-credential

The credential itself is changed in Vault; the workflow then verifies that the new value reached everything that uses it. Nothing is edited in a Kubernetes Secret by hand.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `secretType` | `Enum` | no | `broadcom-registry` | `broadcom-registry`, `backup-storage`, `git-push` or `git-read` (table below) |
| `clusters` | `List` | no | `all` | Registered clusters to verify, or `all` |
| `maxParallel` | `Integer` | no | `5` | Clusters verified at the same time |

```bash
# 1. Write the new value to Vault. In the UI (scripts/run.sh --only access prints the
#    URL and the tpg-admin password), or in a shell in the Vault pod:
kubectl --context aks-tpg-hub -n vault exec -it vault-0 -- sh
#   vault login -method=userpass username=tpg-admin          (prompts for the password)
#   vault kv put tpg/shared/broadcom-registry username=<user> token=<new token>
#   exit

# 2. Verify the propagation
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=broadcom-registry --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=backup-storage --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=git-push --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=git-read --watch
```

| `secretType` | Vault path | What is checked |
|---|---|---|
| `broadcom-registry` | `tpg/shared/broadcom-registry` | The hub `VaultStaticSecret` and the Argo CD OCI repository connection, then on every cluster: `regsecret` matches Vault, and a test pod pulls an image |
| `backup-storage` | `tpg/shared/backup-storage` | `backup-storage` matches Vault on every cluster, the backup locations are re-read by the operator, and the Blob container answers with HTTP 200 for the new key |
| `git-push` | `tpg/shared/github-push` | The workflow's own Git credential: a clone and a `git push --dry-run` to the fleet branch |
| `git-read` | `tpg/shared/github-read` | The Argo CD repository credential: `repo-tpg-fleet` matches Vault (Vault Secrets Operator) and the Argo CD connection to the fleet repository is Successful |

`tpg/shared/monitoring-remote-write` (standalone monitoring: `username`, `password`) has no `secretType`. After changing it in Vault, run `tpg-aks-infra/scripts/run.sh --only addons`: the hub gateway's htpasswd is rebuilt from Vault and the gateway restarted, and the Vault Secrets Operator updates `monitoring/tpg-remote-write` on every target (within its refresh interval); the step then checks that each target's metrics still reach the hub.

---

## 15. Follow, approve, stop and clean up runs

```bash
argo list                                   # runs with status and duration
argo list --running
argo list -l workflows.argoproj.io/workflow-template=tpg-day0
argo get @latest                            # step tree of the newest run
argo watch @latest
argo logs @latest --follow
argo logs <workflow> -c main | sed -n '/tpg run report/,$p'
kubectl -n argo get configmap tpg-run-<workflow> -o yaml   # raw results per target

argo resume <workflow>                      # approve a suspended step (tpg-upgrade allowMajor=true)
argo suspend <workflow>
argo stop <workflow>                        # run exit handlers (report), then stop
argo terminate <workflow>                   # stop immediately, no exit handler
argo retry <workflow>                       # rerun failed steps
argo resubmit <workflow> --memoized         # new run with the same inputs
argo delete <workflow>                      # also deletes tpg-run-<workflow>
argo delete --older 7d
```

### Archived step logs

Every step's log is archived to Azure Blob when the step ends (container `argo-logs` of the backup storage account). The Argo UI shows the log of a finished step even after its pod has been deleted, for as long as the Workflow exists (7 days). After that, or from a terminal:

```bash
cd tpg-aks-infra
scripts/wf-logs.sh <workflow> --list              # the archived logs of a run
scripts/wf-logs.sh <workflow>                      # print every step log
scripts/wf-logs.sh <workflow> --grep 'RESULT|POD_' # only the matching lines, per step
make wf-logs WF=<workflow>
```

The logs are deleted by the storage lifecycle rule after 90 days (Terraform `argo_logs_retention_days`).

### Reading a failed step

Every step writes its own result: one line `RESULT <key> <status> <reason>
<detail>` in the step log, one key in `tpg-run-<workflow>`, and the output
parameter the report and the Prometheus metric read. A step that fails before it
gets that far records `UNEXPECTED_ERROR` with the script and line number, so a
run never ends with a bare `UNKNOWN`.

```bash
argo logs @latest -c main | grep RESULT
kubectl -n argo get configmap tpg-run-<workflow> -o json | jq '.data | map_values(fromjson)'
```

Reasons written by the sync engine, the pod watch and the checks before a change:

| Reason | Meaning | Look at |
|---|---|---|
| `SYNC_REJECTED` | The API server or an admission webhook refused the manifests (invalid or immutable field). Not retried | The detail holds Argo CD's message; fix the spec in Git |
| `SYNC_FAILED` | The sync operation failed for another reason, after the retries | `argocd app get <app> --show-operation` |
| `SYNC_TIMEOUT` | The sync operation did not finish in time | `argocd app get <app>`, the pod table in the step log |
| `SYNC_BUSY` | Another operation on the Application did not end in time | `argocd app get <app> --show-operation`; ask the platform team if it is stuck (section 16) |
| `SYNC_DRIFT` | Synced, but resources stay OutOfSync (listed in the detail) | `argocd app diff <app>` |
| `HEALTH_TIMEOUT` | Synced, but not Healthy in time | The Postgres resource `status.currentState`, the pod table |
| `POD_<REASON>` | A pod could not start (`POD_CRASHLOOPBACKOFF`, `POD_IMAGEPULLBACKOFF`, `POD_UNSCHEDULABLE`, ...) | The status, events and logs printed below the pod table |
| `MONITORING_NOT_FLOWING` | A target's metrics did not reach the hub within 5 minutes | `kubectl -n monitoring logs deploy/tpg-remote-write` on the hub, the target's Prometheus logs |
| `UNKNOWN_INSTANCE` | A selected instance is not declared on the cluster in `clusters/fleet.yaml`. Nothing was changed | The detail lists the declared instances |
| `SKIPPED_VERSION_MISMATCH` | The `postgresVersion` key of `clusterMap` differs from the running version; the instance was left alone | The detail holds both versions |
| `FLEET_OVERRIDDEN` | tpg-day0: nothing ran on the target, so the input replaced the version declared in `fleet.yaml` | The detail holds the old value |
| `UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN` | tpg-day0: the target runs another version (section 4) | tpg-upgrade, or the running operator and instances |
| `PATCH_REFUSED` | tpg-patch: a file holds a refused field, or the dry run failed on the target | The pre-check detail names the file, the field and the owning workflow |
| `NOTHING_TO_PATCH` | tpg-patch: no patch file applies to the cluster | |
| `OPERATOR_PATCH_APPLY_FAILED`, `OPERATOR_PATCH_NOT_APPLIED` | Operator manifest patches could not be applied, or a live field differs after the apply | The detail lists the objects and fields |

Warnings do not fail a run. They are listed in the Warnings part of the report:

| Warning | Meaning |
|---|---|
| `MANUAL_SYNC_DETECTED` | The last operation on a tpg target Application was started by a named user other than `workflow-bot`, or was an automated sync. Section 16 explains why that is refused. The workflow syncs the Application itself at its commit and carries on |
| `OPERATOR_PATCH_OVERRIDES` | tpg-upgrade: the new operator chart sets a different value for a field that an operator manifest patch overrides; the patch was applied again (section 5) |

One line in the executor log is **not** an error, however it reads:

```text
level=INFO msg="saving parameter" argo=true src=/tmp/result dst=/var/run/argo/outputs/parameters//tmp/result
```

The Argo executor builds that destination as `/var/run/argo` +
`/outputs/parameters/` + the source path, so an absolute source path always
produces two slashes, and POSIX treats `//` inside a path as one separator. The
failure in such a log is the line above it (`sub-process exited ... exit status
1`): read the step's own `RESULT` line for what went wrong.

---

## 16. argocd CLI: inspect the sync steps behind the workflows

The workflows call the Argo CD API as the local account `workflow-bot`. Applications: `tpg-<cluster>-platform`, `tpg-<cluster>-operator`, `tpg-<cluster>-<instance>` (project `tpg`, the target Applications), and `tpg-hub-workflows` and `tpg-hub-monitoring` (project `tpg-hub`).

**Only the workflows sync the target Applications.** A sync started elsewhere would bypass the workflow gates: the pre-check, backups, the rollout order, the pod watch, and the re-application of operator manifest patches. Three layers enforce this:

1. **Argo CD RBAC.** People are denied `sync` (which also covers rollback and terminating an operation), `override`, `update` and `delete` on `tpg/*`. `workflow-bot` (`role:tpg-sync`) may get and sync them. The deny lines are a marked block in `policy.csv` (`tpg-aks-infra argo/argocd-values.yaml`; on an existing hub, `scripts/hub/existing/check-argo.sh --yes` adds a line for every subject that could act on project `tpg`).
2. **Admission policy `tpg-application-sync`** on the hub. It refuses a new operation on a target Application unless argocd-server writes it for `workflow-bot`, and refuses switching on automated sync. It also covers a `kubectl edit` of the Application object, which Argo CD RBAC does not see. The Argo CD UI then shows `only the tpg workflows (Argo CD account workflow-bot) may sync tpg-...`.
3. **Detection.** Each workflow sync first checks who started the last operation on the Application, and reports `MANUAL_SYNC_DETECTED` (section 15) when a named user other than `workflow-bot` started it, or when it was an automated sync.

The hub Applications in project `tpg-hub` stay manageable. There is no break-glass role: fix the cause in Git and rerun the workflow.

```bash
# What exists and its state
argocd app list -l tpg.fleet/cluster=aks-tpg-poc-01
argocd app list -l tpg.fleet/component=operator
argocd app get tpg-aks-tpg-poc-01-orders-db --show-operation
argocd appset get tpg-instances
argocd cluster list

# Who started the last operation (workflow-bot, or workflow-bot:apiKey for its token)
argocd app get tpg-aks-tpg-poc-01-orders-db -o json | jq -r '.status.operationState.operation.initiatedBy'

# Hub workflows (templates, scripts, RBAC, admission policies) after a change in Git: project tpg-hub, allowed
argocd app get tpg-hub-workflows --refresh
argocd app sync tpg-hub-workflows && argocd app wait tpg-hub-workflows --health --timeout 300

# Regenerate Applications right after a fleet.yaml commit (same as the workflows; not a sync)
kubectl -n argocd annotate applicationset tpg-instances argocd.argoproj.io/application-set-refresh=true --overwrite
kubectl -n argocd annotate applicationset tpg-operator argocd.argoproj.io/application-set-refresh=true --overwrite

# Operator upgrade check: the rendered chart version and the fleet value files after the fleet.yaml commit
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq '.spec.sources'
argocd app diff tpg-aks-tpg-poc-01-operator

# Scale or patch check: the Postgres spec Argo CD will apply
argocd app manifests tpg-aks-tpg-poc-02-orders-db --source git | yq 'select(.kind == "Postgres") | .spec'

# Operator manifest patches: the fields the tpg-patch field manager owns on the target
kubectl --context aks-tpg-poc-01 -n tanzu-postgres-operator get deploy -o json --show-managed-fields \
  | jq '.items[] | {name: .metadata.name, tpgPatch: [.metadata.managedFields[] | select(.manager == "tpg-patch") | .fieldsV1]}'

# The operator's CRDs and Deployment, which the workflows check directly before hard-refreshing
kubectl --context aks-tpg-poc-01 get crd postgres.sql.tanzu.vmware.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
kubectl --context aks-tpg-poc-01 -n tanzu-postgres-operator get deploy

# Troubleshooting a failed sync (read-only)
argocd app get tpg-aks-tpg-poc-01-orders-db --hard-refresh
argocd app history tpg-aks-tpg-poc-01-orders-db
argocd repo list

# These are refused for people on tpg/* (RBAC, then the admission policy)
#   argocd app sync tpg-aks-tpg-poc-01-orders-db        -> permission denied
#   argocd app rollback tpg-aks-tpg-poc-01-orders-db 3  -> permission denied
#   argocd app terminate-op tpg-aks-tpg-poc-01-orders-db
#   argocd app set tpg-aks-tpg-poc-01-orders-db --sync-policy automated
```

The delete workflows remove target Applications by removing their `clusters/fleet.yaml` entries (the ApplicationSet deletes the Application without cascade) and delete database objects in order; `argocd app delete` is refused for people.
