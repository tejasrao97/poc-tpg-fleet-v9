#!/usr/bin/env bash
# The shared library block (">>> tpg-shared" ... "<<< tpg-shared") that lives in
#   tpg-fleet/workflows/scripts/common.sh
#   tpg-aks-infra/scripts/lib/common.sh
# This file is identical in both repositories (tests/shared-lib/run.sh).
#
#   1. drift: the two copies of the block are identical (skipped when the other
#      repository is not next to this one and FLEET_LOCAL_DIR / INFRA_LOCAL_DIR
#      are not set). tests/shared-lib/sync.sh copies this repository's block over.
#   2. tpg_retry: transient errors are retried, permanent ones are not, stdin is
#      kept for the retries and not taken from a caller's loop, a create that
#      succeeded before the connection dropped counts as created, interactive
#      kubectl subcommands are never retried, arguments are not logged.
#   3. pods_watch: ready pods pass; CreateContainerConfigError fails at once;
#      CrashLoopBackOff is tolerated for POD_WATCH_PERSIST_SECONDS and then
#      fails; an unschedulable pod fails after POD_WATCH_PENDING_SECONDS; an init
#      container failure is named; a done-fn can stop the wait; the failure
#      prints the pod's events and logs.
#
# Requires: bash 4, jq.
# ok() and bad() always return 0, so "check && ok || bad" is an if-then-else here;
# single-quoted snippets are expanded by the bash -c that runs them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/shared-lib: jq not installed" >&2; exit 0; }

if [[ -f "$ROOT/workflows/scripts/common.sh" ]]; then
  SELF="$ROOT/workflows/scripts/common.sh"; SELF_REPO=tpg-fleet
  OTHER_ROOT="${INFRA_LOCAL_DIR:-$(cd "$ROOT/.." && pwd)/tpg-aks-infra}"; OTHER="$OTHER_ROOT/scripts/lib/common.sh"
else
  SELF="$ROOT/scripts/lib/common.sh"; SELF_REPO=tpg-aks-infra
  OTHER_ROOT="${FLEET_LOCAL_DIR:-$(cd "$ROOT/.." && pwd)/tpg-fleet}"; OTHER="$OTHER_ROOT/workflows/scripts/common.sh"
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }
block() { sed -n '/^# >>> tpg-shared >>>$/,/^# <<< tpg-shared <<<$/p' "$1"; }

echo "== 1. drift between the two copies"
block "$SELF" > "$TMP/self.sh"
[[ -s "$TMP/self.sh" ]] || { bad "the block is missing in $SELF"; exit 1; }
if [[ -f "$OTHER" ]]; then
  block "$OTHER" > "$TMP/other.sh"
  if cmp -s "$TMP/self.sh" "$TMP/other.sh"; then ok "identical in ${SELF_REPO} and $(basename "$OTHER_ROOT")"
  else bad "the block differs between ${SELF} and ${OTHER} (run tests/shared-lib/sync.sh)" "$(diff -u "$TMP/other.sh" "$TMP/self.sh" | head -30)"; fi
else
  echo "SKIP drift: ${OTHER} not found (clone both repositories side by side)"
fi

# Every behaviour test sources only the block, in a subshell.
cat > "$TMP/prelude.sh" <<EOF
set -euo pipefail
source "$TMP/self.sh"
TPG_RETRY_DELAY=0
EOF
run() { bash -c "source '$TMP/prelude.sh'; $1" > "$TMP/out" 2> "$TMP/err" && RC=0 || RC=$?; }

# ------------------------------------------------------------------ 2. tpg_retry
echo
echo "== 2. tpg_retry"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/flaky" <<'EOF'
#!/usr/bin/env bash
# flaky FAILS MESSAGE: fail FAILS times with MESSAGE on stderr, then print "ok"
n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE"
if [[ "$n" -le "$1" ]]; then echo "$2" >&2; exit 1; fi
echo ok
EOF
cat > "$TMP/bin/eat" <<'EOF'
#!/usr/bin/env bash
# eat -f -: record stdin, fail once with a transient error
n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE"
cat >> "$SEEN"; echo "|" >> "$SEEN"
if [[ "$n" -eq 1 ]]; then echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2; exit 1; fi
EOF
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# stub kubectl: count calls, always a transient error
n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE"
echo "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout" >&2; exit 1
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" SEEN="$TMP/seen"
calls() { cat "$STATE" 2>/dev/null || echo 0; }

