#!/usr/bin/env bash
set -euo pipefail

COUNTER_USER="${COUNTER_USER:-counter}"
COUNTER_HOME="${COUNTER_HOME:-/home/counter}"
COUNTER_UID="${COUNTER_UID:-$(id -u "$COUNTER_USER" 2>/dev/null || echo 1000)}"
COUNTER_GID="${COUNTER_GID:-$(id -g "$COUNTER_USER" 2>/dev/null || echo 1000)}"

export HOME="$COUNTER_HOME"
export COUNTER_HOME="$HOME"

if [[ ! -d "$HOME" ]]; then
  echo "ERROR: HOME directory does not exist: $HOME" >&2
  echo "  Mount sandbox: -v \$SANDBOX:$COUNTER_HOME" >&2
  exit 1
fi

if ! gosu "$COUNTER_USER" test -w "$HOME"; then
  echo "ERROR: $HOME is not writable by $COUNTER_USER (uid $COUNTER_UID)" >&2
  echo "  On host: chown -R ${COUNTER_UID}:${COUNTER_GID} \$SANDBOX" >&2
  echo "  Or run: ./scripts/chown-sandbox.sh \$SANDBOX" >&2
  echo "  Rootless Podman: add --userns=keep-id to podman run" >&2
  exit 1
fi

gosu "$COUNTER_USER" mkdir -p "$HOME/ai-counter/logs"

# Fixed TZ: Asia/Ho_Chi_Minh (cron + logs)
# shellcheck source=/opt/ai-counter/docker/setup-timezone.sh
source /opt/ai-counter/docker/setup-timezone.sh

if [[ ! -f "$HOME/ai-counter/config.yaml" ]]; then
  echo "WARNING: $HOME/ai-counter/config.yaml missing." >&2
  echo "  Run ./install.sh on the host and mount the sandbox volume." >&2
fi
if [[ ! -f "$HOME/ai-counter/prompts/daily.yaml" ]]; then
  echo "WARNING: $HOME/ai-counter/prompts/daily.yaml missing." >&2
  echo "  Prompts are read from the mounted sandbox at runtime (not baked into the image)." >&2
fi

echo "AI-counter container ready."
echo "  user=$COUNTER_USER uid=$COUNTER_UID HOME=$HOME"
echo "  CLIs: $(command -v specstory) $(command -v cursor-agent) $(command -v z8l)"
gosu "$COUNTER_USER" specstory version 2>/dev/null || gosu "$COUNTER_USER" specstory --version 2>/dev/null || true
gosu "$COUNTER_USER" cursor-agent --version 2>/dev/null || true
gosu "$COUNTER_USER" z8l version 2>/dev/null || gosu "$COUNTER_USER" z8l --version 2>/dev/null || true

echo ""
echo "First-time credentials (stored under mounted sandbox HOME):"
echo "  z8l:    HOME=\$SANDBOX ./bin/z8l auth login   # on host (not in container)"
echo "          or cp ~/.z8l/cli/supabase-auth.json -> \$SANDBOX/.z8l/cli/"
echo "  cursor: podman exec -u $COUNTER_USER -it ai-counter cursor-agent login"
echo "  MCP:    -e CONTEXT7_API_KEY=... (for .cursor/mcp.json)"
echo "  config/prompts: edit \$SANDBOX/ai-counter/ on host — picked up on next daily run (no rebuild)"
echo "  See README.md for full setup steps."
echo ""
echo "  Verify: podman exec -u $COUNTER_USER ai-counter z8l auth status"
echo ""
echo "Schedule: Mon-Fri 06:30 Asia/Ho_Chi_Minh (runs as $COUNTER_USER)"
echo "Manual:   podman exec -u $COUNTER_USER ai-counter /opt/ai-counter/docker/run-daily.sh"
echo "Dry-run:  podman exec -u $COUNTER_USER ai-counter /opt/ai-counter/docker/run-daily.sh --dry-run"
echo "Shell:    podman exec -u $COUNTER_USER -it ai-counter bash"

cp /opt/ai-counter/docker/crontab /etc/cron.d/ai-counter
chmod 0644 /etc/cron.d/ai-counter

exec cron -f
