#!/usr/bin/env bash
# validate-params.sh MODE
# Validates workflow input parameters before anything changes. Parameters come
# from P_* environment variables set by the WorkflowTemplate. Mandatory inputs
# have no default: an empty value fails with the list of valid choices.
# The types of the inputs are enforced earlier, when the Workflow is created
# (ValidatingAdmissionPolicy workflows/admission/workflow-parameters.yaml); this
# step checks what a type cannot: mandatory inputs, combinations, registered
# clusters, and the clusterMap input (P_CLUSTER_MAP) against
# workflows/params/cluster-map-keys.yaml (clustermap.py).
# Outputs:
#   /tmp/clusters.json   normalized cluster list (JSON array) for withParam loops
#   /tmp/selection       the cluster selection for the discover step: the clusterMap
#                        clusters (comma-separated), else the clusters input
#   /tmp/approval        tpg-upgrade: true when a batch approval pause is needed
MODE="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

ERRORS=()
err() { ERRORS+=("$*"); }
REGISTERED="$(registered_clusters)"
REG_LIST="$(paste -sd, <<<"$REGISTERED")"

need() {        # need NAME VALUE HINT
  [[ -n "$2" ]] || err "$1 is mandatory: $3"
}
bool() {        # bool NAME VALUE
  [[ "$2" == "true" || "$2" == "false" ]] || err "$1 must be true or false (got '${2}')"
}
oneof() {       # oneof NAME VALUE CHOICE...
  local n="$1" v="$2" c; shift 2
  for c in "$@"; do [[ "$v" == "$c" ]] && return 0; done
  err "$n must be one of: $* (got '${v}')"
}
posint() {      # posint NAME VALUE
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || err "$1 must be a positive integer (got '${2}')"
}
nonneg() {
  [[ "$2" =~ ^[0-9]+$ ]] || err "$1 must be a non-negative integer (got '${2}')"
}
quantity() {    # quantity NAME VALUE (empty allowed)
  [[ -z "$2" || "$2" =~ ^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|k|M|G|T)?$ ]] || err "$1 must be a Kubernetes quantity such as 20Gi or 500m (got '${2}')"
}
dnsname() {     # dnsname NAME VALUE
  [[ "$2" =~ ^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$ ]] || err "$1 '${2}' must be a lowercase DNS label (letters, digits, '-', at most 40 characters)"
}
clusters_in() {  # clusters_in NAME VALUE ALLOW_ALL -> validates and writes /tmp/clusters.json
  local n="$1" v="$2" allow_all="$3" c out="[]"
  if [[ -z "$v" ]]; then
    err "$n is mandatory: comma-separated cluster names${allow_all:+ or all} (or clusterMap). Registered clusters: ${REG_LIST:-none}"
    return
  fi
  if [[ "$v" == "all" ]]; then
    if [[ -z "$allow_all" ]]; then err "$n does not accept all: list the clusters. Registered clusters: ${REG_LIST:-none}"; return; fi
    printf '%s' "$(jq -cn --arg r "$REGISTERED" '$r | split("\n") | map(select(length > 0))')" > /tmp/clusters.json
    return
  fi
  for c in $(split_list "$v"); do
    grep -qx "$c" <<<"$REGISTERED" || err "$n: cluster '${c}' is not registered. Registered clusters: ${REG_LIST:-none}"
    out="$(jq -c --arg c "$c" 'if index($c) then . else . + [$c] end' <<<"$out")"
  done
  printf '%s' "$out" > /tmp/clusters.json
}
instances_in() { # instances_in NAME VALUE ALLOW_ALL
  local i
  if [[ -z "$2" ]]; then err "$1 is mandatory: comma-separated instance names${3:+ or all} (or clusterMap)"; return; fi
  [[ "$2" == "all" && -n "$3" ]] && return
  for i in $(split_list "$2"); do dnsname "$1" "$i"; done
}
opver() { [[ "$2" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] || err "$1 must be an operator chart version such as v4.5.0 (got '${2}')"; }
pgver() { [[ "$2" =~ ^(postgres-)?[0-9]+(\.[0-9]+)?$ ]] || err "$1 must be a Postgres version such as postgres-17.6 or 17.6 (got '${2}')"; }
paths() {       # paths NAME VALUE PREFIX (empty allowed): comma-separated repository paths under PREFIX
  local p
  for p in $(split_list "$2"); do
    [[ "$p" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*\.ya?ml$ && "/$p/" != */../* ]] || { err "$1: '${p}' must be a relative .yaml or .yml path in the tpg-fleet repository"; continue; }
    [[ "$p" == "$3"* ]] || err "$1: '${p}' must be under $3"
  done
}
same_set() {    # same_set LIST1 LIST2 -> 0 when both comma lists hold the same names
  [[ "$(split_list "$1" | sort -u | paste -sd,)" == "$(split_list "$2" | sort -u | paste -sd,)" ]]
}

# ---- clusterMap
map_exclusive() {  # map_exclusive NAME=VALUE...: inputs that must be empty when clusterMap is set
  local a
  for a in "$@"; do
    [[ -z "${a#*=}" ]] || err "clusterMap and ${a%%=*} cannot be used together: the map selects the clusters and instances (got ${a%%=*}='${a#*=}')"
  done
}
map_validate() {   # map_validate WORKFLOW FLAGS_JSON: clustermap.py validate; writes /tmp/clusters.json
  local out
  if ! cmap_to_json "$P_CLUSTER_MAP" > "$WORK/cmap.raw.json" 2> "$WORK/cmap.err"; then
    err "clusterMap is not valid YAML or JSON: $(tr '\n' ' ' < "$WORK/cmap.err" | cut -c1-300)"
    return
  fi
  yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/cmap-keys.json"
  printf '%s\n' "$REGISTERED" > "$WORK/registered"
  printf '%s' "$2" > "$WORK/flags.json"
  if ! out="$(python3 "$TPG_LIB_DIR/clustermap.py" validate --workflow "$1" --map "$WORK/cmap.raw.json" \
      --keys "$WORK/cmap-keys.json" --registered "$WORK/registered" --flags "$WORK/flags.json" --out "$WORK/cmap.json")"; then
    while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$out"
    return
  fi
  jq -c 'keys' "$WORK/cmap.json" > /tmp/clusters.json
}
map_each_instance() {  # map_each_instance JQ_FILTER MESSAGE: an error for every instance entry where FILTER is false
  # FILTER sees {cluster, instance, v: <instance keys>}
  local bad
  [[ -s "$WORK/cmap.json" ]] || return 0
  bad="$(jq -r --arg m "$2" "to_entries[] | .key as \$c | (.value.instances // {}) | to_entries[]
    | {cluster: \$c, instance: .key, v: .value} | select(($1) | not) | \"clusterMap.\" + .cluster + \".instances.\" + .instance + \": \" + \$m" "$WORK/cmap.json")"
  while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$bad"
}
flags_json() {  # flags_json NAME=VALUE... -> JSON object for clustermap.py --flags
  local a args=()
  for a in "$@"; do args+=(--arg "${a%%=*}" "${a#*=}"); done
  jq -cn "${args[@]}" '$ARGS.named'
}

echo '[]' > /tmp/clusters.json
: > /tmp/selection
echo false > /tmp/approval
case "$MODE" in
  day0)
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate day0 "$(flags_json "operatorVersion=${P_OPERATOR_VERSION:-}" "postgresVersion=${P_POSTGRES_VERSION:-}" \
        "highAvailability=${P_HA:-}" "backupEnableSSL=${P_BACKUP_ENABLE_SSL:-false}")"
      [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
      [[ -z "${P_OPERATOR_VERSION:-}" ]] || opver operatorVersion "$P_OPERATOR_VERSION"
      [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    else
      clusters_in clusters "${P_CLUSTERS:-}" allow
      instances_in instances "${P_INSTANCES:-}"
      need highAvailability "${P_HA:-}" "true or false"; [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
      need operatorVersion "${P_OPERATOR_VERSION:-}" "for example v4.5.0"; [[ -z "${P_OPERATOR_VERSION:-}" ]] || opver operatorVersion "$P_OPERATOR_VERSION"
      need postgresVersion "${P_POSTGRES_VERSION:-}" "for example postgres-17.6"; [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    nonneg readReplicas "${P_READ_REPLICAS:-1}"
    quantity storageSize "${P_STORAGE_SIZE:-}"; quantity walStorageSize "${P_WAL_STORAGE_SIZE:-}"
    quantity cpu "${P_CPU:-}"; quantity memory "${P_MEMORY:-}"
    [[ -z "${P_STORAGE_CLASS:-}" ]] || dnsname storageClass "$P_STORAGE_CLASS"
    oneof backupSchedule "${P_BACKUP_SCHEDULE:-fleet}" fleet none
    oneof monitoringOption "${P_MONITORING_OPTION:-}" "" none azure standalone
    bool installAddons "${P_INSTALL_ADDONS:-true}"; bool dryRun "${P_DRY_RUN:-false}"
    oneof existingAddons "${P_EXISTING:-skip}" skip upgrade
    posint maxParallel "${P_MAX_PARALLEL:-2}"; posint syncTimeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    bool backupEnableSSL "${P_BACKUP_ENABLE_SSL:-false}"
    ;;
  upgrade)
    [[ -z "${P_COMPONENT:-}" ]] || oneof component "$P_COMPONENT" operator postgres
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      # targetVersion is the default of the one component the run is limited to
      opv=""; pgv=""
      case "${P_COMPONENT:-}" in
        operator) opv="${P_TARGET_VERSION:-}"; [[ -z "$opv" ]] || opver targetVersion "$opv" ;;
        postgres) pgv="${P_TARGET_VERSION:-}"; [[ -z "$pgv" ]] || pgver targetVersion "$pgv" ;;
        *) [[ -z "${P_TARGET_VERSION:-}" ]] || err "targetVersion needs component=operator or component=postgres with clusterMap (the map carries operatorVersion and postgresVersion)" ;;
      esac
      map_validate upgrade "$(flags_json "operatorVersion=${opv}" "postgresVersion=${pgv}")"
      if [[ -s "$WORK/cmap.json" ]]; then
        if [[ "${P_COMPONENT:-}" == "operator" && -z "$opv" ]] \
           && ! jq -e 'any(.[]; has("operatorVersion"))' "$WORK/cmap.json" >/dev/null; then
          err "component=operator: no cluster in clusterMap has operatorVersion and targetVersion is empty"
        fi
        if [[ "${P_COMPONENT:-}" == "postgres" && -z "$pgv" ]] \
           && ! jq -e 'any(.[]; any(.instances[]?; has("postgresVersion")))' "$WORK/cmap.json" >/dev/null; then
          err "component=postgres: no instance in clusterMap has postgresVersion and targetVersion is empty"
        fi
        if [[ -z "${P_COMPONENT:-}" ]] \
           && ! jq -e 'any(.[]; has("operatorVersion") or any(.instances[]?; has("postgresVersion")))' "$WORK/cmap.json" >/dev/null; then
          err "clusterMap sets no operatorVersion and no postgresVersion: nothing to upgrade"
        fi
      fi
      if [[ "${P_COMPONENT:-}" != "operator" ]] && { [[ "${P_ALLOW_MAJOR:-false}" == "true" ]] \
           || jq -e 'any(.[]; any(.instances[]?; .allowMajor == "true"))' "$WORK/cmap.json" >/dev/null 2>&1; }; then
        echo true > /tmp/approval
      fi
    else
      need component "${P_COMPONENT:-}" "operator or postgres (or clusterMap)"
      need targetVersion "${P_TARGET_VERSION:-}" "operator: v4.5.0; postgres: postgres-17.6"
      if [[ -n "${P_TARGET_VERSION:-}" ]]; then
        case "${P_COMPONENT:-}" in
          operator) opver targetVersion "$P_TARGET_VERSION" ;;
          postgres) pgver targetVersion "$P_TARGET_VERSION" ;;
        esac
      fi
      clusters_in clusters "${P_CLUSTERS:-}" allow
      if [[ "${P_COMPONENT:-}" == "postgres" ]]; then
        instances_in instances "${P_INSTANCES:-}" allow
        [[ "${P_ALLOW_MAJOR:-false}" != "true" ]] || echo true > /tmp/approval
      elif [[ -n "${P_INSTANCES:-}" ]]; then
        err "instances applies only to component=postgres (the operator is upgraded for the whole cluster)"
      fi
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool preUpgradeBackup "${P_PRE_BACKUP:-true}"; bool allowMajor "${P_ALLOW_MAJOR:-false}"; bool dryRun "${P_DRY_RUN:-false}"
    oneof operatorPatches "${P_OPERATOR_PATCHES:-keep}" keep drop
    posint maxParallel "${P_MAX_PARALLEL:-1}"; posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    [[ "$(cat /tmp/approval)" != "true" || "${P_DRY_RUN:-false}" != "true" ]] || echo false > /tmp/approval
    ;;
  patch)
    pg_paths="${P_POSTGRES_PATCH:-}"; val_paths="${P_VALUES_PATCH:-}"
    opv_paths="${P_OPERATOR_VALUES_PATCH:-}"; opm_paths="${P_OPERATOR_MANIFEST_PATCH:-}"
    paths postgresPatchFilePath "$pg_paths" charts/tpg-instance/patches/
    paths valuesPatchFilePath "$val_paths" charts/tpg-instance/patches/
    paths operatorValuesPatchFilePath "$opv_paths" patches/operator/
    paths operatorManifestPatchFilePath "$opm_paths" patches/operator/
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate patch "$(flags_json "operatorValuesPatchFilePath=${opv_paths}" "operatorManifestPatchFilePath=${opm_paths}")"
      # every instance needs a patch file (its own keys or the inputs), every
      # cluster without instances an operator patch file
      if [[ -n "$pg_paths$val_paths" ]]; then :; else
        map_each_instance '.v | has("postgresPatchFilePath") or has("valuesPatchFilePath")' \
          "no postgresPatchFilePath or valuesPatchFilePath (map key or workflow input)"
      fi
    else
      clusters_in clusters "${P_CLUSTERS:-}" allow
      [[ -z "${P_INSTANCES:-}" ]] || instances_in instances "$P_INSTANCES" allow
      [[ -n "$pg_paths$val_paths$opv_paths$opm_paths" ]] \
        || err "no patch file: set postgresPatchFilePath, valuesPatchFilePath, operatorValuesPatchFilePath or operatorManifestPatchFilePath (or clusterMap)"
      [[ -z "$pg_paths$val_paths" || -n "${P_INSTANCES:-}" ]] \
        || err "postgresPatchFilePath and valuesPatchFilePath need instances (a list, or all)"
      [[ -z "${P_INSTANCES:-}" || -n "$pg_paths$val_paths" ]] \
        || err "instances is set but no instance patch file (postgresPatchFilePath or valuesPatchFilePath)"
    fi
    oneof patchMode "${P_PATCH_MODE:-append}" append replace remove
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    posint maxParallel "${P_MAX_PARALLEL:-1}"; posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    bool dryRun "${P_DRY_RUN:-false}"
    ;;
  scale)
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate scale "$(flags_json "replicas=${P_REPLICAS:-}")"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      instances_in instances "${P_INSTANCES:-}" ""
      need replicas "${P_REPLICAS:-}" "number of read replicas (0 to maxReadReplicas)"
    fi
    [[ -z "${P_REPLICAS:-}" ]] || nonneg replicas "$P_REPLICAS"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool enableHAIfNeeded "${P_ENABLE_HA:-true}"; bool dryRun "${P_DRY_RUN:-false}"
    posint timeoutSeconds "${P_TIMEOUT:-900}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  backup)
    if cmap_set; then
      map_exclusive "instances=${P_INSTANCES:-}"
      [[ -z "${P_CLUSTERS:-}" || "${P_CLUSTERS}" == "all" ]] \
        || err "clusterMap and clusters cannot be used together: the map selects the clusters and instances (got clusters='${P_CLUSTERS}')"
      map_validate backup "{}"
    else
      clusters_in clusters "${P_CLUSTERS:-all}" allow
      [[ -z "${P_INSTANCES:-}" ]] || instances_in instances "$P_INSTANCES" allow
    fi
    oneof backupType "${P_BACKUP_TYPE:-full}" full incremental differential
    posint backupTimeoutSeconds "${P_TIMEOUT:-10800}"
    bool scheduledOnly "${P_SCHEDULED_ONLY:-false}"
    ;;
  restore)
    need sourceCluster "${P_SOURCE_CLUSTER:-}" "one registered cluster. Registered clusters: ${REG_LIST:-none}"
    [[ -z "${P_SOURCE_CLUSTER:-}" ]] || clusters_in sourceCluster "$P_SOURCE_CLUSTER" ""
    need instance "${P_INSTANCE:-}" "the Postgres instance to restore from"; [[ -z "${P_INSTANCE:-}" ]] || dnsname instance "$P_INSTANCE"
    need mode "${P_MODE:-}" "time, latest, backup, lsn or xid"
    [[ -z "${P_MODE:-}" ]] || oneof mode "$P_MODE" time latest backup lsn xid
    case "${P_MODE:-}" in
      time)
        need targetTime "${P_TARGET_TIME:-}" "UTC timestamp such as 2026-09-01T10:30:00Z"
        [[ -z "${P_TARGET_TIME:-}" || "$P_TARGET_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
          || err "targetTime must look like 2026-09-01T10:30:00Z" ;;
      backup) need backupName "${P_BACKUP_NAME:-}" "a PostgresBackup name in the source namespace" ;;
      lsn) need lsn "${P_LSN:-}" "a log sequence number" ;;
      xid) need xid "${P_XID:-}" "a transaction ID"; [[ -z "${P_XID:-}" ]] || nonneg xid "$P_XID" ;;
    esac
    # Exactly one recovery point for the chosen mode
    given=""
    [[ -z "${P_TARGET_TIME:-}" ]] || given="${given}targetTime "
    [[ -z "${P_BACKUP_NAME:-}" ]] || given="${given}backupName "
    [[ -z "${P_LSN:-}" ]] || given="${given}lsn "
    [[ -z "${P_XID:-}" ]] || given="${given}xid "
    case "$(printf '%s' "$given" | wc -w)" in
      0|1) ;;  # 0 is already reported by the per-mode need above (mode=latest takes none)
      *) err "set only the recovery point of the chosen mode (given: ${given})" ;;
    esac
    [[ "${P_MODE:-}" != "latest" || -z "$given" ]] || err "mode=latest takes no recovery point (given: ${given})"
    if [[ -n "${P_TARGET_CLUSTER:-}" ]]; then
      clusters_in targetCluster "$P_TARGET_CLUSTER" ""
      [[ "${P_MODE:-}" != "backup" || "$P_TARGET_CLUSTER" == "${P_SOURCE_CLUSTER:-}" ]] \
        || err "mode=backup restores only inside the source namespace; use time, latest, lsn or xid for another cluster"
    fi
    [[ -z "${P_TARGET_INSTANCE:-}" ]] || dnsname targetInstance "$P_TARGET_INSTANCE"
    if [[ "${P_MODE:-}" == "backup" && -z "${P_TARGET_INSTANCE:-}" && -n "${P_INSTANCE:-}" ]]; then
      err "mode=backup restores only inside the source namespace, and the default target is a new instance in its own namespace: set targetInstance=${P_INSTANCE} and confirm=${P_INSTANCE} (in place), or use time, latest, lsn or xid"
    fi
    if [[ -n "${P_TARGET_INSTANCE:-}" && "${P_TARGET_INSTANCE}" != "${P_INSTANCE:-}" && "${P_MODE:-}" == "backup" ]]; then
      err "mode=backup restores only inside the source namespace (target namespace pg-${P_TARGET_INSTANCE}); use time, latest, lsn or xid"
    fi
    if [[ "${P_TARGET_INSTANCE:-}" == "${P_INSTANCE:-}" && -n "${P_INSTANCE:-}" ]]; then
      [[ "${P_CONFIRM:-}" == "${P_INSTANCE}" ]] || err "an in-place restore overwrites ${P_INSTANCE}: set confirm=${P_INSTANCE}"
    fi
    oneof pushMode "${P_PUSH_MODE:-direct}" direct pr
    bool bestEffort "${P_BEST_EFFORT:-false}"
    posint restoreTimeoutSeconds "${P_TIMEOUT:-7200}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  delete-instance)
    oneof finalBackup "${P_FINAL_BACKUP:-true}" true false required
    bool purgePvcs "${P_PURGE_PVCS:-false}"; bool purgeNamespace "${P_PURGE_NS:-false}"
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate delete-instance "{}"
      need confirm "${P_CONFIRM:-}" "repeat the cluster names of clusterMap"
      if [[ -n "${P_CONFIRM:-}" && -s "$WORK/cmap.json" ]]; then
        same_set "$P_CONFIRM" "$(jq -r 'keys | join(",")' "$WORK/cmap.json")" \
          || err "confirm must repeat the cluster names of clusterMap ($(jq -r 'keys | join(",")' "$WORK/cmap.json"))"
      fi
      map_each_instance "((.v.purgeNamespace // \"${P_PURGE_NS:-false}\") != \"true\") or ((.v.purgePvcs // \"${P_PURGE_PVCS:-false}\") == \"true\")" \
        "purgeNamespace=true needs purgePvcs=true"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      instances_in instances "${P_INSTANCES:-}" ""
      need confirm "${P_CONFIRM:-}" "repeat the instances value"
      if [[ -n "${P_CONFIRM:-}" && -n "${P_INSTANCES:-}" ]]; then
        same_set "$P_CONFIRM" "$P_INSTANCES" || err "confirm must repeat the instances value (${P_INSTANCES})"
      fi
      [[ "${P_PURGE_NS:-false}" != "true" || "${P_PURGE_PVCS:-false}" == "true" ]] || err "purgeNamespace=true needs purgePvcs=true"
    fi
    oneof pushMode "${P_PUSH_MODE:-direct}" direct pr
    posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  delete-apps)
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "apps=${P_APPS:-}"
      map_validate delete-apps "{}"
      need confirm "${P_CONFIRM:-}" "repeat the cluster names of clusterMap"
      if [[ -n "${P_CONFIRM:-}" && -s "$WORK/cmap.json" ]]; then
        same_set "$P_CONFIRM" "$(jq -r 'keys | join(",")' "$WORK/cmap.json")" \
          || err "confirm must repeat the cluster names of clusterMap ($(jq -r 'keys | join(",")' "$WORK/cmap.json"))"
      fi
      # purgePvcs and purgeNamespace have no default: the map key or the input for every instance
      map_each_instance "(.v.purgePvcs // \"${P_PURGE_PVCS:-}\") != \"\"" "purgePvcs is required (map key or workflow input: true deletes PVCs and Azure disks, false keeps them)"
      map_each_instance "(.v.purgeNamespace // \"${P_PURGE_NS:-}\") != \"\"" "purgeNamespace is required (map key or workflow input)"
      map_each_instance "((.v.purgeNamespace // \"${P_PURGE_NS:-}\") != \"true\") or ((.v.purgePvcs // \"${P_PURGE_PVCS:-}\") == \"true\")" \
        "purgeNamespace=true needs purgePvcs=true"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      need apps "${P_APPS:-}" 'JSON map, for example {"aks-tpg-poc-01":["tpg-instances:orders-db","tpg-operator"]} (or clusterMap)'
      if [[ -n "${P_APPS:-}" ]]; then
        if ! jq -e 'type == "object"' <<<"$P_APPS" >/dev/null 2>&1; then
          err "apps must be a JSON object that maps each cluster to a list of applications"
        else
          for c in $(jq -r '.[]' /tmp/clusters.json); do
            jq -e --arg c "$c" 'has($c) and (.[$c] | type == "array" and length > 0)' <<<"$P_APPS" >/dev/null \
              || err "apps has no application list for cluster ${c}"
          done
          for c in $(jq -r 'keys[]' <<<"$P_APPS"); do
            jq -e --arg c "$c" 'index($c)' /tmp/clusters.json >/dev/null || err "apps lists cluster ${c}, which is not in clusters"
          done
          while read -r a; do
            [[ -z "$a" ]] && continue
            case "$a" in
              tpg-operator|tpg-instances|tpg-instances:all) ;;
              tpg-instances:*) for i in $(split_list "${a#tpg-instances:}"); do dnsname "apps instance" "$i"; done ;;
              *) err "apps: unknown application '${a}'; use tpg-instances, tpg-instances:<instance>[,<instance>] or tpg-operator" ;;
            esac
          done < <(jq -r '.[] | .[]? | tostring' <<<"$P_APPS")
        fi
      fi
      need confirm "${P_CONFIRM:-}" "repeat the clusters value"
      if [[ -n "${P_CONFIRM:-}" ]]; then
        same_set "$P_CONFIRM" "${P_CLUSTERS:-}" || err "confirm must repeat the clusters value (${P_CLUSTERS:-})"
      fi
      need purgePvcs "${P_PURGE_PVCS:-}" "true deletes PVCs and Azure disks, false keeps them"
      need purgeNamespace "${P_PURGE_NS:-}" "true deletes the pg-<instance> namespaces, false keeps them"
      [[ "${P_PURGE_NS:-}" != "true" || "${P_PURGE_PVCS:-}" == "true" ]] || err "purgeNamespace=true needs purgePvcs=true"
    fi
    need dryRun "${P_DRY_RUN:-}" "true (plan only) or false"; [[ -z "${P_DRY_RUN:-}" ]] || bool dryRun "$P_DRY_RUN"
    [[ -z "${P_PURGE_PVCS:-}" ]] || bool purgePvcs "$P_PURGE_PVCS"
    [[ -z "${P_PURGE_NS:-}" ]] || bool purgeNamespace "$P_PURGE_NS"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool force "${P_FORCE:-false}"; oneof finalBackup "${P_FINAL_BACKUP:-true}" true false required
    posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  helm-addons)
    clusters_in clusters "${P_CLUSTERS:-}" allow
    for comp in $(split_list "${P_COMPONENTS:-auto}"); do oneof components "$comp" auto cert-manager vso monitoring; done
    [[ "${P_COMPONENTS:-auto}" != *auto* || "${P_COMPONENTS:-auto}" == "auto" ]] || err "components: auto cannot be combined with other components"
    bool dryRun "${P_DRY_RUN:-false}"
    oneof existingAddons "${P_EXISTING:-skip}" skip upgrade
    ;;
  backup-retention)
    if cmap_set; then
      map_exclusive "instances=${P_INSTANCES:-}"
      [[ -z "${P_CLUSTERS:-}" || "${P_CLUSTERS}" == "all" ]] \
        || err "clusterMap and clusters cannot be used together: the map selects the clusters and instances (got clusters='${P_CLUSTERS}')"
      map_validate backup-retention "{}"
    else
      clusters_in clusters "${P_CLUSTERS:-all}" allow
      [[ -z "${P_INSTANCES:-}" ]] || instances_in instances "$P_INSTANCES" allow
    fi
    [[ -z "${P_RETENTION_DAYS:-}" ]] || posint retentionDays "$P_RETENTION_DAYS"
    bool dryRun "${P_DRY_RUN:-false}"
    ;;
  *) err "unknown validation mode ${MODE}" ;;
esac

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  echo "Invalid input parameters:" >&2
  printf '  - %s\n' "${ERRORS[@]}" >&2
  exit 1
fi
[[ "$(jq 'length' /tmp/clusters.json)" -gt 0 || "$MODE" == "restore" ]] \
  || { echo "no registered clusters selected (registered: ${REG_LIST:-none})" >&2; exit 1; }
# The selection the discover step reads: "all" keeps its meaning there (every
# registered cluster with an entry in clusters/fleet.yaml)
if cmap_set; then
  jq -r 'join(",")' /tmp/clusters.json > /tmp/selection
elif [[ "${P_CLUSTERS:-}" == "all" || -z "${P_CLUSTERS:-}" ]]; then
  printf '%s' "${P_CLUSTERS:-all}" > /tmp/selection
else
  jq -r 'join(",")' /tmp/clusters.json > /tmp/selection
fi
log "parameters valid (${MODE}); clusters $(cat /tmp/clusters.json)$(cmap_set && printf ' from clusterMap')"
