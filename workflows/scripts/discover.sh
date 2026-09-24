#!/usr/bin/env bash
# discover.sh WORKFLOW_NAME CLUSTERS [FLEET_JSON]
# Build the run inventory from the registered clusters (Secret argo/kubeconfig-<cluster>,
# wave from its tpg.fleet/wave label) and clusters/fleet.yaml in tpg-fleet.
# CLUSTERS is "all" (registered clusters that have an entry in fleet.yaml) or a
# comma-separated list. FLEET_JSON, when set, replaces fleet.yaml (tpg-day0 dry runs).
# Instance selection (environment), for the workflows that act on chosen instances:
#   P_FILTER       none (default): every declared instance of the selected clusters
#                  off:   the same, also with clusterMap (tpg-day0)
#                  check: the same, but every clusterMap instance must be declared
#                         (tpg-upgrade: the operator upgrade checks every instance)
#                  pairs: only the selected instances, and each one must be declared
#                         on each selected cluster (tpg-scale-instance,
#                         tpg-delete-instance, tpg-patch, and any run with clusterMap)
#                  any:   only the selected instances, each declared on at least one
#                         selected cluster (tpg-backup, tpg-backup-retention)
#   P_CLUSTER_MAP  clusterMap: the instances of each cluster (always checked as pairs)
#   P_INSTANCES    otherwise: comma-separated instances, or all / empty for every one
# A selected instance that is not declared fails the run here, before anything
# changes, with UNKNOWN_INSTANCE and the instances that are declared.
# Outputs:
#   /tmp/inventory.json       [{name, wave, maxReadReplicas, operatorVersion, instances:[...]}]
#   /tmp/instance-items.json  [{cluster, instance, scheduled, retentionDays}]
WF="$1"; SELECTED="$2"; FLEET_JSON="${3:-}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

REPO="$WORK/repo"
git_clone "$REPO"
if [[ -n "$FLEET_JSON" && "$FLEET_JSON" != "{}" ]]; then
  printf '%s' "$FLEET_JSON" | yq -P '.' > "$REPO/$FLEET_REL"
  log "using the fleet.yaml content planned by this run (not pushed)"
fi
registered="$(registered_clusters)"

if [[ "$SELECTED" == "all" ]]; then
  wanted="$(fleet_clusters "$REPO")"
else
  wanted="$(tr ',' '\n' <<<"$SELECTED" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
fi

FILTER="${P_FILTER:-none}"
# off (tpg-day0, tpg-upgrade): every declared instance, even with clusterMap -
# the operator upgrade checks all instances of a cluster, and Day 0 syncs them
CHECK_ONLY=false
if [[ "$FILTER" == "off" ]]; then FILTER=none
elif [[ "$FILTER" == "check" ]]; then FILTER=none; cmap_set && CHECK_ONLY=true
elif cmap_set; then FILTER=pairs
fi
if [[ "$FILTER" != "none" && -z "$(cmap_set && echo map)" ]] && [[ -z "${P_INSTANCES:-}" || "${P_INSTANCES}" == "all" ]]; then
  FILTER=none
fi
unknown=0
declare -A seen_anywhere=()

