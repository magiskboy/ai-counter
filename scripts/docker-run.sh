#!/usr/bin/env bash
# Start ai-counter container with Docker (host timezone sync).
set -euo pipefail

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
  --restart unless-stopped
  -e "TZ=$TZ"
  -v "$SANDBOX:/home/counter"
  -v /etc/localtime:/etc/localtime:ro
)

if [[ -f /etc/timezone ]]; then
  RUN_ARGS+=(-v /etc/timezone:/etc/timezone:ro)
fi

[[ -n "${CURSOR_API_KEY:-}" ]] && RUN_ARGS+=(-e CURSOR_API_KEY)
[[ -n "${CONTEXT7_API_KEY:-}" ]] && RUN_ARGS+=(-e CONTEXT7_API_KEY)

echo "Starting $NAME with Docker (TZ=$TZ, sandbox=$SANDBOX)"
docker run "${RUN_ARGS[@]}" "$IMAGE"
echo "Verify time: docker exec -u counter $NAME date"
