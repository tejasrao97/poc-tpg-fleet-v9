#!/usr/bin/env bash
# The Argo CD sync engine of the workflows (app_sync_wait in workflows/scripts/lib.sh)
# against a scripted Argo CD API, with no cluster.
#
#   1. the previous operation's "Succeeded" is not read as the answer: the engine
#      waits for the operation its own request started
#   2. a permanent error (admission webhook denied) fails at once, SYNC_REJECTED,
#      one sync request only - the case of the tpg-upgrade log where Postgres was
#      reported SUCCEEDED although the sync had been rejected
#   3. a transient error (a CRD the Argo CD cache does not know yet) is synced
#      again and then succeeds
#   4. Healthy but still OutOfSync after the sync: SYNC_DRIFT with the resources
#   5. an operation that never ends: SYNC_TIMEOUT
#   6. the previous operation was started by a person (admin in the UI): the
#      engine warns MANUAL_SYNC_DETECTED and still syncs; one started by the
#      workflows (workflow-bot, workflow-bot:apiKey) is not reported
#
# Requires: bash 4, jq.
# ok() and bad() always return 0, so "check && ok || bad" is an if-then-else here;
# single-quoted snippets are expanded by the bash -c that runs them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/sync-engine: jq not installed" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }

# app SYNC HEALTH [PHASE STARTED_AT MESSAGE] -> Application JSON
app() {
  jq -cn --arg s "$1" --arg h "$2" --arg p "${3:-}" --arg t "${4:-}" --arg m "${5:-}" '{
    status: ({sync: {status: $s, revision: "abc123def4567890"}, health: {status: $h},
              resources: [{kind: "Postgres", name: "orders-db", status: $s}]}
             + (if $p != "" then {operationState: {phase: $p, startedAt: $t, message: $m,
                                  syncResult: {revision: "abc123def4567890"}}} else {} end))}'
}
# scenario GET_RESPONSE...: the n-th Application read returns the n-th argument (the last repeats)
scenario() {
  rm -rf "$TMP/s"; mkdir -p "$TMP/s"
  local i=0 r
  for r in "$@"; do i=$((i + 1)); printf '%s' "$r" > "$TMP/s/get.$i"; done
  echo 0 > "$TMP/s/n"; : > "$TMP/s/posts"
}
cat > "$TMP/prelude.sh" <<PRELUDE
source "$ROOT/workflows/scripts/lib.sh"
acd() {  # scripted Argo CD API
  local method="\$1" path="\$2" n f
  if [[ "\$method" == POST ]]; then echo post >> "$TMP/s/posts"; echo '{}'; return 0; fi
  [[ "\$path" != *refresh=hard ]] || { echo '{}'; return 0; }
  n=\$(( \$(cat "$TMP/s/n") + 1 )); echo "\$n" > "$TMP/s/n"
  f="$TMP/s/get.\$n"; [[ -f "\$f" ]] || f="\$(ls "$TMP/s"/get.* | sort -t. -k2 -n | tail -n1)"
  cat "\$f"
}
SYNC_POLL_SECONDS=0 SYNC_RETRY_DELAY=0
PRELUDE
engine() {  # engine TIMEOUT: run app_sync_wait, print rc and reason
  bash -c "source '$TMP/prelude.sh'; rc=0; app_sync_wait tpg-aks-tpg-poc-01-orders-db $1 --revision abc123def4567890 || rc=\$?; echo \"rc=\$rc reason=\$SYNC_FAIL_REASON detail=\$SYNC_FAIL_DETAIL\"" \
    > "$TMP/out" 2> "$TMP/err" || true
}
posts() { wc -l < "$TMP/s/posts" | tr -d ' '; }

OLD="$(app Synced Healthy Succeeded 2026-09-22T17:00:00Z "successfully synced")"
echo "== 1. the previous operation is not the answer"
scenario "$OLD" "$OLD" "$OLD" \
  "$(app OutOfSync Healthy Running 2026-09-22T17:35:44Z "waiting for healthy state")" \
  "$(app Synced Healthy Succeeded 2026-09-22T17:35:44Z "successfully synced")"
engine 60
grep -q '^rc=0 ' "$TMP/out" && ok "succeeds on its own operation" || bad "succeeds on its own operation" "$(cat "$TMP/out" "$TMP/err")"
grep -q 'waiting for the operation to start' "$TMP/err" && ok "the old Succeeded operation was not taken as the result" \
  || bad "the old Succeeded operation was not taken as the result" "$(cat "$TMP/err")"