inv="[]"
for c in $wanted; do
  if ! grep -qx "$c" <<<"$registered"; then
    record "result.${c}" FAILED NOT_REGISTERED "Secret argo/kubeconfig-${c} is missing; registered clusters: $(paste -sd, <<<"$registered")"
    continue
  fi
  if ! fleet_has_cluster "$REPO" "$c"; then
    record "result.${c}" FAILED NOT_IN_FLEET "no clusters.${c} entry in ${FLEET_REL} (run tpg-day0 for this cluster)"
    continue
  fi
  declared="$(fleet_instances "$REPO" "$c")"
  if [[ "$FILTER" == "none" ]]; then
    chosen="$declared"
    if [[ "$CHECK_ONLY" == "true" ]]; then
      for i in $(cmap_instances "$c"); do
        grep -qx "$i" <<<"$declared" && continue
        record "result.${c}.${i}" FAILED UNKNOWN_INSTANCE \
          "no clusters.${c}.instances.${i} in ${FLEET_REL}; declared on ${c}: $(paste -sd, <<<"$declared")"
        unknown=1
      done
    fi
  else
    chosen=""
    for i in $(selected_instances "$REPO" "$c"); do
      if grep -qx "$i" <<<"$declared"; then
        chosen="$(printf '%s\n%s' "$chosen" "$i")"; seen_anywhere[$i]=1
      elif [[ "$FILTER" == "pairs" ]]; then
        record "result.${c}.${i}" FAILED UNKNOWN_INSTANCE \
          "no clusters.${c}.instances.${i} in ${FLEET_REL}; declared on ${c}: $(paste -sd, <<<"$declared")"
        unknown=1
      fi
    done
  fi
  instances="[]"
  for i in $chosen; do
    ha="$(fleet_instance_value "$REPO" "$c" "$i" '.instance.highAvailability.enabled' true)"
    rr="$(fleet_instance_value "$REPO" "$c" "$i" '.instance.highAvailability.readReplicas' 0)"
    [[ "$ha" == "true" ]] || rr=0
    sched=true
    [[ "$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].backup.scheduled == false' "$REPO/$FLEET_REL")" == "true" ]] && sched=false
    # Backup age limit for tpg-backup-retention: instance override, then cluster override,
    # then clusters/_template/cluster.yaml, then 35 days
    rd="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].backup.retentionDays | select(. != null)' "$REPO/$FLEET_REL")"
    [[ -n "$rd" && "$rd" != "null" ]] || rd="$(fleet_cluster_value "$REPO" "$c" '.backup.retentionDays' 35)"
    [[ "$rd" =~ ^[0-9]+$ ]] || rd=35
    obj="$(jq -cn --arg n "$i" --arg v "$(fleet_instance_value "$REPO" "$c" "$i" '.instance.postgresVersion' '')" \
      --argjson ha "$ha" --argjson rr "$rr" --argjson s "$sched" --argjson rd "$rd" \
      '{name:$n, postgresVersion:$v, highAvailability:$ha, readReplicas:$rr, scheduledBackups:$s, retentionDays:$rd}')"
    instances="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$instances")"
  done
  obj="$(jq -cn --arg n "$c" \
    --argjson w "$(registered_wave "$c")" \
    --argjson m "$(fleet_cluster_value "$REPO" "$c" '.cluster.maxReadReplicas' 3)" \
    --arg v "$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")" \
    --argjson inst "$instances" \
    '{name:$n, wave:$w, maxReadReplicas:$m, operatorVersion:$v, instances:$inst}')"
  inv="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$inv")"
done

if [[ "$FILTER" == "any" ]]; then
  for i in $(split_list "${P_INSTANCES:-}"); do
    [[ -n "${seen_anywhere[$i]:-}" ]] && continue
    record "result.${i}" FAILED UNKNOWN_INSTANCE "${i} is not declared on any selected cluster in ${FLEET_REL}"
    unknown=1
  done
fi

printf '%s' "$inv" > /tmp/inventory.json
jq -c '[.[] as $c | $c.instances[] | {cluster: $c.name, instance: .name, scheduled: (.scheduledBackups | tostring),
  retentionDays: (.retentionDays | tostring)}]' <<<"$inv" > /tmp/instance-items.json
kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge \
  -p "$(jq -cn --arg v "$inv" '{data: {inventory: $v}}')" >/dev/null
log "inventory: $(jq -r 'map(.name + "(" + (.instances | length | tostring) + ")") | join(", ")' <<<"$inv")"
if [[ "$unknown" -ne 0 ]]; then
  log "selected instances that are not declared in ${FLEET_REL}: nothing was changed"
  exit 1
fi
