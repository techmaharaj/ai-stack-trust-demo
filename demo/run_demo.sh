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
echo "Each real event below is labeled by which gate it is. This is not"
echo "simulated -- it's read live from the actual pods as they run."
echo
MSG_ID="m$(date +%s)"
run curl -sS -X POST http://localhost:8083/api/a2a/kagent/trust-demo-agent/ \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','messageId':sys.argv[1],'parts':[{'kind':'text','text':sys.argv[2]}]}}}))" "$MSG_ID" "$PROMPT")" \
  -o /tmp/ai-stack-trust-demo-response.json &
CURL_PID=$!

# This genuinely takes real time (multiple sequential LLM calls) -- found
# 2026-09-17 that a silent wait reads as "stuck," not "working," and that
# lumping all of gates 1-3 into one undifferentiated blob didn't show the
# actual layer structure the talk is about. Poll both pods' own logs and
# label each real event by which gate it is, as it happens.
SECONDS=0
LAST_G1=""
LAST_G2=""
LAST_G4=""
while kill -0 "$CURL_PID" 2>/dev/null; do
  sleep 2
  G1="$(kubectl --context "$KUBE_CTX" logs -n kagent -l app.kubernetes.io/name=kagent-tools --since=10s 2>/dev/null \
    | grep 'level=INFO.*executing command' | grep -v patch | tail -1 || true)"
  G4="$(kubectl --context "$KUBE_CTX" logs -n kagent -l app.kubernetes.io/name=kagent-tools --since=10s 2>/dev/null \
    | grep -E 'patch deployment|patch pod' | tail -1 || true)"
  G2="$(kubectl --context "$KUBE_CTX" logs -n kagent -l app.kubernetes.io/name=runbook-search -c mcp-server --since=10s 2>/dev/null \
    | grep 'mcp.tool=search_runbooks' | tail -1 || true)"

  EVENT=0
  if [[ -n "$G1" && "$G1" != "$LAST_G1" ]]; then
    ARGS="$(echo "$G1" | grep -o 'args="\[[^]]*\]"')"
    printf "\r\033[K${COLOR_GREEN}[%3ds] GATE 1 (access)    -- %s${COLOR_RESET}\n" "$SECONDS" "$ARGS"
    LAST_G1="$G1"; EVENT=1
  fi
  if [[ -n "$G2" && "$G2" != "$LAST_G2" ]]; then
    printf "\r\033[K${COLOR_GREEN}[%3ds] GATE 2 (retrieval) -- agent queried the runbook library${COLOR_RESET}\n" "$SECONDS"
    LAST_G2="$G2"; EVENT=1
  fi
  if [[ -n "$G4" && "$G4" != "$LAST_G4" ]]; then
    if echo "$G4" | grep -qi denied; then
      printf "\r\033[K${COLOR_RED}[%3ds] GATE 4 (governance) -- write attempt DENIED by Kyverno${COLOR_RESET}\n" "$SECONDS"
    else
      printf "\r\033[K${COLOR_GREEN}[%3ds] GATE 4 (governance) -- write attempt allowed${COLOR_RESET}\n" "$SECONDS"
    fi
    LAST_G4="$G4"; EVENT=1
  fi
  if [[ "$EVENT" -eq 0 ]]; then
    printf "\r\033[K[%3ds] GATE 3 (orchestration) -- model is thinking..." "$SECONDS"
  fi
done
wait "$CURL_PID" || { printf "\r\033[K"; log_error "the request to the agent failed (curl exit $?)"; exit 1; }
printf "\r\033[K"
echo
python3 -c "
import json
with open('/tmp/ai-stack-trust-demo-response.json') as f:
    d = json.load(f)
result = d.get('result', {})
state = result.get('status', {}).get('state')
if state == 'failed':
    msg = result['status']['message']['parts'][0]['text']
    print('The agent task failed (often an upstream LLM rate-limit or outage,')
    print('not this setup -- try again in a moment, or pin a different')
    print('LLM_MODEL in .env):')
    print(msg)
elif state == 'input-required':
    print('The agent stopped to ask a question instead of finishing --')
    print('it should not do this (see kagent/agent.yaml). It got this far:')
    for msg in result.get('history', []):
        for part in msg.get('parts', []):
            if part.get('kind') == 'text':
                print(f\"  [{msg.get('role')}] {part['text']}\")
elif 'artifacts' in result:
    print(result['artifacts'][0]['parts'][0]['text'])
else:
    print('Unexpected response shape:')
    print(json.dumps(d, indent=2))
"
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
echo "Jaeger: http://localhost:${JAEGER_PORT}"
echo
read -r -p "$(printf "${COLOR_YELLOW}[press Enter to exit]${COLOR_RESET}")" _
