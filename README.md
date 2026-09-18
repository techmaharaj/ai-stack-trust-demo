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

Port-forwarding runs in its own tab, separate from the demo script, so the
recording terminal stays clean. `port-forwards.sh` reconnects automatically
if a tunnel drops (this happens whenever the pod it's forwarding to gets
replaced, which `run_demo.sh` does on purpose each run to reset Jaeger --
see Architecture below). `demo/run_demo.sh` checks both ports are open
before starting and tells you what to run if they aren't.

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
  curl -> kagent-controller's a2a API
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
  agent runtime -- no custom code. A prompt triggers real `kubectl` calls,
  visible in `kagent-tools`' logs with a trace ID attached; the agent's
  own reasoning is traced too (see Tracing below).
- **Gate 2** (`retrieval/`) is a small FastMCP server exposing one tool,
  `search_runbooks`, backed by Milvus Lite's built-in BM25 full-text
  search -- no embedding model, which keeps the footprint small. Deployed
  via kagent's own `MCPServer` CRD, the same pattern as kagent's
  documented `mcp-server-fetch` example.
- **Gate 4** (`k8s/kyverno-policy.yaml`) is real Kubernetes admission
  control, not a simulation. It denies `UPDATE`/`DELETE` on any
  `Pod`/`Deployment` labeled `env=prod` unless the resource *already
  carried* the `demo.io/approved-by` annotation **before** the request --
  checked against `request.oldObject`, not `request.object`, so an agent
  cannot satisfy its own approval requirement by adding the annotation in
  the same patch it's trying to get approved. The policy is also scoped
  to the agent's own ServiceAccount identity (`kagent-tools`), not every
  identity on the cluster, so it gates the agent specifically without
  blocking normal platform operations. `trust-demo-agent`'s system prompt
  additionally forbids suggesting a workaround (e.g. relabeling the
  resource to dodge the policy) as a "fix."
- `demo/render_response.py` renders the result: after each run, it walks
  the agent's complete task history and prints every tool call with its
  real output, labeled by which gate it is, then a scorecard of what was
  allowed and denied.

## Before you record

Run `demo/run_demo.sh` 2-3 times end to end before you actually record.
LLM tool-choice is the one genuinely non-deterministic piece here -- the
model needs to (a) actually call `search_runbooks`, (b) attempt the patch
instead of asking for permission first, and (c) stop after one denied
attempt instead of retrying. All three are enforced in the system prompt
(`kagent/agent.yaml`), but re-verify with a few dry runs if you change
`LLM_MODEL` -- reliability varies by model, sometimes a lot.

## Notes and known limitations

- **`helm --set providers.openAI.baseUrl=...` has no effect** on the
  kagent chart's `ModelConfig` template (v0.10.1). Set the base URL
  directly on the `ModelConfig` object instead -- `startup.sh` does this
  with a `kubectl patch` after install, per kagent's own
  [BYO OpenAI-compatible provider](https://kagent.dev/docs/kagent/supported-providers/byo-openai)
  doc.
- **Tool-calling reliability and response time both vary significantly by
  `LLM_MODEL`.** An auto-routed or under-powered model can be slow enough
  to make a live recording impractical, or undisciplined enough to keep
  retrying an already-denied action instead of reporting it.
- **The `kagent invoke` CLI fails on this agent's a2a response shape** --
  `jsonrpc error -32603: failed to decode response: json: cannot
  unmarshal object into ... []*errordetails.Typed`. The same request
  against the controller's API directly works and returns a correct,
  complete response, so `demo/run_demo.sh` calls the API directly rather
  than going through the CLI.
- **kagent's `MCPServer` resources default to `imagePullPolicy:
  IfNotPresent`.** If you rebuild `retrieval/`'s image under the same
  `:latest` tag, the node won't re-pull it unless `imagePullPolicy:
  Always` is set (already set in `kagent/mcpserver-milvus.yaml`).
- **Milvus Lite's collection loads as `released` on every fresh process**,
  even when it was seeded and left loaded by a different process at
  image-build time. `retrieval/mcp_server.py` calls `load_collection()`
  explicitly at startup; without it, searches fail with "call load()
  before search/get/query".
- **The agent's system prompt (`kagent/agent.yaml`) explicitly forbids
  asking for permission before acting and retrying after a denial.**
  Without those instructions, a model may describe a fix instead of
  attempting it, or make several quick variations of a denied write
  instead of reporting the denial. Worth re-checking this behavior if you
  change `LLM_MODEL`.
- **The Kyverno gate checks `request.oldObject`, not `request.object`.**
  Checking the submitted object instead would let the agent add the
  required approval annotation to its own patch and pass the check --
  defeating the point of the gate. `oldObject` reflects the resource's
  state before the request, so only an annotation that existed beforehand
  counts.
- **The policy is scoped by `subjects: kind: ServiceAccount, name:
  kagent-tools`.** Without this scoping, the same rule blocks any
  identity's mutation of a matching resource, including a human operator
  running `kubectl` directly -- not just the agent it's meant to gate.
- **`k8s_patch_resource` often returns a bare `exit status 1` to the
  model, without Kyverno's actual denial message**, even though the full
  message is always present in `kagent-tools`' own pod logs. Two things
  account for this: `demo/render_response.py` classifies a denied gate-4
  attempt by whether the tool reported an error at all (not by
  string-matching "denied" in the output text, which misses this case
  entirely), and `demo/run_demo.sh` separately pulls the real message
  from `kagent-tools`' log as an independent "ground truth" display,
  regardless of what the agent's own tool response contained.
- **Tracing the agent's own reasoning/LLM calls needs the chart-level
  `otel.tracing.enabled` Helm value, not a per-Agent env var.** A
  per-Agent `OTEL_TRACING_ENABLED` env var is overridden by a value the
  kagent controller appends afterward. `scripts/startup.sh` sets the
  chart-level value, which is separate from `kagent-tools.otel.tracing.*`
  (that one only covers tool-execution spans, not the model call itself).
- **`startup.sh`'s kagent step always reconciles (`helm upgrade
  --install`), rather than only installing if missing.** Gating config
  changes behind "only if not already installed" would mean they never
  apply on a cluster where kagent already exists.
- **`kubectl port-forward` does not follow a Service when its backing pod
  is replaced** -- it pins to the pod IP resolved at start time, so the
  tunnel breaks on any pod restart (a `helm upgrade`, or the Jaeger reset
  described below). `scripts/port-forwards.sh` wraps both forwards in an
  auto-reconnect loop so this doesn't require manual intervention.
- **Jaeger's in-memory storage has no purge API.** The only way to clear
  old traces between runs is restarting its pod, which
  `demo/run_demo.sh` does at the start of every run for a clean trace
  view.
- First-time image pulls for kagent's components can take several minutes
  on a bandwidth-constrained node; this is expected and only happens once.

## Cleanup

`scripts/teardown.sh` removes everything this repo created (namespaces,
the Kyverno policy, the Agent/MCPServer, Jaeger) but **leaves kagent and
Kyverno installed** -- it doesn't assume it's the only thing depending on
them. The script prints the manual commands to remove those fully if you
want a clean cluster.
