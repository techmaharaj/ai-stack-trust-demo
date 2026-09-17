#!/usr/bin/env bash
# Run this in its own terminal tab, separate from demo/run_demo.sh --
# keeps the recording terminal free of port-forward log lines (found
# 2026-09-17: mixing them into the same terminal as the demo script was
# confusing to watch and fragile to re-run -- "address already in use"
# errors on re-runs, no clean way to tell what's actually happening).
#
# Leave this running for the whole demo/run_demo.sh session. Ctrl+C here
# when you're done recording.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source scripts/lib/common.sh

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
: "${NAMESPACE_PREFIX:=ai-trust-demo}"
JAEGER_PORT="${JAEGER_LOCAL_PORT:-16686}"
KUBE_CTX="${KUBE_CONTEXT:-}"
[[ -z "$KUBE_CTX" ]] && KUBE_CTX="$(kubectl config current-context)"

for p in 8083 "$JAEGER_PORT"; do
  if port_open "$p"; then
    log_error "port $p is already in use. Free it first (check what's using it:"
    log_error "  lsof -i :$p    or    ss -tlnp | grep $p"
    log_error ") then re-run this script."
    exit 1
  fi
done

log_step "Starting both port-forwards -- leave this tab open"
kubectl --context "$KUBE_CTX" port-forward svc/kagent-controller 8083:8083 -n kagent &
PID1=$!
kubectl --context "$KUBE_CTX" port-forward svc/jaeger-query -n "${NAMESPACE_PREFIX}-observability" "$JAEGER_PORT:16686" &
PID2=$!

cleanup() {
  kill "$PID1" "$PID2" 2>/dev/null
  true
}
trap cleanup EXIT INT TERM

log_info "kagent controller: http://localhost:8083"
log_info "Jaeger:             http://localhost:${JAEGER_PORT}"
log_info "Ctrl+C here when you're done recording."
wait