grep -q 'sync requested for tpg-aks-tpg-poc-01-orders-db at revision abc123def456' "$TMP/err" \
  && ok "the sync is pinned to the pushed revision" || bad "the sync is pinned to the pushed revision" "$(cat "$TMP/err")"

echo
echo "== 2. admission webhook denied"
DENIED='one or more objects failed to apply, reason: admission webhook "vpostgres.kb.io" denied the request: Postgres.sql.tanzu.vmware.com "orders-db" is invalid: spec.postgresVersion.name: Forbidden: postgresVersion.name cannot be changed to use a different major version'
scenario "$OLD" "$OLD" "$(app OutOfSync Healthy Failed 2026-09-22T17:36:00Z "$DENIED")"
engine 60
grep -q '^rc=1 reason=SYNC_REJECTED detail=tpg-aks-tpg-poc-01-orders-db: one or more objects failed to apply' "$TMP/out" \
  && ok "fails with SYNC_REJECTED and Argo CD's message" || bad "fails with SYNC_REJECTED" "$(cat "$TMP/out")"
[[ "$(posts)" -eq 1 ]] && ok "not synced again (1 request)" || bad "not synced again" "posts=$(posts)"

echo
echo "== 3. transient error, then success"
TRANSIENT='one or more synchronization tasks are not valid: the server could not find the requested resource'
scenario "$OLD" "$OLD" \
  "$(app OutOfSync Missing Failed 2026-09-22T17:37:00Z "$TRANSIENT")" \
  "$(app OutOfSync Missing Failed 2026-09-22T17:37:00Z "$TRANSIENT")" \
  "$(app OutOfSync Missing Failed 2026-09-22T17:37:00Z "$TRANSIENT")" \
  "$(app Synced Healthy Succeeded 2026-09-22T17:37:30Z "successfully synced")"
engine 60
grep -q '^rc=0 ' "$TMP/out" && ok "synced again after the transient error and succeeded" || bad "transient error then success" "$(cat "$TMP/out" "$TMP/err")"
[[ "$(posts)" -eq 2 ]] && ok "two sync requests" || bad "two sync requests" "posts=$(posts)"
grep -q 'transient sync error (attempt 1/4)' "$TMP/err" && ok "the retry is logged" || bad "the retry is logged" "$(cat "$TMP/err")"

echo
echo "== 4. Healthy but stays OutOfSync"
scenario "$OLD" "$OLD" "$(app OutOfSync Healthy Succeeded 2026-09-22T17:38:00Z "successfully synced")"
engine 60
grep -q '^rc=1 reason=SYNC_DRIFT detail=.*stays OutOfSync after the sync: Postgres/orders-db' "$TMP/out" \
  && ok "SYNC_DRIFT names the OutOfSync resource" || bad "SYNC_DRIFT" "$(cat "$TMP/out")"

echo
echo "== 5. the operation never ends"
scenario "$OLD" "$OLD" "$(app OutOfSync Progressing Running 2026-09-22T17:39:00Z "waiting for healthy state of sql.tanzu.vmware.com/Postgres/orders-db")"
engine 1
grep -q '^rc=2 reason=SYNC_TIMEOUT' "$TMP/out" && ok "SYNC_TIMEOUT" || bad "SYNC_TIMEOUT" "$(cat "$TMP/out")"

echo
echo "== 6. a sync that was not started by the workflows"
BYADMIN="$(jq -c '.status.operationState.operation.initiatedBy.username = "admin"' <<<"$OLD")"
scenario "$BYADMIN" "$BYADMIN" "$(app Synced Healthy Succeeded 2026-09-22T17:40:00Z "successfully synced")"
engine 60
grep -q 'WARNING MANUAL_SYNC_DETECTED: tpg-aks-tpg-poc-01-orders-db was last synced by admin at 2026-09-22T17:00:00Z' "$TMP/err" \
  && ok "a sync by admin is reported" || bad "a sync by admin is reported" "$(cat "$TMP/err")"
grep -q '^rc=0 ' "$TMP/out" && ok "the workflow syncs anyway" || bad "the workflow syncs anyway" "$(cat "$TMP/out")"
for who in workflow-bot workflow-bot:apiKey; do
  BYBOT="$(jq -c --arg w "$who" '.status.operationState.operation.initiatedBy.username = $w' <<<"$OLD")"
  scenario "$BYBOT" "$BYBOT" "$(app Synced Healthy Succeeded 2026-09-22T17:41:00Z "successfully synced")"
  engine 60
  ! grep -q MANUAL_SYNC_DETECTED "$TMP/err" && ok "a sync by ${who} is not reported" || bad "a sync by ${who} is not reported" "$(cat "$TMP/err")"
done

echo
echo "sync-engine: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
