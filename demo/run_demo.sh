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

# NOTE (found 2026-09-17): `kagent invoke` fails with a JSON decode error
# on this a2a response shape ("cannot unmarshal object into
# []*errordetails.Typed") -- looks like a bug in the CLI's a2a client, not
# in this setup (the same request against the controller's API directly
# works and returns a correct, full response). Calling the API directly
# until that's fixed upstream.
CONTROLLER_PF_PID=""
JAEGER_PF_PID=""
cleanup() {
  [[ -n "$CONTROLLER_PF_PID" ]] && kill "$CONTROLLER_PF_PID" 2>/dev/null
  [[ -n "$JAEGER_PF_PID" ]] && kill "$JAEGER_PF_PID" 2>/dev/null
  true
}
trap cleanup EXIT

run() {
  printf "${COLOR_CYAN}\$ %s${COLOR_RESET}\n" "$*"
  "$@"
}

clear || true
printf "${COLOR_BOLD}== Stage 1/4: the crash is real ==${COLOR_RESET}\n\n"
run kubectl --context "$KUBE_CTX" get pods -n "${NAMESPACE_PREFIX}-staging"
echo
run kubectl --context "$KUBE_CTX" logs -n "${NAMESPACE_PREFIX}-staging" -l app=checkout-service --tail=10 --previous
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to continue]${COLOR_RESET}")" _

clear || true
printf "${COLOR_BOLD}== Stage 2/4: ask the agent ==${COLOR_RESET}\n\n"
echo "Your agent is ready. Ask it something like:"
echo "\"checkout-service pods are crashlooping, what's wrong and can we fix it?\""
echo
printf "${COLOR_CYAN}"
read -r -p "> " PROMPT
printf "${COLOR_RESET}"
echo

printf "${COLOR_BOLD}== Stage 3/4: gates 1-3 (MCP access, runbook retrieval, kagent orchestration) ==${COLOR_RESET}\n\n"
run kubectl --context "$KUBE_CTX" port-forward svc/kagent-controller 8083:8083 -n kagent &
CONTROLLER_PF_PID=$!
sleep 2
MSG_ID="m$(date +%s)"
run curl -sS -X POST http://localhost:8083/api/a2a/kagent/trust-demo-agent/ \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','messageId':sys.argv[1],'parts':[{'kind':'text','text':sys.argv[2]}]}}}))" "$MSG_ID" "$PROMPT")" \
  -o /tmp/ai-stack-trust-demo-response.json
echo
python3 -c "
import json
with open('/tmp/ai-stack-trust-demo-response.json') as f:
    d = json.load(f)
print(d['result']['artifacts'][0]['parts'][0]['text'])
"
kill "$CONTROLLER_PF_PID" 2>/dev/null || true
CONTROLLER_PF_PID=""
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to continue]${COLOR_RESET}")" _

clear || true
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
