#!/usr/bin/env bash
# Download z8l Linux x86_64 once into bin/z8l (vendored for Docker build).
#
# Usage:
#   ./scripts/vendor-z8l.sh
#   Z8L_DOWNLOAD_URL='https://.../z8l_Linux_x86_64.zip?token=...' ./scripts/vendor-z8l.sh
#
# After updating, commit bin/z8l and rebuild the image.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bin/z8l"
Z8L_DOWNLOAD_URL="${Z8L_DOWNLOAD_URL:-}"

if [[ -z "$Z8L_DOWNLOAD_URL" ]]; then
  echo "Set Z8L_DOWNLOAD_URL to the signed Supabase zip URL for z8l_Linux_x86_64.zip"
  echo "  export Z8L_DOWNLOAD_URL='https://uichywodzchdjmdtsqer.supabase.co/storage/v1/object/sign/cli-releases/v0.1.12/z8l_Linux_x86_64.zip?token=...'"
  exit 1
fi

command -v unzip >/dev/null || { echo "install unzip"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$ROOT/bin"
curl -fsSL "$Z8L_DOWNLOAD_URL" -o "$TMP/z8l.zip"
unzip -o "$TMP/z8l.zip" -d "$TMP"
install -m 755 "$TMP/z8l" "$OUT"
echo "Installed $OUT"
"$OUT" version 2>/dev/null || "$OUT" --version
