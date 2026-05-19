# shellcheck shell=bash
# Source repo .env (if present). Idempotent — safe to source multiple times.
_load_env_repo_root="${_load_env_repo_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [[ -z "${_AI_COUNTER_ENV_LOADED:-}" ]]; then
  _AI_COUNTER_ENV_LOADED=1
  if [[ -f "$_load_env_repo_root/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$_load_env_repo_root/.env"
    set +a
  fi
fi

export SANDBOX="${SANDBOX:-$HOME/.sandbox-ai-counter}"
export NAME="${NAME:-ai-counter}"
export IMAGE="${IMAGE:-ai-counter:latest}"
