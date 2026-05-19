#!/usr/bin/env bash
# Integration test: bootstrap sandbox-test, dry-run locally, optional Docker dry-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SANDBOX="${SANDBOX:-$ROOT/sandbox-test}"

echo "==> Bootstrap sandbox-test"
AI_COUNTER_SANDBOX="$SANDBOX" ./install.sh --skip-clone --no-start --skip-build --skip-skills

mkdir -p "$SANDBOX/projects/test-app"
if [[ ! -d "$SANDBOX/projects/test-app/.git" ]]; then
  echo "# test" > "$SANDBOX/projects/test-app/README.md"
  git -C "$SANDBOX/projects/test-app" init -q
  git -C "$SANDBOX/projects/test-app" add README.md
  git -C "$SANDBOX/projects/test-app" -c user.email="test@local" -c user.name="Test" commit -q -m "init"
fi

# Minimal config: 1 project, 2 conversations, 2 user messages each
cat > "$SANDBOX/ai-counter/config.yaml" <<EOF
automation:
  user_messages_per_conversation: 2
  delay_between_messages_seconds: 1
  delay_between_conversations_seconds: 2

sandbox:
  projects_dir: projects
  projects:
    - name: test-app
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
  file: ai-counter/prompts/daily.yaml
  rotate: daily
EOF

echo "==> Local dry-run"
HOME="$SANDBOX" uv run ai-counter daily --dry-run

if command -v docker >/dev/null 2>&1; then
  echo "==> Docker build"
  if [[ ! -x bin/z8l ]]; then
    echo "Skip Docker build: bin/z8l missing (run ./scripts/vendor-z8l.sh)" >&2
  else
    docker build --platform linux/amd64 -f docker/Dockerfile -t ai-counter:latest .
  fi

  if docker image inspect ai-counter:latest >/dev/null 2>&1; then
    echo "==> Docker dry-run"
    docker run --rm \
      --platform linux/amd64 \
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
