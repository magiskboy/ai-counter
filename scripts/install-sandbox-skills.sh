#!/usr/bin/env bash
# Wrapper: install agent skills into sandbox HOME (non-interactive npx skills).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SANDBOX="${1:-${SANDBOX:-}}"
if [[ -z "$SANDBOX" ]]; then
  echo "Usage: SANDBOX=~/my-ai-sandbox $0"
  exit 1
fi

if [[ -x "$ROOT/.venv/bin/python" ]]; then
  exec "$ROOT/.venv/bin/python" "$ROOT/scripts/install_sandbox_skills.py" "$SANDBOX"
fi
exec uv run python "$ROOT/scripts/install_sandbox_skills.py" "$SANDBOX"
