#!/usr/bin/env bash
# Bootstrap a host sandbox directory (mounted as HOME in the container).
#
# Usage:
#   export SANDBOX=~/my-ai-sandbox
#   ./sandbox/bootstrap.sh
#
# Or:
#   ./sandbox/bootstrap.sh /path/to/my-ai-sandbox

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="${1:-${SANDBOX:-}}"

if [[ -z "$SANDBOX" ]]; then
  echo "Usage: SANDBOX=~/my-ai-sandbox $0"
  echo "   or: $0 /path/to/sandbox"
  exit 1
fi

SANDBOX="$(cd "$SANDBOX" 2>/dev/null && pwd || mkdir -p "$SANDBOX" && cd "$SANDBOX" && pwd)"

echo "Bootstrapping sandbox at: $SANDBOX"

mkdir -p \
  "$SANDBOX/ai-counter/logs" \
  "$SANDBOX/projects" \
  "$SANDBOX/.z8l/cli" \
  "$SANDBOX/.config/ai-counter" \
  "$SANDBOX/bin"

# Orchestrator config
if [[ ! -f "$SANDBOX/ai-counter/config.yaml" ]]; then
  cp "$SCRIPT_DIR/config.example.yaml" "$SANDBOX/ai-counter/config.yaml"
  echo "Created ai-counter/config.yaml"
else
  echo "Skipped ai-counter/config.yaml (already exists)"
fi

# z8l binary (optional for host-only runs; Docker image installs /usr/local/bin/z8l)
if [[ -x "$REPO_ROOT/bin/z8l" ]] && [[ ! -f "$SANDBOX/bin/z8l" ]]; then
  cp "$REPO_ROOT/bin/z8l" "$SANDBOX/bin/z8l"
  chmod +x "$SANDBOX/bin/z8l"
  echo "Copied bin/z8l (host dev; container uses /usr/local/bin/z8l)"
fi

# Minimal z8l config if missing (user may overwrite after auth login)
if [[ ! -f "$SANDBOX/.z8l/cli/config.toml" ]] && [[ -f "$HOME/.z8l/cli/config.toml" ]]; then
  cp "$HOME/.z8l/cli/config.toml" "$SANDBOX/.z8l/cli/config.toml"
  echo "Copied ~/.z8l/cli/config.toml"
fi

create_fake_repo() {
  local name="$1"
  local dir="$SANDBOX/projects/$name"
  if [[ -d "$dir/.git" ]]; then
    echo "Skipped projects/$name (already exists)"
    return
  fi
  mkdir -p "$dir"
  cat > "$dir/README.md" <<EOF
# $name

Fake project for AI-counter sandbox automation.
EOF
  cat > "$dir/main.py" <<'EOF'
def main() -> None:
    print("hello from fake project")


if __name__ == "__main__":
    main()
EOF
  git -C "$dir" init -q
  git -C "$dir" add README.md main.py
  git -C "$dir" -c user.email="ai-counter@local" -c user.name="AI Counter" commit -q -m "init"
  echo "Created projects/$name"
}

create_fake_repo fake-api
create_fake_repo fake-web
create_fake_repo fake-lib

# Cursor CLI: MCP + permissions (auto-approve tools in headless runs)
mkdir -p "$SANDBOX/.cursor"
if [[ ! -f "$SANDBOX/.cursor/mcp.json" ]]; then
  cp "$SCRIPT_DIR/mcp.example.json" "$SANDBOX/.cursor/mcp.json"
  echo "Created .cursor/mcp.json (Context7 via CONTEXT7_API_KEY env)"
fi
if [[ ! -f "$SANDBOX/.cursor/cli-config.json" ]]; then
  cp "$SCRIPT_DIR/cursor-cli-config.example.json" "$SANDBOX/.cursor/cli-config.json"
  echo "Created .cursor/cli-config.json (Mcp/WebFetch allowlist)"
fi

# Agent skills (non-interactive: npx skills add ... -g -y -a cursor)
if command -v npx >/dev/null 2>&1; then
  echo "Installing agent skills into sandbox..."
  SANDBOX="$SANDBOX" "$REPO_ROOT/scripts/install-sandbox-skills.sh" "$SANDBOX" || {
    echo "WARNING: skill install failed (need Node.js + npx). Run later:" >&2
    echo "  SANDBOX=$SANDBOX $REPO_ROOT/scripts/install-sandbox-skills.sh" >&2
  }
else
  echo "Skipped agent skills (npx not found). Run after installing Node.js:"
  echo "  SANDBOX=$SANDBOX $REPO_ROOT/scripts/install-sandbox-skills.sh"
fi

cat <<EOF

Sandbox ready: $SANDBOX

Next steps:
  1. Edit $SANDBOX/.cursor/mcp.json (skills live in $SANDBOX/.agents/skills/)
  2. z8l auth ON HOST (OAuth needs browser on host, not in container):
       HOME=$SANDBOX $REPO_ROOT/bin/z8l auth login
       # or: cp ~/.z8l/cli/supabase-auth.json $SANDBOX/.z8l/cli/
  3. Build: ./docker/build.sh
  4. chown: ./scripts/chown-sandbox.sh $SANDBOX
  5. Run: podman run -d --userns=keep-id -v $SANDBOX:/home/counter \\
            -e CURSOR_API_KEY=... ai-counter:latest
  6. Full guide: README.md

EOF
