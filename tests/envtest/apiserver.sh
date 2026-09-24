#!/usr/bin/env bash
# A real Kubernetes API server for offline tests: etcd and kube-apiserver from
# the envtest binaries (https://github.com/kubernetes-sigs/controller-tools
# releases, envtest-v1.34.x), no controllers, no nodes. Sourced by
# tests/admission/run.sh and tests/ssa/run.sh.
#
#   envtest_find        -> 0 when etcd, kube-apiserver and kubectl are found
#                          (KUBEBUILDER_ASSETS, then PATH)
#   envtest_start DIR   -> starts both, writes DIR/kubeconfig and exports KUBECONFIG
#   envtest_stop        -> stops both (installed as an EXIT trap by envtest_start)
# Authentication: a static token for user "admin" in group system:masters;
# authorization AlwaysAllow, so kubectl --as works for impersonation tests.

envtest_find() {
  local d
  for d in "${KUBEBUILDER_ASSETS:-}" $(dirname "$(command -v kube-apiserver 2>/dev/null || echo /nonexistent/x)"); do
    [[ -n "$d" && -x "$d/kube-apiserver" && -x "$d/etcd" && -x "$d/kubectl" ]] || continue
    ENVTEST_BIN="$d"
    return 0
  done
  return 1
}

envtest_free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

envtest_start() {
  local dir="$1" etcd_port peer_port api_port
  mkdir -p "$dir/etcd" "$dir/certs"
  etcd_port="$(envtest_free_port)"; peer_port="$(envtest_free_port)"; api_port="$(envtest_free_port)"
  "$ENVTEST_BIN/etcd" --data-dir "$dir/etcd" --listen-client-urls "http://127.0.0.1:${etcd_port}" \
    --advertise-client-urls "http://127.0.0.1:${etcd_port}" --listen-peer-urls "http://127.0.0.1:${peer_port}" \
    --unsafe-no-fsync > "$dir/etcd.log" 2>&1 &
  ENVTEST_ETCD_PID=$!
  openssl genrsa -out "$dir/certs/sa.key" 2048 >/dev/null 2>&1
  openssl rsa -in "$dir/certs/sa.key" -pubout -out "$dir/certs/sa.pub" >/dev/null 2>&1
  echo "envtest-token,admin,admin,system:masters" > "$dir/tokens.csv"
  "$ENVTEST_BIN/kube-apiserver" --etcd-servers "http://127.0.0.1:${etcd_port}" \
    --bind-address 127.0.0.1 --secure-port "$api_port" --cert-dir "$dir/certs" \
    --token-auth-file "$dir/tokens.csv" --authorization-mode AlwaysAllow \
    --service-account-issuer https://kubernetes.default.svc --service-account-key-file "$dir/certs/sa.pub" \
    --service-account-signing-key-file "$dir/certs/sa.key" --service-cluster-ip-range 10.0.0.0/24 \
    --disable-admission-plugins ServiceAccount > "$dir/apiserver.log" 2>&1 &
  ENVTEST_API_PID=$!
  trap envtest_stop EXIT
  cat > "$dir/kubeconfig" <<KC
apiVersion: v1
kind: Config
clusters: [{name: envtest, cluster: {server: "https://127.0.0.1:${api_port}", insecure-skip-tls-verify: true}}]
users: [{name: admin, user: {token: envtest-token}}]
contexts: [{name: envtest, context: {cluster: envtest, user: admin}}]
current-context: envtest
KC
  export KUBECONFIG="$dir/kubeconfig"
  for _ in $(seq 1 60); do
    "$ENVTEST_BIN/kubectl" get --raw /readyz >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "kube-apiserver did not become ready; see $dir/apiserver.log" >&2
  tail -20 "$dir/apiserver.log" >&2
  return 1
}

envtest_stop() {
  [[ -z "${ENVTEST_API_PID:-}" ]] || kill "$ENVTEST_API_PID" 2>/dev/null || true
  [[ -z "${ENVTEST_ETCD_PID:-}" ]] || kill "$ENVTEST_ETCD_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  [[ -z "${ENVTEST_TMP:-}" ]] || rm -rf "$ENVTEST_TMP"
}
