#!/usr/bin/env bash
# Single-pass, self-guided recording script. No narration text -- only
# stage separators, real commands, and real output. cyan = command/live
# input, green = allowed/successful, red = denied/error.
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
KUBE_CTX="${KUBE_CONTEXT:-}"
[[ -z "$KUBE_CTX" ]] && KUBE_CTX="$(kubectl config current-context)"

require_cmd kagent || {
  log_error "kagent CLI not found. Install it first:"
  log_error "  curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash"
  exit 1
}

run() {
  printf "${COLOR_CYAN}\$ %s${COLOR_RESET}\n" "$*"
  "$@"
}

clear
printf "${COLOR_BOLD}== Stage 1/4: the crash is real ==${COLOR_RESET}\n\n"
run kubectl --context "$KUBE_CTX" get pods -n "${NAMESPACE_PREFIX}-staging"
echo
run kubectl --context "$KUBE_CTX" logs -n "${NAMESPACE_PREFIX}-staging" -l app=checkout-service --tail=10 --previous
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to continue]${COLOR_RESET}")" _

clear
printf "${COLOR_BOLD}== Stage 2/4: ask the agent ==${COLOR_RESET}\n\n"
echo "Your agent is ready. Ask it something like:"
echo "\"checkout-service pods are crashlooping, what's wrong and can we fix it?\""
echo
printf "${COLOR_CYAN}"
read -r -p "> " PROMPT
printf "${COLOR_RESET}"
echo

printf "${COLOR_BOLD}== Stage 3/4: gates 1-3 (MCP access, runbook retrieval, kagent orchestration) ==${COLOR_RESET}\n\n"
run kagent invoke -n kagent --agent trust-demo-agent -t "$PROMPT" -v
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to continue]${COLOR_RESET}")" _

clear
printf "${COLOR_BOLD}== Stage 4/4: gate 4 (Kyverno + the trace) ==${COLOR_RESET}\n\n"
echo "If the agent attempted to change checkout-service directly, the"
echo "Kyverno policy either allowed it (approval annotation present) or"
echo "denied it (none) -- that decision is now part of the trace below."
echo
printf "${COLOR_CYAN}"
echo "Open Jaeger, find the most recent trace for service 'kagent-tools',"
echo "and follow it end to end: the MCP call -> the runbook search -> the"
echo "policy decision."
printf "${COLOR_RESET}\n"
echo "If you don't already have a port-forward running:"
run kubectl --context "$KUBE_CTX" port-forward svc/jaeger-query -n "${NAMESPACE_PREFIX}-observability" "${JAEGER_LOCAL_PORT:-16686}:16686" &
JAEGER_PF_PID=$!
sleep 2
echo "Jaeger: http://localhost:${JAEGER_LOCAL_PORT:-16686}"
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to stop the port-forward and exit]${COLOR_RESET}")" _
kill "$JAEGER_PF_PID" 2>/dev/null || true
