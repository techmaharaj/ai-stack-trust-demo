#!/usr/bin/env bash
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
KUBE_CTX="${KUBE_CONTEXT:-}"
[[ -z "$KUBE_CTX" ]] && KUBE_CTX="$(kubectl config current-context)"

log_step "1/5 Agent + MCPServer (Gate 2 + Gate 3)"
kubectl --context "$KUBE_CTX" delete agent trust-demo-agent -n kagent --ignore-not-found
kubectl --context "$KUBE_CTX" delete mcpserver runbook-search -n kagent --ignore-not-found

log_step "2/5 Kyverno policy (Gate 4)"
kubectl --context "$KUBE_CTX" delete clusterpolicy "${NAMESPACE_PREFIX}-prod-approval-gate" --ignore-not-found

log_step "3/5 Jaeger"
if helm status jaeger -n "${NAMESPACE_PREFIX}-observability" --kube-context "$KUBE_CTX" >/dev/null 2>&1; then
  helm uninstall jaeger -n "${NAMESPACE_PREFIX}-observability" --kube-context "$KUBE_CTX"
fi

log_step "4/5 Namespaces + checkout-service"
for ns in "${NAMESPACE_PREFIX}-staging" "${NAMESPACE_PREFIX}-observability"; do
  if kubectl --context "$KUBE_CTX" get ns "$ns" >/dev/null 2>&1; then
    owner="$(kubectl --context "$KUBE_CTX" get ns "$ns" -o jsonpath='{.metadata.labels.demo\.io/managed-by}' 2>/dev/null || true)"
    if [[ "$owner" == "ai-stack-trust-demo" ]]; then
      kubectl --context "$KUBE_CTX" delete namespace "$ns"
    else
      log_warn "namespace '$ns' isn't labeled demo.io/managed-by=ai-stack-trust-demo -- skipping (not ours)"
    fi
  fi
done

log_step "5/5 kagent and Kyverno itself"
log_warn "kagent (namespace 'kagent') and Kyverno were left installed -- this repo"
log_warn "doesn't assume it's the only thing using them. To remove kagent fully:"
log_warn "  helm uninstall kagent kagent-crds -n kagent && kubectl delete ns kagent"
log_warn "Kyverno was pre-existing on this cluster when this repo was first used --"
log_warn "not touched by teardown."

log_info "teardown complete."
