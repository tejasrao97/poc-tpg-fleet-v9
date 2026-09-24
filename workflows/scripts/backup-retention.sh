#!/usr/bin/env bash
# backup-retention.sh WORKFLOW_NAME CLUSTER INSTANCE RETENTION_DAYS DRY_RUN [OVERRIDE_DAYS]
# Age-based retention for one instance, on top of the operator's count-based
# retentionPolicy (fullRetention).
#
# pgBackRest dependency rules decide what can be removed:
#   - an incremental depends on the previous backup of any type, back to its full
#   - a differential depends on its full only
# so a "chain" is one full backup plus every differential and incremental taken
# after it and before the next full. A chain is removed as a whole, newest
# backup first, by setting spec.expire=true on each PostgresBackup; the operator
# expires the backup in the repository and deletes the PostgresBackup object.
#
# A chain is expired when its newest successful backup is older than
# RETENTION_DAYS (OVERRIDE_DAYS, when set, replaces the fleet.yaml value; a
# clusterMap retentionDays for the instance replaces both).
# The newest chain is always kept, whatever its age.
# Backups taken before the oldest full (no chain) and synced copies from another
# namespace (label sql.tanzu.vmware.com/recovered-from-backuplocation) are left alone.
# Records result.<cluster>.<instance>: EXPIRED | NOTHING_TO_EXPIRE | DRY_RUN |
# SKIPPED_BUSY | SKIPPED_NOT_RUNNING | FAILED. Always exits 0.
WF="$1"; C="$2"; I="$3"; DAYS="$4"; DRY="$5"; OVERRIDE="${6:-}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}.${I}"
result_guard "$key"
NS="pg-${I}"
[[ -z "$OVERRIDE" ]] || DAYS="$OVERRIDE"
DAYS="$(cmap_ival "$C" "$I" retentionDays "$DAYS")"
[[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -ge 1 ]] || { record "$key" FAILED INVALID_RETENTION_DAYS "$DAYS"; exit 0; }
if ! use_cluster "$C"; then record "$key" FAILED NOT_REGISTERED; exit 0; fi
if ! g="$(cmap_guard "$C" "$I")"; then record "$key" SKIPPED_VERSION_MISMATCH "" "$g"; exit 0; fi
if ! tk -n "$NS" get postgres "$I" >/dev/null 2>&1; then
  record "$key" SKIPPED_NOT_RUNNING "" "no Postgres ${NS}/${I}"; exit 0
fi
busy="$(busy_operations "$I")"
if [[ -n "$busy" ]]; then
  record "$key" SKIPPED_BUSY "" "unfinished ${busy}- retried on the next run"; exit 0
fi

cutoff=$(( $(date -u +%s) - DAYS * 86400 ))
# Chains, oldest first: [{full: name, members: [names oldest first], newest: epoch}]
chains="$(tk -n "$NS" get postgresbackup -o json | jq -c --arg i "$I" '
  [.items[]
   | select(.spec.sourceInstance.name == $i)
   | select((.metadata.labels["sql.tanzu.vmware.com/recovered-from-backuplocation"] // "") != "true")
   | select(.status.phase == "Succeeded" and (.spec.expire // false) != true)
   | {name: .metadata.name, type: .spec.type,
      started: ((.status.timeStarted // .metadata.creationTimestamp) | fromdateiso8601),
      done: ((.status.timeCompleted // .status.timeStarted // .metadata.creationTimestamp) | fromdateiso8601)}]
  | sort_by(.started)
  | reduce .[] as $b ([];
      if $b.type == "full" then . + [{full: $b.name, members: [$b.name], newest: $b.done}]
      elif length == 0 then .
      else .[-1].members += [$b.name] | .[-1].newest = ([.[-1].newest, $b.done] | max)
      end)')"

total="$(jq 'length' <<<"$chains")"
expire="$(jq -c --argjson cut "$cutoff" '(length - 1) as $last
  | [to_entries[] | select(.key < $last and .value.newest < $cut) | .value]' <<<"$chains")"
n="$(jq 'length' <<<"$expire")"
if [[ "$n" -eq 0 ]]; then
  record "$key" NOTHING_TO_EXPIRE "" "${total} chain(s), none older than ${DAYS} days (the newest chain is always kept)"
  exit 0
fi
names="$(jq -r '[.[] | .members | reverse | .[]] | join(" ")' <<<"$expire")"
summary="$(jq -r '[.[] | .full + "(" + (.members | length | tostring) + " backups, newest " + (.newest | todate) + ")"] | join(", ")' <<<"$expire")"
if [[ "$DRY" == "true" ]]; then
  record "$key" DRY_RUN "" "would expire ${n} of ${total} chain(s) older than ${DAYS} days: ${summary}"
  exit 0
fi

count=0
for b in $names; do   # newest first inside each chain: every expired backup is a leaf
  if ! tk -n "$NS" patch postgresbackup "$b" --type merge -p '{"spec":{"expire":true}}' >/dev/null; then
    record "$key" FAILED EXPIRE_FAILED "patch ${NS}/${b} failed after ${count} backups"
    exit 0
  fi
  count=$((count + 1))
  log "expire requested for ${NS}/${b}"
done
record "$key" EXPIRED "" "${count} backups in ${n} chain(s) older than ${DAYS} days: ${summary}"
