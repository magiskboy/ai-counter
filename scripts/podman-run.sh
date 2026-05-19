#!/usr/bin/env bash
# Start ai-counter container (Podman or Docker).
set -euo pipefail

readonly AI_COUNTER_TZ="Asia/Ho_Chi_Minh"
readonly AI_COUNTER_PLATFORM="${AI_COUNTER_PLATFORM:-linux/amd64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$ROOT/scripts/lib/load-env.sh"
# shellcheck source=scripts/lib/host-ids.sh
source "$ROOT/scripts/lib/host-ids.sh"
SANDBOX="$(mkdir -p "$SANDBOX" && cd "$SANDBOX" && pwd)"

if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
  RUN_ARGS=(
    -d
    --platform "$AI_COUNTER_PLATFORM"
    --name "$NAME"
    --userns=keep-id
    --restart unless-stopped
    -e "TZ=$AI_COUNTER_TZ"
    -e "COUNTER_UID=$COUNTER_UID"
    -e "COUNTER_GID=$COUNTER_GID"
    -v "$SANDBOX:/home/counter:Z"
  )
else
  RUNTIME=docker
  RUN_ARGS=(
    -d
    --platform "$AI_COUNTER_PLATFORM"
    --name "$NAME"
    --restart unless-stopped
    -e "TZ=$AI_COUNTER_TZ"
    -e "COUNTER_UID=$COUNTER_UID"
    -e "COUNTER_GID=$COUNTER_GID"
    -v "$SANDBOX:/home/counter"
  )
fi

[[ -n "${CONTEXT7_API_KEY:-}" ]] && RUN_ARGS+=(-e CONTEXT7_API_KEY)

echo "Starting $NAME with $RUNTIME (platform=$AI_COUNTER_PLATFORM, TZ=$AI_COUNTER_TZ, uid:gid=${COUNTER_UID}:${COUNTER_GID}, sandbox=$SANDBOX)"
"$RUNTIME" run "${RUN_ARGS[@]}" "$IMAGE"
echo "Verify: $RUNTIME exec -u counter $NAME date"
