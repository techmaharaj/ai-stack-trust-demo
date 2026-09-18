#!/usr/bin/env bash
# Run this in its own terminal tab, separate from demo/run_demo.sh --
# keeps the recording terminal free of port-forward log lines and avoids
# "address already in use" errors on repeat runs.
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

# Auto-reconnecting: kubectl port-forward tunnels to a specific pod IP
# resolved at start time and does NOT follow the Service if that pod is
# replaced (a helm upgrade, or resetting Jaeger's in-memory traces for a
# clean slate, both do this) -- a dropped tunnel otherwise fails silently
# until the next demo run errors out. Wrapping in a retry loop means it
# reconnects to whatever pod is live now, automatically.
reconnecting_forward() {
  local desc="$1"; shift
  while true; do
    kubectl --context "$KUBE_CTX" port-forward "$@" 2>&1 | while IFS= read -r line; do
      echo "[$desc] $line"
    done
    log_warn "[$desc] tunnel dropped -- reconnecting in 2s..."
    sleep 2
  done
}

log_step "Starting both port-forwards (auto-reconnecting) -- leave this tab open"
# controller stays on 127.0.0.1 -- only demo/run_demo.sh (on this same
# host) needs it. Jaeger binds 0.0.0.0 -- recording from a laptop means
# the browser needs to reach it over the LAN, not just from this host.
# No auth in front of it, same tradeoff as kagent-ui earlier -- fine for
# a demo box, not for anything sensitive.
reconnecting_forward controller svc/kagent-controller 8083:8083 -n kagent &
PID1=$!
reconnecting_forward jaeger --address 0.0.0.0 svc/jaeger-query -n "${NAMESPACE_PREFIX}-observability" "$JAEGER_PORT:16686" &
PID2=$!

cleanup() {
  kill "$PID1" "$PID2" 2>/dev/null
  pkill -P "$PID1" 2>/dev/null
  pkill -P "$PID2" 2>/dev/null
  true
}
trap cleanup EXIT INT TERM

log_info "kagent controller: http://localhost:8083 (this host only)"
log_info "Jaeger:             http://localhost:${JAEGER_PORT} (this host)"
log_info "                    http://$(hostname):${JAEGER_PORT} (from your laptop, same network)"
log_info "Ctrl+C here when you're done recording."
wait
