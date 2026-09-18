# ai-stack-trust-demo

A live demo built for a conference keynote on trust in cloud-native AI
stacks (talk link: add here once published).

## Overview

An AI agent is asked to investigate and fix a broken Kubernetes service.
To do that, it has to pass through four trust gates, each enforced by a
different real system, not simulated:

1. **Access** -- kagent's built-in Kubernetes MCP tools give it real,
   scoped `kubectl` access -- nothing more.
2. **Context & retrieval** -- a Milvus Lite-backed runbook search tool
   grounds its diagnosis in prior operational knowledge.
3. **Orchestration** -- kagent runs the actual reasoning loop, deciding
   what to check and what to try, via an LLM through OpenRouter.
4. **Governance** -- a live Kyverno policy decides, for real, whether the
   agent's proposed fix is allowed to happen.

The whole path -- tool calls, retrieval, reasoning, and the governance
decision -- is captured as a single OpenTelemetry trace in Jaeger.

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

## Setup

```bash
cp .env.example .env   # fill in OPENROUTER_API_KEY, or let preflight prompt you
bash scripts/startup.sh
```

`scripts/preflight.sh` runs automatically as part of `startup.sh` -- it
checks tooling, cluster reachability, and node memory headroom, and
confirms before touching anything cluster-wide. `startup.sh` then deploys
everything: the namespaces, the crash-looping demo workload, the Kyverno
policy, kagent, Jaeger, and the retrieval service.

See [Configuration](#configuration) below for what each `.env` value does.

## Usage

Run the demo in two separate terminal tabs:

```bash
# Tab 1 -- leave this running for the whole session
bash scripts/port-forwards.sh

# Tab 2 -- this is the one you record
bash demo/run_demo.sh
```

`run_demo.sh` walks through four stages: it shows the crash is real, takes
your prompt, runs the agent and prints its full tool-call history
gate-by-gate as it happens, then opens the resulting Jaeger trace. Tab 1
just holds the two port-forwards the demo needs (to kagent's controller
API and to Jaeger) and runs independently of the recording tab so its
output doesn't clutter the terminal you're recording.

Run `demo/run_demo.sh` a few times end to end before you actually record
-- LLM tool-choice is the one non-deterministic part of this demo.

When you're done:

```bash
bash scripts/teardown.sh   # leaves kagent/Kyverno installed
```

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
  own reasoning is traced too.
- **Gate 2** (`retrieval/`) is a small FastMCP server exposing one tool,
  `search_runbooks`, backed by Milvus Lite's built-in BM25 full-text
  search -- no embedding model, which keeps the footprint small. Deployed
  via kagent's own `MCPServer` CRD, the same pattern as kagent's
  documented `mcp-server-fetch` example.
- **Gate 4** (`k8s/kyverno-policy.yaml`) is real Kubernetes admission
  control, not a simulation. It denies `UPDATE`/`DELETE` on any
  `Pod`/`Deployment` labeled `env=prod` unless the resource *already
  carried* the `demo.io/approved-by` annotation **before** the request,
  and is scoped to only gate the agent's own ServiceAccount identity, not
  every identity on the cluster.
- `demo/render_response.py` renders the result: after each run, it walks
  the agent's complete task history and prints every tool call with its
  real output, labeled by which gate it is, then a scorecard of what was
  allowed and denied.

## Configuration

All configuration lives in `.env` (copy it from `.env.example`):

| Variable | Purpose |
|---|---|
| `LLM_MODEL`, `OPENROUTER_API_KEY` | The agent's LLM provider, via OpenRouter |
| `KUBE_CONTEXT` | kubectl context to target; defaults to your current one |
| `NAMESPACE_PREFIX` | Prefix for every namespace/resource this repo creates |
| `JAEGER_LOCAL_PORT` | Local port for the Jaeger UI |
| `LOCAL_REGISTRY` | Docker registry to push the retrieval image to |
| `MILVUS_DB_PATH` | Where the seeded runbook database lives |
| `APPROVAL_ANNOTATION_KEY` | The annotation Gate 4 checks for |

## Cleanup

`scripts/teardown.sh` removes everything this repo created (namespaces,
the Kyverno policy, the Agent/MCPServer, Jaeger) but **leaves kagent and
Kyverno installed** -- it doesn't assume it's the only thing depending on
them. The script prints the manual commands to remove those fully if you
want a clean cluster.

