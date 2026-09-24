#!/usr/bin/env bash
# Functions shared by the workflow step scripts (sourced through lib.sh) and by
# helm-addons.sh, which also runs on the workstation from tpg-aks-infra. Nothing
# here needs the run ConfigMap, Vault or the Argo CD token: those are in lib.sh.
# Source it; do not run it.
# >>> tpg-shared >>>
# Shared between tpg-aks-infra/scripts/lib/common.sh and
# tpg-fleet/workflows/scripts/common.sh. Everything between the ">>> tpg-shared"
# and "<<< tpg-shared" markers must be identical in both files:
# tests/shared-lib/run.sh fails when they differ. Edit one copy, then run
# tests/shared-lib/sync.sh to copy it to the other repository.
#
#   1. tpg_retry and the kubectl, helm, az and argocd wrappers
#   2. pods_watch: pod status every 5 seconds, fail fast on a pod that cannot start
#   3. hr_*: Helm release pre-check and install (classify, decide, values diff,
#      upgrade/skip/abort prompt, install with pod watch)
#   4. monitoring_flowing: target metrics arrive on the hub Prometheus
#
# Callers may define before sourcing: nothing. Callers may set afterwards:
# TPG_RETRY_ATTEMPTS, TPG_RETRY_DELAY, HR_* (see hr_setup).

_tpg_note() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ============================================================ 1. retries
# The AKS API server of a busy cluster sometimes answers with a timeout or drops
# the connection. tpg_retry repeats a command that failed with such a transient
# error, and only then: a NotFound, a Forbidden, a validation error or a
# "helm --wait" timeout fails at once, because repeating it cannot help.
#
#   TPG_RETRY_ATTEMPTS  attempts in total (default 5)
#   TPG_RETRY_DELAY     seconds before the first retry, doubled each time (default 5:
#                       5, 10, 20, 40 s)
#
# Standard input is kept for the retries when the command reads it (-f -,
# --values -, --password-stdin, /dev/stdin): it is held in a shell variable,
# never in a file. stderr is shown after the command ends.
: "${TPG_RETRY_ATTEMPTS:=5}"
: "${TPG_RETRY_DELAY:=5}"
TPG_RETRY_PATTERN='i/o timeout|TLS handshake timeout|connection refused|connection reset by peer|broken pipe|unexpected EOF|http2: client connection lost|Client\.Timeout exceeded|net/http: request canceled|Unable to connect to the server|the server is currently unable to handle the request|etcdserver: request timed out|etcdserver: leader changed|Kubernetes cluster unreachable|the server was unable to return a response|ServiceUnavailable|Too ?Many ?Requests|429 Too Many|502 Bad Gateway|503 Service Unavailable|504 Gateway Time-?out|returned error: 50[234]|no route to host|Temporary failure in name resolution|Could not resolve host|Failed to connect to|Connection timed out|Operation timed out|Empty reply from server|Recv failure|SSL_ERROR_SYSCALL|error dialing backend|GOAWAY|ConnectionResetError|Connection aborted|Read timed out|ReadTimeout|RemoteDisconnected|GatewayTimeout|rpc error: code = Unavailable'

# _tpg_reads_stdin ARGS... -> 0 when the command reads standard input
_tpg_reads_stdin() {
  local prev="" a
  for a in "$@"; do
    case "$a" in
      -f=-|--filename=-|--values=-|--password-stdin|*=/dev/stdin|/dev/stdin) return 0 ;;
      -) case "$prev" in -f|--filename|--values|--from-file|--from-env-file) return 0 ;; esac ;;
    esac
    prev="$a"
  done
  return 1
}

# _tpg_verb TOOL ARGS... -> the subcommand, skipping global flags and their values.
# Used to decide what may be retried and to name a command in the retry log
# without printing its arguments (they can hold secrets).
_tpg_verb() {
  shift
  local skip=0 a
  for a in "$@"; do
    if [[ "$skip" -eq 1 ]]; then skip=0; continue; fi
    case "$a" in
      --context|--kubeconfig|-n|--namespace|--request-timeout|--kube-context|--cluster|--user|--as|--as-group|-s|--server|--token|--subscription|-o|--output|--repo-server|--server-crt|--grpc-web-root-path) skip=1 ;;
      -*) ;;
      *) printf '%s' "$a"; return 0 ;;
    esac
  done
}

