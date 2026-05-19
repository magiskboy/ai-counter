#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/counter}"
export USER="${USER:-counter}"
export PATH="/opt/ai-counter/.venv/bin:/usr/local/bin:${PATH}"

cd /opt/ai-counter
exec /opt/ai-counter/.venv/bin/ai-counter daily "$@"
