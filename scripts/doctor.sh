#!/usr/bin/env bash
# Host-side health checks before/after setup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/load-env.sh
source "$ROOT/scripts/lib/load-env.sh"

SANDBOX="$(mkdir -p "$SANDBOX" 2>/dev/null && cd "$SANDBOX" && pwd)" || SANDBOX="${SANDBOX:-}"

ERRORS=0
WARNINGS=0

ok() { echo "  OK  $*"; }
warn() { echo "  WARN $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "  FAIL $*"; ERRORS=$((ERRORS + 1)); }

detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    echo podman
  elif command -v docker >/dev/null 2>&1; then
    echo docker
  else
    echo ""
  fi
}

RUNTIME_BIN="$(detect_runtime)"

echo "AI-counter doctor"
echo "  repo:    $ROOT"
echo "  sandbox: $SANDBOX"
echo ""

echo "Prerequisites"
if [[ -n "$RUNTIME_BIN" ]]; then
  ok "container runtime: $RUNTIME_BIN"
else
  fail "no podman/docker found"
fi

if [[ -x "$ROOT/bin/z8l" ]]; then
  ok "bin/z8l present"
else
  fail "bin/z8l missing (./scripts/vendor-z8l.sh)"
fi

if [[ -f "$ROOT/.env" ]]; then
  ok ".env loaded"
else
  warn "no .env (optional: cp .env.example .env)"
fi

echo ""
echo "Sandbox"
if [[ -d "$SANDBOX" ]]; then
  ok "directory exists"
else
  fail "sandbox missing — run ./install.sh"
fi

if [[ -d "$SANDBOX" ]] && [[ -w "$SANDBOX" ]]; then
  ok "sandbox writable by current user"
else
  [[ -d "$SANDBOX" ]] && fail "sandbox not writable: $SANDBOX"
fi

for f in ai-counter/config.yaml ai-counter/prompts/daily.yaml .cursor/mcp.json .cursor/cli-config.json; do
  if [[ -f "$SANDBOX/$f" ]]; then
    ok "$f"
  else
    warn "missing $f (run ./install.sh)"
  fi
done

if [[ -d "$SANDBOX/projects" ]]; then
  ok "projects/ directory"
  proj_count=0
  while IFS= read -r -d '' d; do
    proj_count=$((proj_count + 1))
    name="$(basename "$d")"
    if [[ -d "$d/.git" ]]; then
      ok "projects/$name (git)"
    else
      warn "projects/$name exists but is not a git repo"
    fi
  done < <(find "$SANDBOX/projects" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  if [[ "$proj_count" -eq 0 ]]; then
    warn "no projects yet — clone repos into $SANDBOX/projects/ and edit ai-counter/config.yaml"
  fi
else
  warn "missing projects/ (run ./install.sh)"
fi

if [[ -d "$SANDBOX" ]] && [[ "$(stat -c '%u' "$SANDBOX" 2>/dev/null || echo '?')" == "1000" ]]; then
  ok "sandbox owned by uid 1000 (counter)"
else
  warn "sandbox not uid 1000 — run ./scripts/chown-sandbox.sh \"$SANDBOX\""
fi

echo ""
echo "z8l auth (host)"
if [[ -f "$SANDBOX/.z8l/cli/supabase-auth.json" ]]; then
  ok "supabase-auth.json in sandbox"
elif [[ -d "$SANDBOX" ]] && HOME="$SANDBOX" "$ROOT/bin/z8l" auth status 2>/dev/null | grep -qi 'logged in'; then
  ok "z8l auth status: logged in"
else
  fail "z8l not authenticated — HOME=$SANDBOX $ROOT/bin/z8l auth login"
fi

echo ""
echo "Image & container"
if [[ -n "$RUNTIME_BIN" ]] && "$RUNTIME_BIN" image exists "$IMAGE" >/dev/null 2>&1; then
  ok "image $IMAGE"
else
  fail "image $IMAGE not found — ./install.sh"
fi

if [[ -z "$RUNTIME_BIN" ]]; then
  warn "skipped container checks (no runtime)"
elif "$RUNTIME_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  ok "container $NAME running"
  if out="$("$RUNTIME_BIN" exec -u counter "$NAME" date 2>/dev/null)"; then
    ok "container date: $out"
  else
    warn "cannot exec into $NAME"
  fi
  if "$RUNTIME_BIN" exec -u counter "$NAME" z8l auth status 2>/dev/null | grep -qi 'logged in'; then
    ok "z8l auth inside container"
  else
    warn "z8l not logged in inside container (token may be missing on sandbox)"
  fi
  if "$RUNTIME_BIN" exec -u counter "$NAME" cursor-agent --version >/dev/null 2>&1; then
    ok "cursor-agent installed"
  else
    fail "cursor-agent not found in container"
  fi
else
  warn "container $NAME not running — ./install.sh"
fi

echo ""
if [[ "$ERRORS" -eq 0 ]] && [[ "$WARNINGS" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
fi

echo "Summary: $ERRORS error(s), $WARNINGS warning(s)"
[[ "$ERRORS" -eq 0 ]] && exit 0 || exit 1
