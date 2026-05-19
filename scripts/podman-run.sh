#!/usr/bin/env bash
# Start ai-counter container with host timezone sync.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="${SANDBOX:-$HOME/ai-counter-sandbox}"
NAME="${NAME:-ai-counter}"
IMAGE="${IMAGE:-ai-counter:latest}"

if [[ -z "${TZ:-}" ]]; then
  if command -v timedatectl >/dev/null 2>&1; then
    TZ="$(timedatectl show -pTimezone --value 2>/dev/null || true)"
  fi
  if [[ -z "${TZ:-}" ]] && [[ -f /etc/timezone ]]; then
    TZ="$(tr -d '[:space:]' </etc/timezone)"
  fi
  TZ="${TZ:-UTC}"
fi
export TZ

RUN_ARGS=(
  -d
  --name "$NAME"
  --userns=keep-id
  --restart unless-stopped
  -e "TZ=$TZ"
  -v "$SANDBOX:/home/counter:Z"
  -v /etc/localtime:/etc/localtime:ro
)

if [[ -f /etc/timezone ]]; then
  RUN_ARGS+=(-v /etc/timezone:/etc/timezone:ro)
fi

[[ -n "${CURSOR_API_KEY:-}" ]] && RUN_ARGS+=(-e CURSOR_API_KEY)
[[ -n "${CONTEXT7_API_KEY:-}" ]] && RUN_ARGS+=(-e CONTEXT7_API_KEY)

echo "Starting $NAME (TZ=$TZ, sandbox=$SANDBOX)"

if command -v podman >/dev/null 2>&1; then
  podman run "${RUN_ARGS[@]}" "$IMAGE"
else
  docker run "${RUN_ARGS[@]}" "$IMAGE"
fi

echo "Verify time: podman exec -u counter $NAME date"
