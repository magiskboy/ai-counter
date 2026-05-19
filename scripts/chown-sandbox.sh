#!/usr/bin/env bash
# Set sandbox ownership for container user `counter` (host uid/gid by default).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/host-ids.sh
source "$ROOT/scripts/lib/host-ids.sh"

SANDBOX="${1:-}"

if [[ -z "$SANDBOX" ]]; then
  echo "Usage: $0 /path/to/sandbox" >&2
  echo "   or: SANDBOX=~/my-sandbox $0" >&2
  exit 1
fi

SANDBOX="$(cd "$SANDBOX" && pwd)"
echo "chown -R ${COUNTER_UID}:${COUNTER_GID} $SANDBOX"
chown -R "${COUNTER_UID}:${COUNTER_GID}" "$SANDBOX"
echo "Done. Mount with: -v $SANDBOX:/home/counter"
