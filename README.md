# ai-stack-trust-demo

A live demo built for a conference keynote on trust in cloud-native AI
stacks (talk link: add here once published). One request -- "checkout-service
pods are crashlooping, what's wrong and can we fix it?" -- walks up four
trust gates:

1. **Access** -- kagent's built-in Kubernetes MCP tools (real `kubectl`
   calls, not simulated)
2. **Context & retrieval** -- a Milvus Lite-backed runbook search tool
3. **Orchestration** -- kagent, reasoning over an LLM via OpenRouter
4. **Governance** -- a Kyverno policy that genuinely denies an unapproved
   change to a production-labeled resource, with the whole path visible as
   one OpenTelemetry trace in Jaeger

Everything below is scripted end to end: clone, run the scripts, record.

## Prerequisites

- A Kubernetes cluster you have admin access to, with **Kyverno already
  installed** (this repo does not install Kyverno itself -- it's a
  heavier, cluster-wide dependency; see https://kyverno.io/docs/installation/)
- An in-cluster Docker registry reachable from your cluster's nodes (used
  to build and push the runbook-search image), OR set `LOCAL_REGISTRY` in
  `.env` to one you already have
- `kubectl`, `helm`, `python3`, `pip3`, `curl`, `docker`, `envsubst`
  (part of `gettext` -- `apt install gettext` / `brew install gettext`)
- An OpenRouter API key

## Quickstart

```bash
cp .env.example .env   # fill in OPENROUTER_API_KEY, or let preflight prompt you
bash scripts/startup.sh
```

Then, in **two separate terminal tabs**:

```bash
# Tab 1 -- leave this running for the whole session
bash scripts/port-forwards.sh

# Tab 2 -- this is the one you record
bash demo/run_demo.sh
```

Kept these separate (found 2026-09-17): mixing port-forward log lines into
the same terminal as the demo script was confusing to watch and fragile to
re-run. `port-forwards.sh` auto-reconnects if a tunnel drops (which
happens whenever the pod it's forwarding to gets replaced -- a helm
upgrade, or `run_demo.sh` resetting Jaeger for a clean slate each run,
both do this). `demo/run_demo.sh` checks both ports are open before
starting and tells you exactly what to run if they aren't.

When you're done:

```bash
bash scripts/teardown.sh   # leaves kagent/Kyverno installed
```

`scripts/preflight.sh` runs automatically as part of `startup.sh` -- checks
tooling, cluster reachability, and node memory headroom, and confirms
before touching anything cluster-wide.

## Architecture

```
 you type a prompt
        |
        v
  curl -> kagent-controller's a2a API (NOT the kagent CLI -- see gotcha below)
        |
        v
  trust-demo-agent (kagent, LLM via OpenRouter)
        |
        +--> Gate 1: kagent-tools (built-in)  -- real kubectl calls
        |
        +--> Gate 2: runbook-search (custom MCP server, Milvus Lite BM25)
        |
        v
  Gate 4: any write attempt hits the live Kyverno admission webhook --
          allowed or denied for real, both outcomes traced
        |
        v
  OTel spans (tool execution AND the agent's own model-call reasoning) ->
  Jaeger (all-in-one, in-cluster)
```

- **Gate 1 & 3** use kagent's own built-in Kubernetes MCP tool server and
  agent runtime -- no custom code. Verified end-to-end: a prompt triggers
  real `kubectl` calls, visible in `kagent-tools` logs with a real trace ID
  attached, and the agent's own reasoning shows up in Jaeger too (see the
  tracing gotcha below).
- **Gate 2** (`retrieval/`) is one of two genuinely custom pieces: a small
  FastMCP server exposing one tool, `search_runbooks`, backed by Milvus
  Lite's built-in BM25 full-text search (no embedding model -- kept the
  footprint down on a memory-constrained node). Deployed via kagent's own
  `MCPServer` CRD, same pattern as kagent's documented `mcp-server-fetch`
  example.
- **Gate 4** (`k8s/kyverno-policy.yaml`) is real admission control, not a
  simulation: it denies `UPDATE`/`DELETE` on any `Pod`/`Deployment`
  labeled `env=prod` unless it *already carried* the
  `demo.io/approved-by` annotation **before** the request (checked against
  `request.oldObject`, not `request.object` -- see the security gotcha
  below for why that distinction matters), and is scoped to only gate the
  agent's own ServiceAccount identity, not every identity on the cluster.
  `trust-demo-agent` is explicitly told not to suggest working around this
  gate, let alone attempt to.
- `demo/render_response.py` is the second custom piece: after each run
  completes, it walks the agent's full, real task history and prints every
  tool call with its complete, verbatim, untruncated output (except three
  routinely-huge tools capped at 12 lines each), labeled by which gate it
  is, then a final scorecard.

## What's verified vs. what needs a dry run

**Verified live, repeatedly, through 2026-09-18**: all four gates, via a
direct call to `trust-demo-agent`'s a2a API (see the CLI gotcha below for
why not through `kagent invoke`). Real diagnosis, real runbook citation, a
real `k8s_patch_resource` attempt genuinely denied by Kyverno's admission
webhook every time it was tried -- including deliberate attempts to route
around it (see the security gotcha) -- and a real Jaeger trace showing
both tool execution spans and the agent's own model-reasoning span.

**Still worth doing before you record**: run `demo/run_demo.sh` 2-3 times
end to end yourself. LLM tool-choice reliability is the one genuinely
non-deterministic piece here -- the model needs to (a) actually call
`search_runbooks`, (b) attempt the patch instead of asking for permission
first, and (c) stop after one denied attempt instead of retrying. All
three are enforced in the system prompt (`kagent/agent.yaml`) and have
held up across many runs with the default model, but re-verify if you
change `LLM_MODEL` -- reliability genuinely varies by model, sometimes a
lot.

