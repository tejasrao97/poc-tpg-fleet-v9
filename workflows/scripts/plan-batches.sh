#!/usr/bin/env bash
# plan-batches.sh WORKFLOW_NAME REQUIRE_PRECHECK MAX_PARALLEL [ROLLOUT_MODE]
# ROLLOUT_MODE
#   canary   (default) wave 0 clusters run one at a time first; later waves run
#            in batches of MAX_PARALLEL, wave by wave
#   batches  no canary: every cluster, ordered by wave, in batches of MAX_PARALLEL
#   all      one batch with every selected cluster at once (waves and
#            MAX_PARALLEL ignored; the template's parallelism still caps how
#            many clusters run at the same time)
# With REQUIRE_PRECHECK=true only PASSED or MANAGED clusters are planned.
# Outputs /tmp/batches.json and /tmp/has-batches.
WF="$1"; REQUIRE="$2"; MAXP="$3"; MODE="${4:-canary}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

[[ "$MAXP" =~ ^[1-9][0-9]*$ ]] || { log "maxParallel must be a positive integer"; exit 1; }
case "$MODE" in canary|batches|all) ;; *) log "rolloutMode must be canary, batches or all (got ${MODE})"; exit 1 ;; esac
inv="$(run_data inventory)"
[[ -n "$inv" ]] || inv="[]"

eligible="[]"
for c in $(jq -r '.[].name' <<<"$inv"); do
  if [[ "$REQUIRE" == "true" ]]; then
    s="$(record_status "precheck.${c}")"
    [[ "$s" == "PASSED" || "$s" == "MANAGED" ]] || { log "skipping ${c} (precheck ${s:-missing})"; continue; }
  fi
  eligible="$(jq -c --argjson inv "$inv" --arg c "$c" '. + [$inv[] | select(.name == $c)]' <<<"$eligible")"
done

jq -c --argjson n "$MAXP" --arg mode "$MODE" '
  def chunks($size): [range(0; length; $size) as $i | .[$i:($i + $size)]];
  if $mode == "all" then
    (if length > 0 then [map(.name)] else [] end)
  elif $mode == "batches" then
    (sort_by(.wave) | map(.name) | chunks($n))
  else
    (map(select(.wave == 0)) | map([.name])) as $canary
    | (map(select(.wave != 0)) | sort_by(.wave) | group_by(.wave)
       | map(map(.name) | chunks($n)) | add // []) as $rest
    | $canary + $rest
  end
' <<<"$eligible" > /tmp/batches.json

if [[ "$(jq 'length' /tmp/batches.json)" -gt 0 ]]; then echo true > /tmp/has-batches; else echo false > /tmp/has-batches; fi
log "rolloutMode ${MODE}, batches: $(cat /tmp/batches.json)"
