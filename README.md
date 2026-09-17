# ai-stack-trust-demo

A live demo built for a conference keynote on trust in cloud-native AI
stacks (talk link: add here once published). One request -- "checkout-service
pods are crashlooping, what's wrong and can we fix it?" -- walks up four
trust gates:

1. **Access** -- kagent's built-in Kubernetes MCP tools (real `kubectl`
   calls, not simulated)
2. **Context & retrieval** -- a Milvus Lite-backed runbook search tool
3. **Orchestration** -- kagent, reasoning over an OpenRouter free-tier model
4. **Governance** -- a Kyverno policy that genuinely denies an unapproved
   change to a production-labeled resource, with the whole path visible as
   one OpenTelemetry trace in Jaeger

Everything below is scripted end to end: clone, run three scripts, record.

## Prerequisites

- A Kubernetes cluster you have admin access to, with **Kyverno already
  installed** (this repo does not install Kyverno itself -- it's a
  heavier, cluster-wide dependency; see https://kyverno.io/docs/installation/)
- An in-cluster Docker registry reachable from your cluster's nodes (used
  to build and push the runbook-search image), OR set `LOCAL_REGISTRY` in
  `.env` to one you already have
- `kubectl`, `helm`, `python3`, `pip3`, `curl`, `docker`, `envsubst`
  (part of `gettext` -- `apt install gettext` / `brew install gettext`)
- An OpenRouter API key (free tier works -- see the rate-limit note below)

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
re-run ("address already in use" on a second attempt). `demo/run_demo.sh`
checks both ports are open before starting and tells you exactly what to
run if they aren't.

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
  kagent CLI (kagent invoke)
        |
        v
  trust-demo-agent (kagent, OpenRouter/openrouter-free)
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
  OTel spans -> Jaeger (all-in-one, in-cluster)
```

- **Gate 1 & 3** use kagent's own built-in Kubernetes MCP tool server and
  agent runtime -- no custom code. Verified end-to-end: a chat prompt
  triggers a real `kubectl get pod` call, visible in `kagent-tools` logs
  with a real trace ID attached.
- **Gate 2** (`retrieval/`) is the one genuinely custom piece: a small
  FastMCP server exposing one tool, `search_runbooks`, backed by Milvus
  Lite's built-in BM25 full-text search (no embedding model -- kept the
  footprint down on a memory-constrained node). Deployed via kagent's own
  `MCPServer` CRD, same pattern as kagent's documented `mcp-server-fetch`
  example.
- **Gate 4** (`k8s/kyverno-policy.yaml`) is real admission control, not a
  simulation: it denies `UPDATE`/`DELETE` on any `Pod`/`Deployment`
  labeled `env=prod` unless it carries the `demo.io/approved-by`
  annotation. `trust-demo-agent` is never told to add that annotation --
  the point is that it can't just talk its way past the gate.

## What's verified vs. what needs a dry run

**Verified live end to end, 2026-09-17**: all four gates, via a direct
call to `trust-demo-agent` (see the CLI gotcha below for why not through
`kagent invoke`). Real diagnosis, real runbook citation, a real
`k8s_patch_resource` attempt genuinely denied by Kyverno's admission
webhook (confirmed in the admission-controller's own logs, blocking
`system:serviceaccount:kagent:kagent-tools` itself), and a real trace in
Jaeger showing `mcp.tool.k8s_patch_resource` with a nested `ERROR`-status
span for the denied call.

**Still worth doing before you record**: run `demo/run_demo.sh` 2-3 times
end to end yourself. LLM tool-choice reliability is the one genuinely
non-deterministic piece here -- the model needs to (a) actually call
`search_runbooks`, and (b) attempt the patch instead of asking for
permission first (a system-prompt line fixed this once, but re-verify
after any model swap). Re-run the dry runs if you change `LLM_MODEL`.

## Gotchas already found (so you don't hit them again)

- **`helm --set providers.openAI.baseUrl=...` does nothing.** It's not
  wired into the kagent chart's `ModelConfig` template in v0.10.1 --
  silently ignored. `startup.sh` handles this with a `kubectl patch`
  after install, per kagent's own
  [BYO OpenAI-compatible provider](https://kagent.dev/docs/kagent/supported-providers/byo-openai)
  doc, which is the real config surface.
- **OpenRouter's free tier caps at 50 requests/day** (1000/day with the
  $10 credit bump). This demo is single-pass so it's lower risk than a
  multi-pass version, but dry-run iteration still burns requests --
  budget for it, don't dry-run carelessly the morning of.
- Model is `openrouter/free` -- OpenRouter's own free-model auto-router,
  confirmed via `openrouter.ai/api/v1/models` to support `tools`/
  `tool_choice`. Not the same as the litellm-only `openrouter/openrouter/free`
  alias -- kagent calls OpenRouter's API directly, so it needs a real
  model ID.
- First-time image pulls for kagent's components can take 10+ minutes on
  a bandwidth-constrained node. Not a config problem, just patience --
  cached after that.
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
- **Stage 3 of `demo/run_demo.sh` can sit for 3-7 minutes with no visible
  output before this fix.** It's making 3-4 sequential calls to a free
  OpenRouter model, each queuing for a while -- not stuck. The script now
  polls `kagent-tools`' own logs every 2s and prints each real command as
  it executes, plus an elapsed-time counter, so it's visibly alive instead
  of looking hung. This is a real-time cost worth planning your recording
  around (cut/speed up the wait in editing), not something a faster model
  reliably fixes -- two different pinned models (a 550B one and one
  branded "lightning") both took 400+ seconds; the bottleneck looks like
  OpenRouter's free-tier queueing itself, not model size.
- **The agent needs to be told, explicitly, not to ask permission before
  acting.** The first real run diagnosed the problem correctly, cited the
  right runbook, then stopped and asked "would you like me to proceed?"
  instead of calling its patch tool. Fixed in the system prompt
  (`kagent/agent.yaml`) -- worth re-checking if you change `LLM_MODEL`.
- **`startup.sh`'s kagent step must reconcile every run
  (`helm upgrade --install`), not just install-if-missing.** Gating config
  changes (like enabling OTel tracing) behind "only if not already
  installed" meant they silently never applied on a cluster where kagent
  was already there from an earlier run -- traces just never showed up in
  Jaeger, with no error anywhere to point at why.

## Cleanup

`scripts/teardown.sh` removes everything this repo created (namespaces,
the Kyverno policy, the Agent/MCPServer, Jaeger) but **leaves kagent and
Kyverno installed** -- it doesn't assume it's the only thing depending on
them. The script prints the manual commands to remove those fully if you
want a clean cluster.