rm -f "$STATE"; run 'tpg_retry flaky 2 "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout"'
if [[ "$RC" -eq 0 && "$(calls)" -eq 3 && "$(cat "$TMP/out")" == ok ]]; then ok "transient error retried until it succeeds (3 calls, output once)"
else bad "transient error retried until it succeeds" "rc=$RC calls=$(calls) out=$(cat "$TMP/out") $(cat "$TMP/err")"; fi
grep -q 'transient error (attempt 1/5), retrying in 0s' "$TMP/err" && ok "each retry is logged with the attempt number" \
  || bad "each retry is logged with the attempt number" "$(cat "$TMP/err")"

rm -f "$STATE"; run 'tpg_retry flaky 1 "Error from server (NotFound): storageclasses.storage.k8s.io \"x\" not found"'
if [[ "$RC" -ne 0 && "$(calls)" -eq 1 ]] && grep -q NotFound "$TMP/err"; then ok "a NotFound is not retried and its message is shown"
else bad "a NotFound is not retried" "rc=$RC calls=$(calls) $(cat "$TMP/err")"; fi

rm -f "$STATE"; run 'TPG_RETRY_ATTEMPTS=3 tpg_retry flaky 9 "Error from server (ServiceUnavailable): the server is currently unable to handle the request"'
if [[ "$RC" -ne 0 && "$(calls)" -eq 3 ]] && grep -q 'still failing after 3 attempts' "$TMP/err"; then ok "gives up after TPG_RETRY_ATTEMPTS and says so"
else bad "gives up after TPG_RETRY_ATTEMPTS" "rc=$RC calls=$(calls) $(cat "$TMP/err")"; fi

rm -f "$STATE"; run 'tpg_retry flaky 1 "Error: UPGRADE FAILED: context deadline exceeded"'
if [[ "$RC" -ne 0 && "$(calls)" -eq 1 ]]; then ok "a helm --wait timeout (context deadline exceeded) is not retried"
else bad "a helm --wait timeout is not retried" "rc=$RC calls=$(calls)"; fi

rm -f "$STATE" "$SEEN"; run 'printf "kind: ConfigMap\n" | tpg_retry eat -f -'
if [[ "$RC" -eq 0 && "$(calls)" -eq 2 && "$(grep -c 'kind: ConfigMap' "$SEEN")" -eq 2 ]]; then ok "stdin (-f -) is given again to the retry"
else bad "stdin (-f -) is given again to the retry" "rc=$RC calls=$(calls) seen=$(cat "$SEEN" 2>/dev/null)"; fi

rm -f "$STATE"; run 'printf "a\nb\n" | while read -r x; do tpg_retry flaky 0 x >/dev/null; echo "$x"; done'
if [[ "$(paste -sd, "$TMP/out")" == "a,b" ]]; then ok "a command that does not read stdin leaves the caller's input alone"
else bad "a command that does not read stdin leaves the caller's input alone" "out=$(paste -sd, "$TMP/out")"; fi

cat > "$TMP/bin/mk" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE"
if [[ "$n" -eq 1 ]]; then echo "Unable to connect to the server: EOF, http2: client connection lost" >&2; exit 1; fi
echo 'Error from server (AlreadyExists): namespaces "pg-orders-db" already exists' >&2; exit 1
EOF
chmod +x "$TMP/bin/mk"
rm -f "$STATE"; run 'tpg_retry mk create namespace pg-orders-db'
if [[ "$RC" -eq 0 && "$(calls)" -eq 2 ]] && grep -q 'treating as created' "$TMP/err"; then ok "a create that reached the server before the drop counts as created"
else bad "a create that reached the server before the drop counts as created" "rc=$RC calls=$(calls) $(cat "$TMP/err")"; fi

