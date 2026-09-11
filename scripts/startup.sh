#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source scripts/lib/common.sh

bash scripts/preflight.sh

set -a
source .env
set +a
: "${NAMESPACE_PREFIX:=ai-trust-demo}"
: "${APPROVAL_ANNOTATION_KEY:=demo.io/approved-by}"
: "${LLM_MODEL:=openrouter/free}"
KUBE_CTX="${KUBE_CONTEXT:-}"
[[ -z "$KUBE_CTX" ]] && KUBE_CTX="$(kubectl config current-context)"
export NAMESPACE_PREFIX APPROVAL_ANNOTATION_KEY

mkdir -p .demo-state

log_step "1/8 Namespaces"
render_template k8s/namespaces.yaml | kubectl --context "$KUBE_CTX" apply -f -

log_step "2/8 checkout-service (crashloop fixture)"
render_template k8s/checkout-service.yaml | kubectl --context "$KUBE_CTX" apply -f -

log_step "3/8 Kyverno policy (Gate 4)"
if ! kubectl --context "$KUBE_CTX" get ns kyverno >/dev/null 2>&1; then
  log_error "Kyverno is not installed on this cluster. This repo does not install"
  log_error "Kyverno itself (it's a heavier, cluster-wide dependency) -- install it"
  log_error "first per https://kyverno.io/docs/installation/ then re-run this script."
  exit 1
fi
render_template k8s/kyverno-policy.yaml | kubectl --context "$KUBE_CTX" apply -f -

log_step "4/8 kagent"
if ! kubectl --context "$KUBE_CTX" get ns kagent >/dev/null 2>&1; then
  helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
    --namespace kagent --create-namespace --kube-context "$KUBE_CTX"
fi
if ! kubectl --context "$KUBE_CTX" get secret kagent-openai -n kagent >/dev/null 2>&1; then
  kubectl --context "$KUBE_CTX" create secret generic kagent-openai -n kagent \
    --from-literal=OPENAI_API_KEY="$OPENROUTER_API_KEY"
fi
if ! helm status kagent -n kagent --kube-context "$KUBE_CTX" >/dev/null 2>&1; then
  # Slim install: only kagent-tools (Gate 1's built-in Kubernetes MCP tools)
  # and one agent. Grafana MCP, the 9 unused pre-built agents, and the UI
  # are all dropped -- verified 2026-09-11 this holds steady on a
  # memory-constrained node. Bring the UI back with:
  #   kubectl scale deployment kagent-ui -n kagent --replicas=1
  helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
    --namespace kagent --kube-context "$KUBE_CTX" \
    --set providers.default=openAI \
    --set providers.openAI.apiKeySecretRef=kagent-openai \
    --set providers.openAI.apiKeySecretKey=OPENAI_API_KEY \
    --set providers.openAI.model="$LLM_MODEL" \
    --set grafana-mcp.enabled=false \
    --set ui.replicas=0 \
    --set argo-rollouts-agent.enabled=false \
    --set cilium-debug-agent.enabled=false \
    --set cilium-manager-agent.enabled=false \
    --set cilium-policy-agent.enabled=false \
    --set helm-agent.enabled=false \
    --set istio-agent.enabled=false \
    --set kgateway-agent.enabled=false \
    --set observability-agent.enabled=false \
    --set promql-agent.enabled=false \
    --set kagent-tools.otel.tracing.enabled=true \
    --set kagent-tools.otel.tracing.exporter.otlp.endpoint="$OTEL_COLLECTOR_ENDPOINT" \
    --set kagent-tools.otel.tracing.exporter.otlp.insecure=true \
    --timeout 8m
fi
# GOTCHA (found 2026-09-11): the chart's providers.openAI.baseUrl values
# key is NOT wired into the ModelConfig template -- setting it via --set
# is silently ignored. The baseUrl has to be patched onto the ModelConfig
# object directly, per kagent's own BYO-OpenAI-compatible-provider doc.
log_info "patching ModelConfig baseUrl to OpenRouter (chart doesn't wire this through --set)"
kubectl --context "$KUBE_CTX" patch modelconfig default-model-config -n kagent \
  --type=merge -p '{"spec":{"openAI":{"baseUrl":"https://openrouter.ai/api/v1"}}}'

log_step "5/8 Jaeger (Gate 4 trace backend)"
if ! helm status jaeger -n "${NAMESPACE_PREFIX}-observability" --kube-context "$KUBE_CTX" >/dev/null 2>&1; then
  helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update jaegertracing >/dev/null 2>&1 || true
  helm install jaeger jaegertracing/jaeger \
    --namespace "${NAMESPACE_PREFIX}-observability" --kube-context "$KUBE_CTX" \
    -f k8s/observability/jaeger-values.yaml
fi

log_step "6/8 Build + push runbook-search image (Gate 2)"
REGISTRY_NODEPORT="$(kubectl --context "$KUBE_CTX" get svc docker-registry -n registry \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
NODE_IP="$(kubectl --context "$KUBE_CTX" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [[ -z "$REGISTRY_NODEPORT" ]]; then
  log_error "no in-cluster docker-registry service found. Either point LOCAL_REGISTRY"
  log_error "in .env at a registry you already have, or install one first."
  exit 1
fi
export LOCAL_REGISTRY="${NODE_IP}:${REGISTRY_NODEPORT}"
log_info "using registry: $LOCAL_REGISTRY"
docker build -t "${LOCAL_REGISTRY}/ai-stack-trust-demo/runbook-search:latest" ./retrieval
docker push "${LOCAL_REGISTRY}/ai-stack-trust-demo/runbook-search:latest"

log_step "7/8 MCPServer + Agent (Gate 2 + Gate 3)"
render_template kagent/mcpserver-milvus.yaml | kubectl --context "$KUBE_CTX" apply -f -
kubectl --context "$KUBE_CTX" apply -f kagent/agent.yaml

log_step "8/8 Waiting for everything to be Ready"
kubectl --context "$KUBE_CTX" wait --for=condition=Ready pod -l app.kubernetes.io/instance=kagent -n kagent --timeout=300s || true
kubectl --context "$KUBE_CTX" wait --for=condition=Accepted agent/trust-demo-agent -n kagent --timeout=120s || true

log_info "startup complete. Next: bash demo/run_demo.sh"
log_info "kagent UI: kubectl scale deployment kagent-ui -n kagent --replicas=1"
log_info "           kubectl port-forward service/kagent-ui 8080:8080 -n kagent"
log_info "Jaeger UI: kubectl port-forward svc/jaeger-query -n ${NAMESPACE_PREFIX}-observability ${JAEGER_LOCAL_PORT:-16686}:16686"
