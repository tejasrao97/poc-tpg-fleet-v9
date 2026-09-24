#!/usr/bin/env bash
# workflows/scripts/plan-batches.sh: the rolloutMode of tpg-day0 and tpg-upgrade.
#   canary   (default) the wave-0 cluster alone first, then batches of maxParallel per wave
#   batches  no canary: every cluster, by wave, in batches of maxParallel
#   all      one batch with every cluster
# Runs the script with a stub lib.sh (inventory c0 wave 0, c1 and c2 wave 1, c3 wave 2).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/rollout: jq not installed" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
cat > "$TMP/lib.sh" <<'LIB'
log() { printf '%s\n' "$*" >&2; }
run_data() { printf '%s' "${INVENTORY_JSON}"; }
record_status() { echo PASSED; }
LIB
sed "s#source /scripts/lib.sh#source $TMP/lib.sh#" "$ROOT/workflows/scripts/plan-batches.sh" > "$TMP/plan.sh"

plan() {  # plan INVENTORY_JSON MAX_PARALLEL MODE -> batches JSON (or ERROR)
  (cd "$TMP" && INVENTORY_JSON="$1" bash "$TMP/plan.sh" wf false "$2" ${3:+"$3"} 2>/dev/null) || { echo ERROR; return; }
  jq -c '.' /tmp/batches.json
}
expect() {  # expect NAME GOT WANT
  if [[ "$2" == "$3" ]]; then printf 'ok   %-44s %s\n' "$1" "$2"; PASS=$((PASS + 1))
  else printf 'FAIL %-44s got %s, expected %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}
INV='[{"name":"c0","wave":0},{"name":"c1","wave":1},{"name":"c2","wave":1},{"name":"c3","wave":2}]'
expect "default is canary"               "$(plan "$INV" 2 "")"        '[["c0"],["c1","c2"],["c3"]]'
expect "canary, maxParallel 2"           "$(plan "$INV" 2 canary)"    '[["c0"],["c1","c2"],["c3"]]'
expect "batches, maxParallel 2"          "$(plan "$INV" 2 batches)"   '[["c0","c1"],["c2","c3"]]'
expect "batches, maxParallel 1"          "$(plan "$INV" 1 batches)"   '[["c0"],["c1"],["c2"],["c3"]]'
expect "all: one batch"                  "$(plan "$INV" 1 all)"       '[["c0","c1","c2","c3"]]'
expect "all with no cluster: no batch"   "$(plan '[]' 2 all)"         '[]'
expect "canary without a wave-0 cluster" "$(plan '[{"name":"c1","wave":1},{"name":"c2","wave":1}]' 2 canary)" '[["c1","c2"]]'
expect "an unknown mode fails"           "$(plan "$INV" 2 fast)"      'ERROR'
echo
echo "rollout: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
