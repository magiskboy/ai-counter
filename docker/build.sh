#!/usr/bin/env bash
# Build ai-counter image (z8l vendored in bin/z8l).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/host-ids.sh
source "$ROOT/scripts/lib/host-ids.sh"
readonly PLATFORM="${AI_COUNTER_PLATFORM:-linux/amd64}"
readonly IMAGE="${AI_COUNTER_IMAGE:-ai-counter:latest}"

if [[ ! -f bin/z8l ]]; then
  echo "Missing bin/z8l. Run: ./scripts/vendor-z8l.sh" >&2
  exit 1
fi
chmod +x bin/z8l 2>/dev/null || true
if [[ ! -x bin/z8l ]]; then
  echo "bin/z8l is not executable (try: chmod +x bin/z8l)" >&2
  exit 1
fi

RUNTIME="${AI_COUNTER_RUNTIME:-}"
if [[ -z "$RUNTIME" ]]; then
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
  else
    echo "ERROR: Install Podman or Docker first." >&2
    exit 1
  fi
fi

echo "Building with counter uid:gid=${COUNTER_UID}:${COUNTER_GID} (host $(id -un 2>/dev/null || echo '?'))"
"$RUNTIME" build \
  --platform "$PLATFORM" \
  --build-arg "COUNTER_UID=${COUNTER_UID}" \
  --build-arg "COUNTER_GID=${COUNTER_GID}" \
  -f docker/Dockerfile \
  -t "$IMAGE" \
  .
echo "Built $IMAGE (runtime=$RUNTIME platform=$PLATFORM uid:gid=${COUNTER_UID}:${COUNTER_GID})"
