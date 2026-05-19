# shellcheck shell=bash
# Bash 3.2–safe helpers (macOS /bin/bash is 3.2 — no ${var,,}).

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}
