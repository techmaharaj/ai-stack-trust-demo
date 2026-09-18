#!/usr/bin/env bash
# Single-pass, self-guided recording script. No narration text -- only
# stage separators, real commands, and real output. cyan = command/live
# input, green = allowed/successful, red = denied/error.
#
# Port-forwards are NOT started here -- run scripts/port-forwards.sh in a
# separate tab first and leave it running (found 2026-09-17: mixing
# port-forward log lines into this script's own output was confusing to
# watch and fragile to re-run).
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

# NOTE (found 2026-09-17): `kagent invoke` fails with a JSON decode error
# on this a2a response shape ("cannot unmarshal object into
# []*errordetails.Typed") -- looks like a bug in the CLI's a2a client, not
# in this setup (the same request against the controller's API directly
# works and returns a correct, full response). Calling the API directly
# until that's fixed upstream.

run() {
  printf "${COLOR_CYAN}\$ %s${COLOR_RESET}\n" "$*"
  "$@"
}

for p in 8083 "$JAEGER_PORT"; do
  if ! port_open "$p"; then
    log_error "port $p isn't open. Run scripts/port-forwards.sh in a separate"
    log_error "terminal tab first, leave it running, then re-run this script."
    exit 1
  fi
done

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

printf "${COLOR_BOLD}== Stage 3/4: watch the agent walk the gates ==${COLOR_RESET}\n\n"
echo "Below is the agent's complete, real tool-call history -- every"
echo "command and its full output, verbatim, labeled by which gate it is."
echo
MSG_ID="m$(date +%s)"
run curl -sS -X POST http://localhost:8083/api/a2a/kagent/trust-demo-agent/ \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','messageId':sys.argv[1],'parts':[{'kind':'text','text':sys.argv[2]}]}}}))" "$MSG_ID" "$PROMPT")" \
  -o /tmp/ai-stack-trust-demo-response.json &
CURL_PID=$!

# This genuinely takes real time (multiple sequential LLM calls) -- found
# 2026-09-17 that a silent wait reads as "stuck," not "working." A simple
# elapsed-time ticker here is enough; the detailed gate-by-gate breakdown
# happens after the response arrives (see render_response.py) -- found
# 2026-09-18 that live log-scraping during the wait couldn't show full,
# untruncated output and had a bash printf color-escaping bug.
SECONDS=0
while kill -0 "$CURL_PID" 2>/dev/null; do
  sleep 2
  printf "\r\033[K[%3ds] waiting on the agent (this can take a while)..." "$SECONDS"
done
wait "$CURL_PID" || { printf "\r\033[K"; log_error "the request to the agent failed (curl exit $?)"; exit 1; }
printf "\r\033[K"
echo
python3 "$ROOT_DIR/demo/render_response.py" /tmp/ai-stack-trust-demo-response.json
echo

# Ground truth, independent of what the agent's tool call reported: found
# 2026-09-18 that k8s_patch_resource essentially never returns Kyverno's
# actual message to the model (just a bare "exit status 1") -- but
# kagent-tools' own pod log always captures the real kubectl stderr, since
# that's what's actually happening at the API server. Show it directly so
# the audience sees Kyverno's real words, not just the agent's account of
# them.
GROUND_TRUTH="$(kubectl --context "$KUBE_CTX" logs -n kagent -l app.kubernetes.io/name=kagent-tools --since="${SECONDS}s" 2>/dev/null \
  | grep -i 'denied the request' | tail -1 || true)"
if [[ -n "$GROUND_TRUTH" ]]; then
  printf "${COLOR_BOLD}== Ground truth: Kyverno's own admission log (not the agent's account of it) ==${COLOR_RESET}\n\n"
  printf "${COLOR_RED}%s${COLOR_RESET}\n\n" "$GROUND_TRUTH"
fi
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
echo "Jaeger: http://localhost:${JAEGER_PORT}"
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to exit]${COLOR_RESET}")" _
