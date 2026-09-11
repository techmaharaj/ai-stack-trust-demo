#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source scripts/lib/common.sh

log_step "1/5 Checking local tooling"
missing=0
for cmd in kubectl helm python3 pip3 curl docker envsubst; do
  require_cmd "$cmd" || missing=1
done
if [[ "$missing" -eq 1 ]]; then
  log_error "install the missing command(s) above and re-run this script"
  exit 1
fi
log_info "kubectl, helm, python3, pip3, curl, docker all present"

log_step "2/5 Loading .env"
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    log_warn "created .env from .env.example -- fill in OPENROUTER_API_KEY before continuing"
  else
    log_error ".env.example missing, cannot bootstrap .env"
    exit 1
  fi
fi
set -a
source .env
set +a
: "${NAMESPACE_PREFIX:=ai-trust-demo}"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  read -r -s -p "OPENROUTER_API_KEY (not shown): " OPENROUTER_API_KEY
  echo
  if [[ -z "$OPENROUTER_API_KEY" ]]; then
    log_error "OPENROUTER_API_KEY is required"
    exit 1
  fi
  # append, don't overwrite the rest of .env
  sed -i.bak "s#^OPENROUTER_API_KEY=.*#OPENROUTER_API_KEY=${OPENROUTER_API_KEY}#" .env && rm -f .env.bak
fi

log_step "3/5 Checking cluster reachability"
KUBE_CTX="${KUBE_CONTEXT:-}"
[[ -z "$KUBE_CTX" ]] && KUBE_CTX="$(kubectl config current-context)"
if ! kubectl --context "$KUBE_CTX" cluster-info >/dev/null 2>&1; then
  log_error "cannot reach the cluster for context '$KUBE_CTX' -- check your kubeconfig"
  exit 1
fi
log_info "target kube context: $KUBE_CTX"

log_step "4/5 Checking node memory headroom"
if command -v free >/dev/null 2>&1; then
  avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
  if [[ -n "$avail_mb" && "$avail_mb" -lt 800 ]]; then
    log_warn "only ${avail_mb}Mi available memory on this host -- kagent + Jaeger + the"
    log_warn "runbook-search MCP server need headroom. Consider pausing non-essential"
    log_warn "workloads first (see homelab-argocd-status.md in the parent talks folder"
    log_warn "for a worked example: scaling ArgoCD to zero freed ~500Mi)."
    if ! confirm "Continue anyway?"; then
      exit 1
    fi
  else
    log_info "${avail_mb}Mi available memory -- looks fine"
  fi
else
  log_warn "no 'free' command available (not Linux?) -- skipping memory check"
fi

log_step "5/5 Confirm before proceeding"
log_info "About to create/modify cluster-wide resources under namespace prefix '${NAMESPACE_PREFIX}':"
log_info "  - namespaces ${NAMESPACE_PREFIX}-staging, ${NAMESPACE_PREFIX}-observability"
log_info "  - a Kyverno ClusterPolicy (Kyverno itself must already be installed -- this repo does not install it)"
log_info "  - kagent (Helm, namespace 'kagent') if not already present"
log_info "  - a Jaeger all-in-one (Helm) in the observability namespace"
if ! confirm "Continue?"; then
  log_warn "aborted by user"
  exit 1
fi

log_info "preflight OK"