rm -f "$STATE"; run 'kubectl --context aks-tpg-hub -n vault exec -i vault-0 -- vault status'
if [[ "$RC" -ne 0 && "$(calls)" -eq 1 ]]; then ok "kubectl exec is passed through, never retried"
else bad "kubectl exec is passed through, never retried" "rc=$RC calls=$(calls)"; fi

rm -f "$STATE"; run 'TPG_RETRY_ATTEMPTS=2 kubectl --context aks-tpg-hub -n argo get secret x'
if [[ "$RC" -ne 0 && "$(calls)" -eq 2 ]]; then ok "kubectl get goes through the retry wrapper"
else bad "kubectl get goes through the retry wrapper" "rc=$RC calls=$(calls)"; fi

rm -f "$STATE"; run 'TPG_RETRY_ATTEMPTS=2 kubectl --context aks-tpg-hub -n argo create secret generic x --from-literal=password=S3cr3tValue'
if grep -q 'kubectl create: transient error' "$TMP/err" && ! grep -q 'S3cr3tValue' "$TMP/err"; then ok "the retry log names the subcommand, never the arguments"
else bad "the retry log names the subcommand, never the arguments" "$(cat "$TMP/err")"; fi

# ------------------------------------------------------------------ 3. pods_watch
echo
echo "== 3. pods_watch"
pod() {  # pod NAME PHASE READY(true|false) [WAITING_REASON] [INIT_REASON] [LAST_REASON] [UNSCHEDULABLE]
  jq -n --arg n "$1" --arg ph "$2" --argjson r "$3" --arg w "${4:-}" --arg i "${5:-}" --arg l "${6:-}" --arg u "${7:-}" '{
    metadata: {name: $n},
    spec: {containers: [{name: "pg-container"}, {name: "instance-logging"}]},
    status: {phase: $ph,
      conditions: ([{type: "Ready", status: (if $r then "True" else "False" end)}]
                   + (if $u != "" then [{type: "PodScheduled", status: "False", reason: "Unschedulable", message: $u}] else [] end)),
      initContainerStatuses: (if $i != "" then [{name: "init", ready: false, restartCount: 3,
                              state: {waiting: {reason: $i, message: "back-off restarting failed container"}}}] else [] end),
      containerStatuses: [
        {name: "pg-container", ready: $r, restartCount: (if $w != "" or $l != "" then 4 else 0 end),
         state: (if $w != "" then {waiting: {reason: $w, message: ("reason " + $w)}} else {running: {}} end),
         lastState: (if $l != "" then {terminated: {reason: $l, exitCode: 137}} else {} end)},
        {name: "instance-logging", ready: $r, restartCount: 0, state: {running: {}}}]}}'
}
fixture() { jq -s '{items: .}' > "$TMP/pods.json"; }
cat > "$TMP/prelude-pods.sh" <<EOF
fk() {  # stub kubectl for pods_watch
  case "\$*" in
    *"get pods"*) cat "$TMP/pods.json" ;;
    *"get pod "*"-o wide"*) echo "NAME READY STATUS" ;;
    *"get pod "*"-o json"*) jq '.items[0]' "$TMP/pods.json" ;;
    *"get events"*) echo "Warning  BackOff  kubelet  Back-off restarting failed container" ;;
    *logs*) echo "FATAL:  could not open configuration file" ;;
  esac
}
POD_WATCH_INTERVAL=0
EOF
pw() { run "source '$TMP/prelude-pods.sh'; $1; rc=0; pods_watch pg-orders-db ${2:-5} --kubectl fk ${3:-} || rc=\$?; echo \"rc=\$rc reason=\$POD_WATCH_REASON\""; }

{ pod orders-db-0 Running true; pod orders-db-1 Running true; } | fixture
pw ':' 5
grep -q 'rc=0 ' "$TMP/out" && ok "every pod Ready: success" || bad "every pod Ready: success" "$(cat "$TMP/out" "$TMP/err")"
grep -q 'NAME .*PHASE .*READY .*RESTARTS .*STATUS' "$TMP/err" && grep -q 'checking pod status in pg-orders-db' "$TMP/err" \
  && ok "prints the check and the pod table" || bad "prints the check and the pod table" "$(cat "$TMP/err")"

