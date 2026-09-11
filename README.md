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
- `kagent` CLI (only needed for `demo/run_demo.sh`, not for setup):
  `curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash`
- An OpenRouter API key (free tier works -- see the rate-limit note below)

## Quickstart

```bash
cp .env.example .env   # fill in OPENROUTER_API_KEY, or let preflight prompt you
bash scripts/startup.sh
bash demo/run_demo.sh
bash scripts/teardown.sh   # when you're done -- leaves kagent/Kyverno installed
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

**Verified live** (2026-09-11): kagent install + slim profile, the
OpenRouter `ModelConfig` patch, and Gate 1 (built-in tools) end to end via
the kagent UI chat.

**Scripted but not yet run end to end**: Gate 2 (Milvus MCP server image
build/push/wire-in), Gate 4 (the real Kyverno deny), and the full
`demo/run_demo.sh` cut. **Run the whole thing at least 2-3 times before
you trust it enough to record** -- LLM tool-choice reliability is the one
genuinely non-deterministic piece here, same lesson learned the hard way
on an earlier version of this demo. Re-run the dry runs if you change
`LLM_MODEL`.

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

## Cleanup

`scripts/teardown.sh` removes everything this repo created (namespaces,
the Kyverno policy, the Agent/MCPServer, Jaeger) but **leaves kagent and
Kyverno installed** -- it doesn't assume it's the only thing depending on
them. The script prints the manual commands to remove those fully if you
want a clean cluster.
