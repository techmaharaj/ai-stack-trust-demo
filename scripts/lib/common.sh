#!/usr/bin/env bash
# Shared logging + helper functions. Sourced by every scripts/*.sh file --
# never executed directly.

COLOR_RESET='\033[0m'
COLOR_BLUE='\033[34m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_RED='\033[31m'
COLOR_CYAN='\033[36m'
COLOR_BOLD='\033[1m'

log_step()  { printf "${COLOR_BOLD}${COLOR_BLUE}==> %s${COLOR_RESET}\n" "$*"; }
log_info()  { printf "${COLOR_GREEN}[info]${COLOR_RESET} %s\n" "$*"; }
log_warn()  { printf "${COLOR_YELLOW}[warn]${COLOR_RESET} %s\n" "$*"; }
log_error() { printf "${COLOR_RED}[error]${COLOR_RESET} %s\n" "$*" >&2; }

confirm() {
  local prompt="$1" reply
  read -r -p "$(printf "${COLOR_YELLOW}%s [type 'yes' to continue]: ${COLOR_RESET}" "$prompt")" reply
  [[ "$reply" == "yes" ]]
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "required command not found: $cmd"
    return 1
  fi
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# render_template <src-file> -- prints src with ${VAR} placeholders
# substituted from the current environment via envsubst. Caller pipes to
# `kubectl apply -f -` or redirects to a file.
render_template() {
  envsubst < "$1"
}