{ pod orders-db-0 Pending false CreateContainerConfigError; } | fixture
pw ':' 30
grep -q 'rc=1 reason=POD_CREATECONTAINERCONFIGERROR' "$TMP/out" && ok "CreateContainerConfigError fails at once" \
  || bad "CreateContainerConfigError fails at once" "$(cat "$TMP/out")"
grep -q -- '---- events of orders-db-0' "$TMP/err" && grep -q 'could not open configuration file' "$TMP/err" \
  && ok "the failure prints the pod's events and container logs" || bad "the failure prints the pod's events and logs" "$(tail -20 "$TMP/err")"

{ pod orders-db-0 Running false CrashLoopBackOff; } | fixture
pw 'POD_WATCH_PERSIST_SECONDS=60' 2
grep -q 'rc=2 reason=POD_TIMEOUT' "$TMP/out" && ok "CrashLoopBackOff is tolerated for POD_WATCH_PERSIST_SECONDS" \
  || bad "CrashLoopBackOff is tolerated for POD_WATCH_PERSIST_SECONDS" "$(cat "$TMP/out")"
pw 'POD_WATCH_PERSIST_SECONDS=0' 30
grep -q 'rc=1 reason=POD_CRASHLOOPBACKOFF' "$TMP/out" && ok "then it fails with POD_CRASHLOOPBACKOFF" \
  || bad "then it fails with POD_CRASHLOOPBACKOFF" "$(cat "$TMP/out")"
grep -q -- 'previous run' "$TMP/err" && ok "a restarted container's previous logs are printed" \
  || bad "a restarted container's previous logs are printed" "$(tail -20 "$TMP/err")"

{ pod orders-db-0 Running false "" "" OOMKilled; } | fixture
pw 'POD_WATCH_PERSIST_SECONDS=0' 30
grep -q 'rc=1 reason=POD_OOMKILLED' "$TMP/out" && ok "a container killed for memory is named OOMKilled" \
  || bad "a container killed for memory is named OOMKilled" "$(cat "$TMP/out")"

{ pod orders-db-0 Pending false "" CrashLoopBackOff; } | fixture
pw 'POD_WATCH_PERSIST_SECONDS=0' 30
grep -q 'rc=1 reason=POD_CRASHLOOPBACKOFF' "$TMP/out" && grep -q 'Init:CrashLoopBackOff' "$TMP/err" \
  && ok "an init container failure is shown as Init:<reason>" || bad "an init container failure" "$(cat "$TMP/out") $(grep -m2 Init "$TMP/err")"

{ pod orders-db-0 Pending false "" "" "" "0/3 nodes are available: 3 node(s) had volume node affinity conflict"; } | fixture
pw 'POD_WATCH_PENDING_SECONDS=0' 30
grep -q 'rc=1 reason=POD_UNSCHEDULABLE' "$TMP/out" && grep -q 'volume node affinity conflict' "$TMP/err" \
  && ok "an unschedulable pod fails with the scheduler's message" || bad "an unschedulable pod" "$(cat "$TMP/out") $(grep -m1 affinity "$TMP/err")"

{ pod orders-db-0 Running true; } | fixture
pw 'done_never() { printf "PostgresVersionUpgrade x: phase Failed"; return 3; }' 30 '--done-fn done_never'
grep -q 'rc=4 reason=CONDITION_FAILED' "$TMP/out" && ok "a done-fn returning 3 stops the wait" \
  || bad "a done-fn returning 3 stops the wait" "$(cat "$TMP/out")"
pw 'done_later() { printf "currentState=Created"; return 1; }' 1 '--done-fn done_later'
grep -q 'rc=2 ' "$TMP/out" && grep -q 'currentState=Created' "$TMP/err" \
  && ok "pods ready but the done-fn not yet: keeps waiting and shows its state" || bad "done-fn state" "$(cat "$TMP/out")"

echo
echo "shared-lib: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
