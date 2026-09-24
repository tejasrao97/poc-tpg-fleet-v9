#!/usr/bin/env bash
# report.sh WORKFLOW_NAME WORKFLOW_STATUS MODE
# MODE: cluster (one result per cluster), instance (one result per instance),
# precheck (dry run: only pre-check results, nothing is NOT_RUN), or steps
# (scale, delete and add-on workflows: only the recorded step results).
# Prints the end-of-run report. Targets without a result are NOT_RUN.
# Exits 1 when any target is FAILED or TIMEOUT.
WF="$1"; WF_STATUS="$2"; MODE="${3:-cluster}"
case "$MODE" in
  cluster-or-precheck:true) MODE=precheck ;;
  cluster-or-precheck:*) MODE=cluster ;;
  upgrade:postgres) MODE=instance ;;
  upgrade:operator) MODE=cluster ;;
  upgrade:*) MODE=steps ;;   # clusterMap without component: operator and Postgres results
esac
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

if ! cm_raw="$(kubectl -n "$ARGO_NS" get configmap "$(run_cm)" -o json 2>/dev/null)"; then
  log "ConfigMap $(run_cm) not found — workflow failed before init-run completed; no step results recorded"
  data="{}"
else
  data="$(jq -c '.data // {}' <<<"$cm_raw")"
fi
inv="$(jq -r '.inventory // "[]"' <<<"$data")"

rows="$(jq -c --arg mode "$MODE" --argjson inv "$inv" '
  . as $d
  | ($d | to_entries | map(select(.key | startswith("result."))) | map({key: (.key | ltrimstr("result.")), value: (.value | fromjson)})) as $res
  | (if $mode == "instance" then [$inv[] as $c | $c.instances[] | ($c.name + "." + .name)]
     elif $mode == "precheck" or $mode == "steps" then []
     else [$inv[].name] end) as $expected
  | ($res | map(.key)) as $have
  | $res + [$expected[] | select(. as $e | $have | index($e) | not) | {key: ., value: {status: "NOT_RUN", reason: "", detail: "stopped by an earlier failure or skipped"}}]
  | map({target: .key, status: .value.status, reason: (.value.reason // ""), previous: (.value.previous // ""), detail: (.value.detail // "")})
  | sort_by(.target)
' <<<"$data")"

pre="$(jq -c 'to_entries | map(select(.key | startswith("precheck."))) | map({cluster: (.key | ltrimstr("precheck.")), v: (.value | fromjson)}) | map({cluster, status: .v.status, reason: .v.reason})' <<<"$data")"

echo "=================================================================="
echo " tpg run report: ${WF} (workflow status: ${WF_STATUS})"
echo "=================================================================="
if [[ "$(jq 'length' <<<"$pre")" -gt 0 ]]; then
  echo "Pre-check:"
  jq -r '.[] | "  \(.cluster | .[0:28] | . + (" " * (28 - length)))  \(.status | . + (" " * (10 - length)))  \(.reason)"' <<<"$pre"
  echo
fi
echo "Results:"
jq -r '.[] | "  \(.target | .[0:40] | . + (" " * (40 - length)))  \(.status | . + (" " * (20 - length)))  \(.reason)  \(if .previous != "" then "previous=" + .previous else "" end)  \(.detail)"' <<<"$rows"
echo
warn="$(jq -c 'to_entries | map(select(.key | startswith("warning."))) | map({target: (.key | ltrimstr("warning.")), v: (.value | fromjson)})' <<<"$data")"
if [[ "$(jq 'length' <<<"$warn")" -gt 0 ]]; then
  # Not failures: for example MANUAL_SYNC_DETECTED (a target Application synced
  # outside the workflows) or OPERATOR_PATCH_OVERRIDES after an operator upgrade
  echo "Warnings:"
  jq -r '.[] | "  \(.target | .[0:40] | . + (" " * (40 - length)))  \(.v.reason)  \(.v.detail)"' <<<"$warn"
  echo
fi

jq -c '{succeeded: map(select(.status == "SUCCEEDED")) | length,
        failed: map(select(.status == "FAILED" or .status == "TIMEOUT")) | length,
        skipped: map(select(.status | startswith("SKIPPED"))) | length,
        notRun: map(select(.status == "NOT_RUN")) | length}' <<<"$rows" | tee /tmp/summary.json
kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge \
  -p "$(jq -cn --arg v "$(cat /tmp/summary.json)" '{data: {summary: $v}}')" >/dev/null || true

if [[ "$(jq '.failed' /tmp/summary.json)" -gt 0 ]]; then
  exit 1
fi
