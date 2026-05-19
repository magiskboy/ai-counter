#!/usr/bin/env bash
# Build ai-counter image (z8l vendored in bin/z8l).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
readonly PLATFORM="${AI_COUNTER_PLATFORM:-linux/amd64}"

if [[ ! -x bin/z8l ]]; then
  echo "Missing bin/z8l. Run: ./scripts/vendor-z8l.sh" >&2
  exit 1
fi

if command -v podman >/dev/null 2>&1; then
  podman build --platform "$PLATFORM" -f docker/Dockerfile -t ai-counter:latest .
else
  docker build --platform "$PLATFORM" -f docker/Dockerfile -t ai-counter:latest .
fi
echo "Built ai-counter:latest (platform=$PLATFORM)"