tpg_retry() {
  # tpg_retry COMMAND [ARGS...]
  local attempt=1 max="$TPG_RETRY_ATTEMPTS" delay="$TPG_RETRY_DELAY" rc err input="" has_input=0 name verb
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=1
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=5
  if [[ "$1" == "command" ]]; then name="$2"; verb="$(_tpg_verb "${@:2}")"; else name="$1"; verb="$(_tpg_verb "$@")"; fi
  if _tpg_reads_stdin "$@"; then
    has_input=1
    input="$(cat; printf .)"
    input="${input%.}"
  fi
  while true; do
    rc=0
    if [[ "$has_input" -eq 1 ]]; then
      { err="$( { printf '%s' "$input" | "$@" 2>&1 1>&9 9>&-; } )" || rc=$?; } 9>&1
    else
      { err="$( { "$@" 2>&1 1>&9 9>&-; } )" || rc=$?; } 9>&1
    fi
    if [[ "$rc" -eq 0 ]]; then
      [[ -z "$err" ]] || printf '%s\n' "$err" >&2
      return 0
    fi
    # A create whose first attempt reached the API server before the connection
    # dropped finds the object on the retry: that is the result we wanted.
    if [[ "$attempt" -gt 1 && "$verb" == "create" ]] && grep -Eq 'AlreadyExists|already exists' <<<"$err"; then
      _tpg_note "${name} create: the object exists after a retry; treating as created"
      return 0
    fi
    if [[ "$attempt" -ge "$max" ]] || ! grep -Eqi -- "$TPG_RETRY_PATTERN" <<<"$err"; then
      [[ -z "$err" ]] || printf '%s\n' "$err" >&2
      [[ "$attempt" -eq 1 ]] || _tpg_note "${name} ${verb}: still failing after ${attempt} attempts"
      return "$rc"
    fi
    _tpg_note "${name} ${verb}: transient error (attempt ${attempt}/${max}), retrying in ${delay}s: $(grep -Ei -m1 -- "$TPG_RETRY_PATTERN" <<<"$err" | cut -c1-200)"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# Wrappers: every call of these tools in the scripts goes through tpg_retry.
# Interactive or streaming subcommands (exec, port-forward, logs -f, attach, cp,
# proxy, edit, debug, run) are passed through unchanged: a retry could repeat an
# action that already happened (for example "vault operator init" inside exec).
kubectl() {
  case "$(_tpg_verb kubectl "$@")" in
    exec|port-forward|attach|cp|proxy|edit|debug|run) command kubectl "$@"; return ;;
    logs) case " $* " in *" -f "*|*" --follow "*|*" --follow=true "*) command kubectl "$@"; return ;; esac ;;
  esac
  tpg_retry command kubectl "$@"
}
helm() { tpg_retry command helm "$@"; }
az() {
  case "$(_tpg_verb az "$@")" in login|logout|interactive) command az "$@"; return ;; esac
  tpg_retry command az "$@"
}
argocd() {
  case "$(_tpg_verb argocd "$@")" in login|relogin) command argocd "$@"; return ;; esac
  tpg_retry command argocd "$@"
}

# ============================================================ 2. pod watch
# pods_watch NAMESPACE TIMEOUT_SECONDS [options]
#   --selector SEL      label selector (default: every pod in the namespace)
#   --kubectl FN        function or command used as kubectl (default kubectl;
#                       the workflows pass tk for a target cluster)
#   --label TEXT        what is being waited for, printed in the log
#   --done-fn FN        extra condition: FN must return 0 as well (it may print a
#                       one-line state, shown above the table); FN returns 3 to
#                       stop the wait because the condition can no longer be met
#   --while-pid PID     keep watching until PID has exited (helm --wait)
#   --min-pods N        pods that must exist before the wait can succeed (default 1)
#   --allow-empty       no pod at all is acceptable (with --while-pid or --done-fn)
#
# Prints the pod table every 5 seconds. Returns
#   0  every pod is Ready (or Completed) and the extra conditions hold
#   1  a pod cannot start
#   2  timeout
#   3  the --while-pid process ended before every pod was ready
#   4  the --done-fn reported that its condition failed (POD_WATCH_REASON
#      CONDITION_FAILED, POD_WATCH_DETAIL its state line)
# On 1 and 2 it prints the pod status, the pod's recent events and the last log
# lines of its containers (with --previous for a restarted one), and sets
# POD_WATCH_REASON (POD_<REASON>) and POD_WATCH_DETAIL.
#
# Fail rules
#   at once           CreateContainerConfigError, CreateContainerError,
#                     InvalidImageName, RunContainerError, ErrImageNeverPull
#   after 60 seconds  CrashLoopBackOff, ImagePullBackOff, ErrImagePull, Error,
#                     OOMKilled, StartError, ContainerCannotRun
#   after 5 minutes   Pending and unschedulable (FailedScheduling, unbound PVC)
: "${POD_WATCH_INTERVAL:=5}"
: "${POD_WATCH_PERSIST_SECONDS:=60}"
: "${POD_WATCH_PENDING_SECONDS:=300}"
POD_WATCH_REASON=""
POD_WATCH_DETAIL=""

