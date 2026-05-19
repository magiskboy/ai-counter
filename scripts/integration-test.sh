#!/usr/bin/env bash
# Integration test: bootstrap sandbox-test, dry-run locally, optional Docker dry-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SANDBOX="${SANDBOX:-$ROOT/sandbox-test}"

echo "==> Bootstrap sandbox-test"
SANDBOX="$SANDBOX" ./sandbox/bootstrap.sh
./scripts/chown-sandbox.sh "$SANDBOX" 2>/dev/null || true

# Minimal config: 1 project, 2 conversations, 2 user messages each
cat > "$SANDBOX/ai-counter/config.yaml" <<EOF
automation:
  user_messages_per_conversation: 2
  delay_between_messages_seconds: 1
  delay_between_conversations_seconds: 2

sandbox:
  projects_dir: projects
  projects:
    - name: fake-api
      conversations_per_day: 2

cursor:
  binary: cursor-agent
  flags: ["-p", "--trust", "-f", "--approve-mcps"]
  timeout_seconds: 900
  delay_between_sessions: 2

z8l:
  binary: $ROOT/bin/z8l
  sync_provider: cursor

prompts:
  file: $ROOT/prompts/daily.yaml
  rotate: daily
EOF

echo "==> Local dry-run"
HOME="$SANDBOX" uv run ai-counter daily --dry-run

if command -v docker >/dev/null 2>&1; then
  echo "==> Docker build"
  if [[ ! -x bin/z8l ]]; then
    echo "Skip Docker build: bin/z8l missing (run ./scripts/vendor-z8l.sh)" >&2
  else
    docker build -f docker/Dockerfile -t ai-counter:latest .
  fi

  if docker image inspect ai-counter:latest >/dev/null 2>&1; then
    echo "==> Docker dry-run"
    docker run --rm \
      --user counter \
      --entrypoint /opt/ai-counter/docker/run-daily.sh \
      -v "$SANDBOX:/home/counter" \
      -e HOME=/home/counter \
      ai-counter:latest \
      --dry-run
  fi
else
  echo "==> Skipping Docker (docker not installed)"
fi

echo "==> Integration test passed"
