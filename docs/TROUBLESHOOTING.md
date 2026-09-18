# Troubleshooting and known limitations

## Model and prompt behavior

- **Tool-calling reliability and response time both vary significantly by
  `LLM_MODEL`.** An auto-routed or under-powered model can be slow enough
  to make a live recording impractical, or undisciplined enough to keep
  retrying an already-denied action instead of reporting it.
- **The agent's system prompt (`kagent/agent.yaml`) explicitly forbids
  asking for permission before acting and retrying after a denial.**
  Without those instructions, a model may describe a fix instead of
  attempting it, or make several quick variations of a denied write
  instead of reporting the denial. Worth re-checking this behavior if you
  change `LLM_MODEL`.
- **`k8s_patch_resource` often returns a bare `exit status 1` to the
  model, without Kyverno's actual denial message**, even though the full
  message is always present in `kagent-tools`' own pod logs. Two things
  account for this: `demo/render_response.py` classifies a denied gate-4
  attempt by whether the tool reported an error at all (not by
  string-matching "denied" in the output text, which misses this case
  entirely), and `demo/run_demo.sh` separately pulls the real message
  from `kagent-tools`' log as an independent "ground truth" display,
  regardless of what the agent's own tool response contained.

## kagent and Helm

- **`helm --set providers.openAI.baseUrl=...` has no effect** on the
  kagent chart's `ModelConfig` template (v0.10.1). Set the base URL
  directly on the `ModelConfig` object instead -- `startup.sh` does this
  with a `kubectl patch` after install, per kagent's own
  [BYO OpenAI-compatible provider](https://kagent.dev/docs/kagent/supported-providers/byo-openai)
  doc.
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
- **`startup.sh`'s kagent step always reconciles (`helm upgrade
  --install`), rather than only installing if missing.** Gating config
  changes behind "only if not already installed" would mean they never
  apply on a cluster where kagent already exists.
- **Tracing the agent's own reasoning/LLM calls needs the chart-level
  `otel.tracing.enabled` Helm value, not a per-Agent env var.** A
  per-Agent `OTEL_TRACING_ENABLED` env var is overridden by a value the
  kagent controller appends afterward. `scripts/startup.sh` sets the
  chart-level value, which is separate from `kagent-tools.otel.tracing.*`
  (that one only covers tool-execution spans, not the model call itself).

## Kyverno policy

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

## Retrieval (Milvus Lite)

- **Milvus Lite's collection loads as `released` on every fresh process**,
  even when it was seeded and left loaded by a different process at
  image-build time. `retrieval/mcp_server.py` calls `load_collection()`
  explicitly at startup; without it, searches fail with "call load()
  before search/get/query".

## Networking and observability

- **`kubectl port-forward` does not follow a Service when its backing pod
  is replaced** -- it pins to the pod IP resolved at start time, so the
  tunnel breaks on any pod restart (a `helm upgrade`, or the Jaeger reset
  that happens at the start of every `demo/run_demo.sh` run).
  `scripts/port-forwards.sh` wraps both forwards in an auto-reconnect
  loop so this doesn't require manual intervention.
- **Jaeger's in-memory storage has no purge API.** The only way to clear
  old traces between runs is restarting its pod, which
  `demo/run_demo.sh` does at the start of every run for a clean trace
  view.

## General

- First-time image pulls for kagent's components can take several minutes
  on a bandwidth-constrained node; this is expected and only happens once.