## Gotchas already found (so you don't hit them again)

- **`helm --set providers.openAI.baseUrl=...` does nothing.** It's not
  wired into the kagent chart's `ModelConfig` template in v0.10.1 --
  silently ignored. `startup.sh` handles this with a `kubectl patch`
  after install, per kagent's own
  [BYO OpenAI-compatible provider](https://kagent.dev/docs/kagent/supported-providers/byo-openai)
  doc, which is the real config surface.
- **Tool-calling reliability and response time both vary significantly by
  `LLM_MODEL`.** An auto-routed or under-powered model can be slow enough
  to make a live recording impractical, or undisciplined enough to keep
  retrying an already-denied action instead of reporting it. Re-run
  several dry runs after changing the model before trusting it.
- **`kagent invoke` (the CLI) fails** on this a2a response shape --
  `jsonrpc error -32603: failed to decode response: json: cannot
  unmarshal object into ... []*errordetails.Typed`. The same request
  against the controller's own API directly works fine and returns a
  correct, complete response -- looks like a bug in the CLI's a2a client,
  not this setup. `demo/run_demo.sh` calls the API directly instead.
- **kagent's MCPServer resources default to `imagePullPolicy:
  IfNotPresent`.** If you rebuild `retrieval/`'s image and push the same
  `:latest` tag, the node won't re-pull it unless you force
  `imagePullPolicy: Always` (already set in `kagent/mcpserver-milvus.yaml`)
  -- otherwise a fixed bug looks unfixed because the old image is still
  running.
- **Milvus Lite's collection loads as `released` on every fresh process**,
  even though it was seeded (and left loaded) in a different process at
  image-build time. `retrieval/mcp_server.py` calls `load_collection()`
  explicitly at startup -- without it, every search fails with "call
  load() before search/get/query".
- **The agent needs to be told, explicitly, not to ask permission before
  acting, and not to retry after a denial.** The first real run diagnosed
  the problem correctly, cited the right runbook, then stopped and asked
  "would you like me to proceed?" instead of calling its patch tool. A
  later run made three quick patch attempts after the first was denied.
  Both fixed in the system prompt (`kagent/agent.yaml`) -- worth
  re-checking if you change `LLM_MODEL`.
- **Security bug found on the first real run: the agent could self-approve
  its own change.** The Kyverno policy originally checked
  `request.object` (the resource as submitted, including whatever the
  agent's own patch added) rather than `request.oldObject` (the resource's
  state *before* this request). The agent simply added the required
  `demo.io/approved-by` annotation to its own patch payload and got
  through -- completely defeating the point of the gate. Fixed by checking
  `oldObject` instead, so only an annotation that existed *before* the
  agent touched anything counts.
- **The same policy also blocked legitimate platform operations, not just
  the agent.** An admin's own `kubectl delete` on the demo fixture was
  denied by the same rule. Scoped the policy to `subjects: kind:
  ServiceAccount, name: kagent-tools` so it only gates the agent's actual
  identity, not everyone who can touch the resource.
- **`k8s_patch_resource` essentially never returns Kyverno's actual denial
  message to the model** -- typically just a bare `exit status 1`, even
  though the real message is always in `kagent-tools`' own pod logs. Two
  consequences handled: (1) `demo/render_response.py` classifies a denied
  gate-4 attempt by whether the tool reported an error at all, not by
  string-matching "denied" in the text -- an earlier version did that and
  silently mislabeled real denials as ALLOWED; (2) `demo/run_demo.sh`
  pulls the real message directly from `kagent-tools`' log as independent
  "ground truth", shown regardless of what the agent's own tool response
  contained.
- **The agent's own reasoning/LLM-call tracing needs a *chart-level* Helm
  value (`otel.tracing.enabled`), not a per-Agent env var.** A per-Agent
  `OTEL_TRACING_ENABLED=true` env var gets silently clobbered -- the
  kagent controller unconditionally appends its own
  `OTEL_TRACING_ENABLED=false` after any custom env vars in the Agent
  spec. `scripts/startup.sh` sets the chart-level value instead, which is
  a separate toggle from `kagent-tools.otel.tracing.*` (that one only
  covers tool-execution spans, not the model call itself).
- **`startup.sh`'s kagent step must reconcile every run
  (`helm upgrade --install`), not just install-if-missing.** Gating config
  changes behind "only if not already installed" meant they silently
  never applied on a cluster where kagent was already there from an
  earlier run.
- **Any `kubectl port-forward` breaks silently when the pod it's attached
  to gets replaced** -- it pins to a specific pod IP resolved at start
  time and does not follow the Service. This bit the setup twice: once
  when a `helm upgrade` restarted `kagent-controller`, and again by
  design every time `demo/run_demo.sh` resets Jaeger for a clean slate.
  `scripts/port-forwards.sh` wraps both forwards in an auto-reconnect
  loop so this is no longer something you have to notice and fix by hand.
- **Jaeger's in-memory storage has no purge API** -- the only way to
  actually clear old traces (and stop unrelated services from earlier
  testing cluttering the trace view) is restarting its pod.
  `demo/run_demo.sh` does this at the start of every run.
- First-time image pulls for kagent's components can take 10+ minutes on
  a bandwidth-constrained node. Not a config problem, just patience --
  cached after that.

## Cleanup

`scripts/teardown.sh` removes everything this repo created (namespaces,
the Kyverno policy, the Agent/MCPServer, Jaeger) but **leaves kagent and
Kyverno installed** -- it doesn't assume it's the only thing depending on
them. The script prints the manual commands to remove those fully if you
want a clean cluster.
