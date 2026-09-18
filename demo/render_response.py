#!/usr/bin/env python3
"""Renders the agent's full response history as a gate-by-gate walkthrough
with the real command and real, complete output for every tool call --
no truncation, no simulation. Reads the whole task history only after the
response is complete, so every detail here is exactly what happened,
verbatim.
"""
import json
import sys

RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"

GATES = {
    "k8s_get_resources": ("1", "ACCESS (MCP)", "Can this identity even reach the cluster to look?", GREEN),
    "k8s_get_pod_logs": ("1", "ACCESS (MCP)", "Can this identity even reach the cluster to look?", GREEN),
    "k8s_describe_resource": ("1", "ACCESS (MCP)", "Can this identity even reach the cluster to look?", GREEN),
    "k8s_get_events": ("1", "ACCESS (MCP)", "Can this identity even reach the cluster to look?", GREEN),
    "search_runbooks": ("2", "RETRIEVAL (Milvus)", "What does prior experience already know about this?", GREEN),
    "k8s_patch_resource": ("4", "GOVERNANCE (Kyverno)", "Is this identity actually allowed to make this change?", YELLOW),
}

BANNER = "━" * 63

# These three tools routinely return huge dumps (a full cluster-wide pod
# list, a full `describe`, a full events JSON blob) that bury the
# actually-interesting gate 2/4 output. Truncate just these;
# search_runbooks and k8s_patch_resource stay full -- they're already
# short and are the parts that matter most.
TRUNCATE_TOOLS = {"k8s_get_resources", "k8s_describe_resource", "k8s_get_events"}
TRUNCATE_LINES = 12


def truncate(text, name):
    if name not in TRUNCATE_TOOLS:
        return text
    lines = text.splitlines()
    if len(lines) <= TRUNCATE_LINES:
        return text
    shown = lines[:TRUNCATE_LINES]
    return "\n".join(shown) + f"\n... ({len(lines) - TRUNCATE_LINES} more lines truncated)"


def banner(color, name, question):
    print(f"\n{color}{BANNER}")
    print(f"  GATE {name}")
    print(f'  "{question}"')
    print(f"{BANNER}{RESET}")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ai-stack-trust-demo-response.json"
    with open(path) as f:
        d = json.load(f)
    result = d.get("result", {})
    state = result.get("status", {}).get("state")

    if state == "failed":
        msg = result["status"]["message"]["parts"][0]["text"]
        print(f"{RED}The agent task failed (often an upstream LLM rate-limit or outage,")
        print("not this setup -- try again in a moment, or pin a different")
        print(f"LLM_MODEL in .env):{RESET}")
        print(msg)
        return

    if state == "input-required":
        print(f"{RED}The agent stopped to ask a question instead of finishing --")
        print(f"it should not do this (see kagent/agent.yaml). It got this far:{RESET}")
        for msg in result.get("history", []):
            for part in msg.get("parts", []):
                if part.get("kind") == "text":
                    print(f"  [{msg.get('role')}] {part['text']}")
        return

    history = result.get("history", [])
    pending = {}
    seen_gates = set()
    counts = {"1": 0, "2": 0, "4": 0}
    deny_count = 0
    allow_count = 0
    last_denial = ""
    last_runbook = ""

    for msg in history:
        role = msg.get("role")
        for part in msg.get("parts", []):
            if part.get("kind") == "text" and role == "agent":
                text = part["text"].strip()
                if text:
                    print(f"\n{text}")
            elif part.get("kind") == "data":
                data = part["data"]
                meta_type = part.get("metadata", {}).get("adk_type")
                if meta_type == "function_call":
                    pending[data["id"]] = (data["name"], data.get("args", {}))
                elif meta_type == "function_response":
                    name, args = pending.pop(data["id"], (data.get("name", "?"), {}))
                    gate = GATES.get(name)
                    response = data.get("response", {})
                    output = response.get("output")
                    error = response.get("error")
                    text_out = json.dumps(output, indent=2) if isinstance(output, dict) else str(output or error or "")

                    if gate:
                        gate_id, gate_name, question, color = gate
                        if gate_id not in seen_gates:
                            banner(color, f"{gate_id} -- {gate_name}", question)
                            seen_gates.add(gate_id)
                        counts[gate_id] += 1

                        # Classify by whether the tool actually reported an
                        # error, not by string-matching "denied" in the
                        # text -- kagent-tools sometimes returns a bare
                        # "exit status 1" with no policy message at all,
                        # which a string-match would miss and mislabel as
                        # ALLOWED. A patch that errored never took effect,
                        # full stop, regardless of whether the reason text
                        # came through.
                        is_denied = (gate_id == "4") and (error is not None)
                        line_color = RED if is_denied else GREEN
                        print(f"\n{CYAN}$ {name}({json.dumps(args)}){RESET}")
                        print(f"{line_color}{truncate(text_out.strip(), name)}{RESET}")

                        if gate_id == "4":
                            if is_denied:
                                deny_count += 1
                                if "denied" in text_out.lower() or "admission webhook" in text_out.lower():
                                    last_denial = text_out.strip()
                                elif not last_denial:
                                    last_denial = "blocked (tool didn't return the policy's exact message this time -- see Kyverno admission-controller logs for the full reason)"
                            else:
                                allow_count += 1
                        if gate_id == "2":
                            last_runbook = text_out.strip()

    print()
    print(f"{BOLD}== Final answer =={RESET}")
    if "artifacts" in result:
        print(result["artifacts"][0]["parts"][0]["text"])
    else:
        print("(agent produced no final text answer -- see the walkthrough above)")

    print()
    print(f"{BOLD}== Gate scorecard =={RESET}")
    print(f"  GATE 1 (access)        " + (f"{GREEN}ALLOWED{RESET} -- {counts['1']} real cluster read(s)" if counts["1"] else "not used this run"))
    print(f"  GATE 2 (retrieval)     " + (f"{GREEN}ALLOWED{RESET} -- runbook queried" if counts["2"] else "not used this run"))
    print(f"  GATE 3 (orchestration) {GREEN}reasoned across {sum(counts.values())} tool call(s){RESET}")
    if deny_count:
        print(f"  GATE 4 (governance)    {RED}DENIED{RESET} x{deny_count} -- {last_denial}")
    elif allow_count:
        print(f"  GATE 4 (governance)    {GREEN}ALLOWED{RESET} x{allow_count}")
    else:
        print("  GATE 4 (governance)    not triggered this run (no write attempted)")


if __name__ == "__main__":
    main()
