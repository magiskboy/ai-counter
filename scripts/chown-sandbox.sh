#!/usr/bin/env bash
# Set sandbox ownership for container user `counter` (default uid 1000).
set -euo pipefail

SANDBOX="${1:-}"
COUNTER_UID="${COUNTER_UID:-1000}"
COUNTER_GID="${COUNTER_GID:-1000}"

if [[ -z "$SANDBOX" ]]; then
  echo "Usage: $0 /path/to/sandbox" >&2
  echo "   or: SANDBOX=~/my-sandbox $0" >&2
  exit 1
fi

SANDBOX="$(cd "$SANDBOX" && pwd)"
echo "chown -R ${COUNTER_UID}:${COUNTER_GID} $SANDBOX"
chown -R "${COUNTER_UID}:${COUNTER_GID}" "$SANDBOX"
echo "Done. Mount with: -v $SANDBOX:/home/counter"