_pw_rows() {
  # JSON pod list on stdin -> TSV: name phase ready restarts status container message
  jq -r '
    .items[]? | . as $p
    | ($p.status.initContainerStatuses // []) as $ics
    | ($p.status.containerStatuses // []) as $cs
    | ([$cs[] | select(.ready)] | length) as $r
    | ($p.spec.containers | length) as $n
    | ([$cs[].restartCount, $ics[].restartCount] | add // 0) as $rs
    | ([ ($ics[] | select((.state.waiting.reason // "") != "" and .state.waiting.reason != "PodInitializing")
                 | {c: .name, r: ("Init:" + .state.waiting.reason), m: (.state.waiting.message // "")}),
         ($ics[] | select(.state.terminated != null and (.state.terminated.exitCode // 0) != 0)
                 | {c: .name, r: ("Init:" + (.state.terminated.reason // "Error")), m: (.state.terminated.message // "")}),
         ($cs[] | select((.state.waiting.reason // "") != "" and .state.waiting.reason != "ContainerCreating")
                | {c: .name, r: .state.waiting.reason, m: (.state.waiting.message // "")}),
         ($cs[] | select(.state.terminated != null and (.state.terminated.exitCode // 0) != 0)
                | {c: .name, r: (.state.terminated.reason // "Error"), m: (.state.terminated.message // "")}),
         ($cs[] | select((.ready | not) and ((.lastState.terminated.reason // "") == "OOMKilled"))
                | {c: .name, r: "OOMKilled", m: "last termination: OOMKilled"})
       ] | first) as $bad
    | ([$p.status.conditions[]? | select(.type == "PodScheduled" and .status == "False")] | first) as $sched
    | ([$p.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0) as $ready
    | [ $p.metadata.name, ($p.status.phase // "Unknown"), "\($r)/\($n)", ($rs | tostring),
        (if $p.metadata.deletionTimestamp then "Terminating"
         elif $bad then $bad.r
         elif $sched then "Unschedulable"
         elif $p.status.phase == "Succeeded" then "Completed"
         elif $ready then "Ready"
         elif ([$cs[] | select(.state.waiting.reason == "ContainerCreating")] | length > 0) then "ContainerCreating"
         else ($p.status.phase // "Unknown") end),
        ($bad.c // ""),
        (($bad.m // $sched.message // "") | gsub("[\t\n\r]+"; " ") | .[0:300]) ]
    | @tsv'
}

_pw_class() {
  # _pw_class STATUS -> now | persist | pending | ok | wait
  case "${1#Init:}" in
    CreateContainerConfigError|CreateContainerError|InvalidImageName|RunContainerError|ErrImageNeverPull) echo now ;;
    CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|OOMKilled|StartError|ContainerCannotRun) echo persist ;;
    Unschedulable) echo pending ;;
    Ready|Completed) echo ok ;;
    *) echo wait ;;
  esac
}

_pw_diagnose() {
  # _pw_diagnose KFN NS POD: status, events and logs of one pod, on stderr
  local kfn="$1" ns="$2" pod="$3" c j
  {
    printf '\n---- pod %s/%s\n' "$ns" "$pod"
    "$kfn" -n "$ns" get pod "$pod" -o wide 2>&1 || true
    printf -- '---- events of %s (newest last)\n' "$pod"
    "$kfn" -n "$ns" get events --field-selector "involvedObject.name=${pod}" \
      --sort-by=.lastTimestamp 2>&1 | tail -n 20 || true
    j="$("$kfn" -n "$ns" get pod "$pod" -o json 2>/dev/null || echo '{}')"
    while IFS=$'\t' read -r c restarts; do
      [[ -n "$c" ]] || continue
      printf -- '---- logs of %s, container %s (last 50 lines)\n' "$pod" "$c"
      "$kfn" -n "$ns" logs "$pod" -c "$c" --tail=50 2>&1 || true
      if [[ "${restarts:-0}" -gt 0 ]]; then
        printf -- '---- logs of %s, container %s, previous run (last 50 lines)\n' "$pod" "$c"
        "$kfn" -n "$ns" logs "$pod" -c "$c" --previous --tail=50 2>&1 || true
      fi
    done < <(jq -r '((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
                    | [.name, (.restartCount | tostring)] | @tsv' <<<"$j")
    printf -- '---- end of %s\n\n' "$pod"
  } >&2
}

pods_watch() {
  local ns="$1" timeout="$2" sel="" kfn="kubectl" label="" done_fn="" wpid="" min=1 allow_empty=0
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --selector) sel="$2"; shift 2 ;;
      --kubectl) kfn="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --done-fn) done_fn="$2"; shift 2 ;;
      --while-pid) wpid="$2"; shift 2 ;;
      --min-pods) min="$2"; shift 2 ;;
      --allow-empty) allow_empty=1; shift ;;
      *) _tpg_note "pods_watch: unknown option $1"; return 2 ;;
    esac
  done
  local -A seen=()
  local start now elapsed json rows name phase ready restarts status cont msg cls key age
  local total bad_pod="" bad_status="" bad_msg="" bad_cont="" all_ok done_state done_ok done_rc running
  local -a selargs=()
  [[ -z "$sel" ]] || selargs=(-l "$sel")
  POD_WATCH_REASON=""; POD_WATCH_DETAIL=""
  start="$(date +%s)"
  _tpg_note "checking pod status in ${ns}${sel:+ (${sel})}${label:+ for ${label}} every ${POD_WATCH_INTERVAL}s (timeout ${timeout}s)"
  while true; do
    now="$(date +%s)"; elapsed=$((now - start))
    json="$("$kfn" -n "$ns" get pods "${selargs[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
    rows="$(_pw_rows <<<"$json" 2>/dev/null || true)"
    done_state=""; done_ok=1
    if [[ -n "$done_fn" ]]; then
      done_rc=0; done_state="$("$done_fn" 2>/dev/null)" || done_rc=$?
      if [[ "$done_rc" -eq 0 ]]; then done_ok=1; else done_ok=0; fi
      if [[ "$done_rc" -eq 3 ]]; then
        POD_WATCH_REASON="CONDITION_FAILED"; POD_WATCH_DETAIL="$done_state"
        _tpg_note "FAILED: ${done_state}"
        return 4
      fi
    fi
    running=0
    if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then running=1; fi
    total=0; all_ok=1; bad_pod=""
    {
      printf '[%s] %s%s, %ss elapsed%s\n' "$(date -u +%H:%M:%S)" "$ns" "${sel:+ (${sel})}" "$elapsed" \
        "${done_state:+ | ${done_state}}"
      if [[ -z "$rows" ]]; then
        printf '  (no pods yet)\n'
      else
        printf '  %-44s %-10s %-6s %-9s %s\n' NAME PHASE READY RESTARTS STATUS
      fi
    } >&2
    while IFS=$'\t' read -r name phase ready restarts status cont msg; do
      [[ -n "$name" ]] || continue
      total=$((total + 1))
      cls="$(_pw_class "$status")"
      key="${name}|${status}"
      [[ -n "${seen[$key]:-}" ]] || seen[$key]="$now"
      age=$((now - ${seen[$key]}))
      case "$cls" in
        ok) ;;
        wait) all_ok=0 ;;
        now) all_ok=0; [[ -n "$bad_pod" ]] || { bad_pod="$name"; bad_status="$status"; bad_msg="$msg"; bad_cont="$cont"; } ;;
        persist)
          all_ok=0
          if [[ "$age" -ge "$POD_WATCH_PERSIST_SECONDS" && -z "$bad_pod" ]]; then
            bad_pod="$name"; bad_status="$status"; bad_msg="$msg"; bad_cont="$cont"
          fi ;;
        pending)
          all_ok=0
          if [[ "$age" -ge "$POD_WATCH_PENDING_SECONDS" && -z "$bad_pod" ]]; then
            bad_pod="$name"; bad_status="$status"; bad_msg="$msg"; bad_cont="$cont"
          fi ;;
      esac
      printf '  %-44s %-10s %-6s %-9s %s%s\n' "$name" "$phase" "$ready" "$restarts" "$status" \
        "$( [[ "$cls" == persist || "$cls" == pending ]] && printf ' (%ss)' "$age")" >&2
    done <<<"$rows"
    if [[ -n "$bad_pod" ]]; then
      POD_WATCH_REASON="POD_$(printf '%s' "${bad_status#Init:}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_')"
      POD_WATCH_DETAIL="${ns}/${bad_pod}${bad_cont:+ container ${bad_cont}}: ${bad_status}${bad_msg:+: ${bad_msg}}"
      _tpg_note "FAILED: ${POD_WATCH_DETAIL}"
      _pw_diagnose "$kfn" "$ns" "$bad_pod"
      return 1
    fi
    if [[ "$running" -eq 0 && "$done_ok" -eq 1 && "$all_ok" -eq 1 ]]; then
      if [[ "$total" -ge "$min" ]] || { [[ "$allow_empty" -eq 1 ]] && [[ "$total" -eq 0 ]]; }; then
        _tpg_note "${ns}: ${total} pod(s) ready${label:+ (${label})}"
        return 0
      fi
    fi
    # The watched process (helm --wait) ended while pods are still starting: the
    # caller reads its exit status and decides.
    if [[ -n "$wpid" && "$running" -eq 0 ]]; then
      return 3
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      POD_WATCH_REASON="POD_TIMEOUT"
      POD_WATCH_DETAIL="${ns}${sel:+ (${sel})}: not ready after ${timeout}s${done_state:+ (${done_state})}"
      _tpg_note "TIMEOUT: ${POD_WATCH_DETAIL}"
      while IFS=$'\t' read -r name phase ready restarts status cont msg; do
        [[ -n "$name" && "$(_pw_class "$status")" != ok ]] && _pw_diagnose "$kfn" "$ns" "$name"
      done <<<"$rows"
      return 2
    fi
    sleep "$POD_WATCH_INTERVAL"
  done
}

# ============================================================ 3. Helm releases
# Pre-check of a Helm release before anything changes, and the install itself.
#   NOT_INSTALLED   nothing found                         -> install
#   OURS            our release in the expected namespace -> compare chart version and values:
#                     same version and values             -> UP_TO_DATE
#                     installed chart newer than target   -> SKIPPED_NEWER (never downgrade)
#                     otherwise show the change and act on HR_EXISTING:
#                     ask (prompt upgrade/skip/abort), upgrade, skip or abort
#   OTHER_RELEASE   the same chart as another Helm release (other name or namespace)
#   NOT_HELM        the component exists without a Helm release (hr_foreign_hook)
#                   -> reused when hr_reuse_hook accepts it (REUSED_EXISTING), else BLOCKED
# Every result is printed on stdout as: ADDON <release> <STATUS> <detail>
#
# hr_setup --cluster NAME [--kubeconfig FILE] [--context CTX] [--existing MODE]
#          [--dry-run 0|1] [--log-name NAME]
# Optional hooks the caller may define:
#   hr_foreign_hook RELEASE        print NOT_HELM when the component runs outside Helm
#   hr_reuse_hook RELEASE CLASS    print a detail and return 0 when that copy can be reused
HR_CLUSTER="" HR_EXISTING="" HR_DRY_RUN=0 HR_LOG_NAME="helm" HR_TMP="" ACTION=""
HR_KUBE_ARGS=() HR_HELM_ARGS=()
# Every release state, whatever the Helm major version: Helm 3 needs -a for
# superseded and uninstalled releases, Helm 4 removed -a and lists every state by
# default. These per-state flags exist in both and select the same set.
HR_LIST_ALL=(--deployed --failed --pending --superseded --uninstalled --uninstalling)

hr_setup() {
  HR_KUBE_ARGS=(); HR_HELM_ARGS=(); HR_EXISTING="${ADDONS_EXISTING:-}"; HR_DRY_RUN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster) HR_CLUSTER="$2"; shift 2 ;;
      --kubeconfig) HR_KUBE_ARGS+=(--kubeconfig "$2"); HR_HELM_ARGS+=(--kubeconfig "$2"); shift 2 ;;
      --context) HR_KUBE_ARGS+=(--context "$2"); HR_HELM_ARGS+=(--kube-context "$2"); shift 2 ;;
      --existing) HR_EXISTING="$2"; shift 2 ;;
      --dry-run) HR_DRY_RUN="$2"; shift 2 ;;
      --log-name) HR_LOG_NAME="$2"; shift 2 ;;
      *) hr_die "hr_setup: unknown option $1" ;;
    esac
  done
  if [[ -z "$HR_EXISTING" ]]; then
    if [[ -r /dev/tty ]] && [[ -t 2 ]]; then HR_EXISTING=ask; else HR_EXISTING=skip; fi
  fi
  case "$HR_EXISTING" in ask|upgrade|skip|abort) ;; *) hr_die "existing-release mode must be ask, upgrade, skip or abort (got ${HR_EXISTING})" ;; esac
  if [[ -z "$HR_TMP" || ! -d "$HR_TMP" ]]; then
    HR_TMP="$(mktemp -d)"
    chmod 700 "$HR_TMP"
  fi
}

hr_say() { printf '[%s %s] %s\n' "$HR_LOG_NAME" "$HR_CLUSTER" "$*" >&2; }
hr_die() { hr_say "ERROR: $*"; exit 1; }
hr_result() { printf 'ADDON %s %s %s\n' "$1" "$2" "${3:-}"; hr_say "$1: $2${3:+ ($3)}"; }
hr_blocked() { hr_result "$1" BLOCKED "$2"; exit 1; }
hr_k() { kubectl "${HR_KUBE_ARGS[@]}" "$@"; }
hr_h() { helm "${HR_HELM_ARGS[@]}" "$@"; }
hr_hlist() { hr_h list "${HR_LIST_ALL[@]}" -o json "$@"; }

# hr_merge_values OUT FILE...: deep-merge values files (later wins, lists replaced,
# like Helm). One merged file keeps "helm get values" comparable with this run.
hr_merge_values() {
  local out="$1"; shift
  if [[ $# -eq 0 ]]; then echo '{}' > "$out"; return; fi
  # shellcheck disable=SC2016  # yq variables
  yq eval-all '. as $item ireduce ({}; . * $item)' "$@" > "$out"
}

hr_overlay() {
  # hr_overlay NAME YQ_EXPRESSION: write a values overlay built with yq -n
  local f="$HR_TMP/overlay-$1.yaml"
  yq -n "$2" > "$f"
  printf '%s' "$f"
}

hr_norm_ver() { local v="${1#v}"; printf '%s' "${v%%[-+]*}"; }
hr_ver_ge() {  # hr_ver_ge A B -> 0 when A >= B
  [[ "$(printf '%s\n%s\n' "$(hr_norm_ver "$2")" "$(hr_norm_ver "$1")" | sort -V | head -n1)" == "$(hr_norm_ver "$2")" ]]
}
hr_ver_gt() { ! hr_ver_ge "$2" "$1"; }

# hr_classify RELEASE NS CHART -> NOT_INSTALLED | OURS | OTHER_RELEASE:<ns>/<name> | NOT_HELM
hr_classify() {
  local rel="$1" ns="$2" chart="$3" other foreign=""
  if hr_h status "$rel" -n "$ns" >/dev/null 2>&1; then echo OURS; return; fi
  other="$(hr_hlist -A 2>/dev/null | jq -r --arg c "$chart" --arg r "$rel" --arg n "$ns" '
    [.[] | select((.chart | test("^" + $c + "-v?[0-9]")) and ((.name != $r) or (.namespace != $n)))
     | .namespace + "/" + .name] | first // empty')"
  if [[ -n "$other" ]]; then echo "OTHER_RELEASE:${other}"; return; fi
  if declare -F hr_foreign_hook >/dev/null; then foreign="$(hr_foreign_hook "$rel" "$ns")"; fi
  if [[ -n "$foreign" ]]; then echo "$foreign"; return; fi
  echo NOT_INSTALLED
}

hr_class_text() {
  case "$1" in
    OTHER_RELEASE:*) printf 'already installed by Helm release %s' "${1#OTHER_RELEASE:}" ;;
    NOT_HELM) printf 'already installed outside Helm' ;;
    *) printf '%s' "$1" ;;
  esac
}

# hr_values_diff RELEASE NS MERGED -> unified diff on stdout (empty when equal)
hr_values_diff() {
  local rel="$1" ns="$2" merged="$3"
  hr_h get values "$rel" -n "$ns" -o yaml 2>/dev/null | yq -P 'sort_keys(..)' > "$HR_TMP/installed.yaml" || true
  [[ -s "$HR_TMP/installed.yaml" ]] && [[ "$(cat "$HR_TMP/installed.yaml")" != "null" ]] || echo '{}' > "$HR_TMP/installed.yaml"
  yq -P 'sort_keys(..)' "$merged" > "$HR_TMP/target.yaml"
  diff -u --label "installed values" --label "values of this run" "$HR_TMP/installed.yaml" "$HR_TMP/target.yaml" || true
}

hr_ask_existing() {  # hr_ask_existing RELEASE -> upgrade | skip | abort on stdout
  local answer
  while true; do
    printf '\n%s on %s: upgrade, skip or abort? [u/s/a] ' "$1" "$HR_CLUSTER" > /dev/tty
    read -r answer < /dev/tty || answer=a
    case "$answer" in
      u|U|upgrade) echo upgrade; return ;;
      s|S|skip) echo skip; return ;;
      a|A|abort) echo abort; return ;;
    esac
  done
}

# hr_decide RELEASE NS CHART VERSION MERGED [NOTE] -> sets ACTION: install | upgrade | none
# (none: nothing to do, or a foreign installation is reused). Prints the ADDON result for none.
hr_decide() {
  local rel="$1" ns="$2" chart="$3" version="$4" merged="$5" note="${6:-}" class st cur cur_app d choice detail row
  class="$(hr_classify "$rel" "$ns" "$chart")"
  case "$class" in
    NOT_INSTALLED)
      ACTION=install ;;
    OURS)
      st="$(hr_h status "$rel" -n "$ns" -o json)"
      case "$(jq -r '.info.status' <<<"$st")" in
        pending-*) hr_blocked "$rel" "release ${ns}/${rel} has an operation in progress ($(jq -r '.info.status' <<<"$st"))" ;;
      esac
      # One list call; app_version is app_version in Helm 3 and 4, appVersion in
      # some wrappers, so both spellings are read.
      row="$(hr_hlist -n "$ns" | jq -c --arg r "$rel" '[.[] | select(.name == $r)][0] // {}')"
      cur="$(jq -r '.chart // ""' <<<"$row" | sed -E "s/^${chart}-//")"
      cur_app="$(jq -r '.app_version // .appVersion // ""' <<<"$row")"
      if hr_ver_gt "$cur" "$version"; then
        ACTION=none; hr_result "$rel" SKIPPED_NEWER "installed chart ${cur} is newer than ${version}; no downgrade"; return
      fi
      d="$(hr_values_diff "$rel" "$ns" "$merged")"
      if [[ "$(hr_norm_ver "$cur")" == "$(hr_norm_ver "$version")" && -z "$d" && "$(jq -r '.info.status' <<<"$st")" == "deployed" ]]; then
        ACTION=none; hr_result "$rel" UP_TO_DATE "chart ${cur}, values unchanged"; return
      fi
      {
        printf '\n=== %s: Helm release %s/%s is already installed ===\n' "$HR_CLUSTER" "$ns" "$rel"
        printf '  status:        %s\n' "$(jq -r '.info.status' <<<"$st")"
        printf '  chart:         %s %s -> %s\n' "$chart" "$cur" "$version"
        printf '  app version:   %s (installed)\n' "$cur_app"
        [[ -z "$note" ]] || printf '  note:          %s\n' "$note"
        if [[ -n "$d" ]]; then printf '  values diff:\n    %s\n' "${d//$'\n'/$'\n'    }"; else printf '  values:        unchanged\n'; fi
      } >&2
      choice="$HR_EXISTING"
      [[ "$choice" != "ask" ]] || choice="$(hr_ask_existing "$rel")"
      case "$choice" in
        upgrade) ACTION=upgrade ;;
        skip) ACTION=none; hr_result "$rel" SKIPPED_EXISTS "chart ${cur} kept (target ${version}); rerun with --existing upgrade to apply" ;;
        abort) hr_blocked "$rel" "ABORTED: the release exists and the operator chose abort (--existing ${HR_EXISTING})" ;;
      esac ;;
    OTHER_RELEASE:*|NOT_HELM)
      if declare -F hr_reuse_hook >/dev/null && detail="$(hr_reuse_hook "$rel" "$class")"; then
        ACTION=none; hr_result "$rel" REUSED_EXISTING "$detail"
      else
        [[ -n "${detail:-}" ]] || detail="$(hr_class_text "$class"), and the fleet needs its own ${rel} configuration: that installation cannot be reused"
        hr_blocked "$rel" "$detail"
      fi ;;
  esac
}

# hr_release NAME CHART VERSION REPO NAMESPACE MERGED [NOTE] [extra helm args...]
#   Pre-check, then helm upgrade --install. Helm runs with --wait in the
#   background while pods_watch prints the pods of NAMESPACE every 5 seconds and
#   stops the install as soon as a pod cannot start. HR_NO_WAIT=1: no --wait and
#   no pod watch (vault-0 becomes Ready only after init and unseal).
#   HR_WAIT_SECONDS: timeout (default 900).
hr_release() {
  local name="$1" chart="$2" version="$3" repo="$4" ns="$5" merged="$6" note="${7:-}"
  local secs="${HR_WAIT_SECONDS:-900}" pid rc=0 wrc=0 out rev
  shift 7
  hr_decide "$name" "$ns" "$chart" "$version" "$merged" "$note"
  [[ "$ACTION" != "none" ]] || return 0
  local -a chart_src=("$chart" --version "$version")
  [[ -z "$repo" ]] || chart_src+=(--repo "$repo")
  if [[ "$HR_DRY_RUN" -eq 1 ]]; then
    hr_h upgrade --install "$name" "${chart_src[@]}" -n "$ns" --create-namespace \
      -f "$merged" --dry-run=server "$@" >/dev/null
    hr_result "$name" DRY_RUN "would ${ACTION} ${chart} ${version} in ${ns}"
    return 0
  fi
  hr_say "helm upgrade --install ${name} (${chart} ${version}) in ${ns}"
  out="$HR_TMP/helm-${name}.out"
  if [[ "${HR_NO_WAIT:-0}" == "1" ]]; then
    hr_h upgrade --install "$name" "${chart_src[@]}" -n "$ns" --create-namespace -f "$merged" "$@" >"$out" 2>&1 \
      || { cat "$out" >&2; hr_result "$name" FAILED "helm upgrade --install failed"; exit 1; }
  else
    hr_h upgrade --install "$name" "${chart_src[@]}" -n "$ns" --create-namespace -f "$merged" \
      --wait --timeout "${secs}s" "$@" >"$out" 2>&1 &
    pid=$!
    pods_watch "$ns" "$((secs + 60))" --kubectl hr_k --label "Helm release ${name}" --while-pid "$pid" --allow-empty || wrc=$?
    # wrc 0: pods ready and helm finished; 3: helm finished first; 2: timeout
    if [[ "$wrc" -eq 1 ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      hr_result "$name" FAILED "${POD_WATCH_REASON}: ${POD_WATCH_DETAIL}"
      exit 1
    fi
    wait "$pid" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      cat "$out" >&2
      hr_result "$name" FAILED "helm upgrade --install exited ${rc}${POD_WATCH_REASON:+ (${POD_WATCH_REASON})}"
      exit 1
    fi
  fi
  rev="$(hr_h status "$name" -n "$ns" -o json | jq -r '(.version | tostring) + " " + .info.status')"
  if [[ "$ACTION" == "install" ]]; then hr_result "$name" INSTALLED "${chart} ${version}, revision ${rev}"
  else hr_result "$name" UPGRADED "${chart} ${version}, revision ${rev}"; fi
}
# ============================================================ 4. monitoring (standalone option)
# monitoring_flowing HUB_KUBECTL CLUSTER [TIMEOUT_SECONDS] [TARGET_KUBECTL]
#   Wait until the hub Prometheus has samples from CLUSTER (up{cluster="<c>"}),
#   checking every 15 seconds (default timeout 300 s). The query goes through the
#   Kubernetes API service proxy of the hub (Service monitoring/prometheus-operated),
#   so no Prometheus port has to be reachable. HUB_KUBECTL and TARGET_KUBECTL are
#   functions or commands used as kubectl for the hub and for the target. On
#   timeout the target Prometheus remote-write errors are printed when
#   TARGET_KUBECTL is given. Returns 0 when samples arrive, 1 otherwise.
monitoring_flowing() {
  local hk="$1" c="$2" timeout="${3:-300}" tk_fn="${4:-}" start q path out n="0" elapsed
  q="count(up{cluster=\"${c}\"})"
  path="/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$q" '$q | @uri')"
  start="$(date +%s)"
  _tpg_note "checking that metrics from ${c} reach the hub Prometheus every 15s (timeout ${timeout}s)"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    out="$("$hk" get --raw "$path" 2>/dev/null || true)"
    [[ -n "$out" ]] || out='{}'
    n="$(jq -r '.data.result[0].value[1] // "0"' <<<"$out" 2>/dev/null || echo 0)"
    if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
      _tpg_note "hub Prometheus has ${n} up series from ${c}"
      return 0
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      _tpg_note "no metrics from ${c} on the hub Prometheus after ${timeout}s"
      if [[ -n "$tk_fn" ]]; then
        {
          printf -- '---- remote-write errors logged by the Prometheus on %s (last 10)\n' "$c"
          "$tk_fn" -n monitoring logs -l app.kubernetes.io/name=prometheus -c prometheus --tail=500 2>/dev/null \
            | grep -iE 'remote|write|401|403|x509|tls|dial' | tail -n 10 || true
        } >&2
      fi
      return 1
    fi
    _tpg_note "waiting for metrics from ${c} on the hub Prometheus (${elapsed}s)"
    sleep 15
  done
}
# <<< tpg-shared <<<
