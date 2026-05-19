#!/usr/bin/env bash
# One-line install (fixed paths, no .env):
#
#   curl -fsSL https://raw.githubusercontent.com/magiskboy/ai-counter/main/install.sh | bash
#
# Or: ./install.sh
#
# Layout: repo ~/.ai-counter | sandbox ~/.sandbox-ai-counter | container ai-counter

set -euo pipefail

# --- hardcoded profile ---
readonly AI_COUNTER_REPO_URL="${AI_COUNTER_REPO_URL:-https://github.com/magiskboy/ai-counter.git}"
readonly AI_COUNTER_REF="${AI_COUNTER_REF:-main}"
readonly AI_COUNTER_INSTALL_DIR="${AI_COUNTER_INSTALL_DIR:-$HOME/.ai-counter}"
readonly AI_COUNTER_SANDBOX="${AI_COUNTER_SANDBOX:-$HOME/.sandbox-ai-counter}"
readonly AI_COUNTER_CONTAINER_NAME="${AI_COUNTER_CONTAINER_NAME:-ai-counter}"
readonly AI_COUNTER_IMAGE="${AI_COUNTER_IMAGE:-ai-counter:latest}"
readonly SANDBOX_SEED="${AI_COUNTER_SANDBOX_SEED:-sandbox}"
# ---

DO_START=1
SKIP_CLONE=0
SKIP_SKILLS=0
SKIP_BUILD=0
SKIP_AUTH=0
REPLACE_CONTAINER=1
RUNTIME="auto"

ROOT=""
SANDBOX=""
RUNTIME_BIN=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Install AI-counter (no .env). Paths: ~/.ai-counter, ~/.sandbox-ai-counter.

Options:
  --no-start       do not start container
  --skip-clone     use existing ~/.ai-counter checkout
  --skip-build     skip image build
  --skip-skills    skip npx agent skills
  --skip-auth      skip z8l + cursor-agent login after container start
  --runtime auto|docker|podman
  -h, --help

  curl -fsSL https://raw.githubusercontent.com/magiskboy/ai-counter/main/install.sh | bash
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) DO_START=0; shift ;;
    --skip-clone) SKIP_CLONE=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-skills) SKIP_SKILLS=1; shift ;;
    --skip-auth) SKIP_AUTH=1; shift ;;
    --runtime)
      RUNTIME="${2:?--runtime requires docker|podman|auto}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found." >&2
    exit 1
  }
}

resolve_local_root() {
  local script="${BASH_SOURCE[0]:-}"
  [[ -n "$script" && "$script" != "-" && -f "$script" ]] || return 1
  local dir
  dir="$(cd "$(dirname "$script")" && pwd)"
  [[ -f "$dir/bin/z8l" && -f "$dir/docker/build.sh" ]] || return 1
  printf '%s\n' "$dir"
}

# curl | bash runs from stdin — re-exec from cloned repo so build/scripts use a real path.
should_reexec_from_clone() {
  [[ "${AI_COUNTER_INSTALL_REEXEC:-}" == 1 ]] && return 1
  [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" ]] && return 1
  return 0
}

ensure_repo_checkout() {
  local root="$1"
  local missing=0
  for rel in bin/z8l docker/build.sh docker/Dockerfile; do
    if [[ ! -e "$root/$rel" ]]; then
      echo "ERROR: incomplete checkout, missing $rel" >&2
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    echo "==> Repair checkout in $root"
    git -C "$root" checkout -f HEAD
  fi
  if [[ -f "$root/bin/z8l" ]]; then
    chmod +x "$root/bin/z8l"
  fi
  [[ -x "$root/bin/z8l" ]] || {
    echo "ERROR: $root/bin/z8l is missing or not executable" >&2
    exit 1
  }
}

clone_or_update_repo() {
  need_cmd git
  if [[ -d "$AI_COUNTER_INSTALL_DIR/.git" ]]; then
    echo "==> Update repo: $AI_COUNTER_INSTALL_DIR"
    git -C "$AI_COUNTER_INSTALL_DIR" fetch --depth 1 origin "$AI_COUNTER_REF"
    git -C "$AI_COUNTER_INSTALL_DIR" checkout -q "$AI_COUNTER_REF" 2>/dev/null \
      || git -C "$AI_COUNTER_INSTALL_DIR" checkout -q "origin/$AI_COUNTER_REF"
    git -C "$AI_COUNTER_INSTALL_DIR" reset --hard "origin/$AI_COUNTER_REF"
  else
    echo "==> Clone repo → $AI_COUNTER_INSTALL_DIR"
    rm -rf "$AI_COUNTER_INSTALL_DIR"
    git clone --depth 1 --branch "$AI_COUNTER_REF" "$AI_COUNTER_REPO_URL" "$AI_COUNTER_INSTALL_DIR"
  fi
}

detect_runtime() {
  case "$RUNTIME" in
    auto)
      if command -v podman >/dev/null 2>&1; then echo podman
      elif command -v docker >/dev/null 2>&1; then echo docker
      else echo ""
      fi
      ;;
    docker|podman) echo "$RUNTIME" ;;
    *)
      echo "Invalid --runtime: $RUNTIME" >&2
      exit 1
      ;;
  esac
}

bootstrap_sandbox() {
  local repo="$1"
  local box="$2"
  local seed="$repo/$SANDBOX_SEED"

  mkdir -p "$box"
  box="$(cd "$box" && pwd)"
  echo "==> Seed sandbox: $box"

  mkdir -p \
    "$box/ai-counter/logs" \
    "$box/projects" \
    "$box/.z8l/cli" \
    "$box/.config/ai-counter" \
    "$box/bin"

  if [[ ! -f "$box/ai-counter/config.yaml" ]]; then
    cp "$seed/ai-counter/config.yaml" "$box/ai-counter/config.yaml"
    echo "    seeded ai-counter/config.yaml"
  fi
  if [[ ! -f "$box/ai-counter/prompts/daily.yaml" ]]; then
    mkdir -p "$box/ai-counter/prompts"
    cp "$seed/ai-counter/prompts/daily.yaml" "$box/ai-counter/prompts/daily.yaml"
    echo "    seeded ai-counter/prompts/daily.yaml"
  fi

  mkdir -p "$box/.cursor"
  if [[ ! -f "$box/.cursor/mcp.json" ]]; then
    cp "$seed/.cursor/mcp.json" "$box/.cursor/mcp.json"
    echo "    seeded .cursor/mcp.json"
  fi
  if [[ ! -f "$box/.cursor/cli-config.json" ]]; then
    cp "$seed/.cursor/cli-config.json" "$box/.cursor/cli-config.json"
    echo "    seeded .cursor/cli-config.json"
  fi

  if [[ -x "$repo/bin/z8l" ]] && [[ ! -f "$box/bin/z8l" ]]; then
    cp "$repo/bin/z8l" "$box/bin/z8l"
    chmod +x "$box/bin/z8l"
  fi

  if [[ ! -f "$box/.z8l/cli/config.toml" ]] && [[ -f "${HOME}/.z8l/cli/config.toml" ]]; then
    cp "${HOME}/.z8l/cli/config.toml" "$box/.z8l/cli/config.toml"
  fi

  SANDBOX="$box"
}

install_sandbox_skills() {
  if [[ "$SKIP_SKILLS" -eq 1 ]]; then
    echo "==> Skipped agent skills (--skip-skills)"
    return 0
  fi
  if ! command -v npx >/dev/null 2>&1; then
    echo "==> Skipped agent skills (npx not found)"
    return 0
  fi
  echo "==> Install agent skills (after image build)"
  SANDBOX="$SANDBOX" "$ROOT/scripts/install-sandbox-skills.sh" "$SANDBOX" || {
    echo "WARN: skill install failed — rerun: SANDBOX=$SANDBOX $ROOT/scripts/install-sandbox-skills.sh" >&2
  }
}

chown_sandbox_path() {
  local path="$1"
  chown -R "${COUNTER_UID}:${COUNTER_GID}" "$path" 2>/dev/null \
    || sudo chown -R "${COUNTER_UID}:${COUNTER_GID}" "$path"
}

chown_sandbox() {
  echo "==> chown sandbox (uid:gid ${COUNTER_UID}:${COUNTER_GID})"
  export COUNTER_UID COUNTER_GID
  if ! "$ROOT/scripts/chown-sandbox.sh" "$SANDBOX" 2>/dev/null; then
    sudo env COUNTER_UID="$COUNTER_UID" COUNTER_GID="$COUNTER_GID" \
      "$ROOT/scripts/chown-sandbox.sh" "$SANDBOX"
  fi
}

image_exists() {
  runtime_image_exists "$RUNTIME_BIN" "$AI_COUNTER_IMAGE"
}

build_image() {
  local attempt max_attempts=3
  echo "==> Build image $AI_COUNTER_IMAGE ($RUNTIME_BIN)"

  for attempt in $(seq 1 "$max_attempts"); do
    if env \
      AI_COUNTER_RUNTIME="$RUNTIME_BIN" \
      AI_COUNTER_IMAGE="$AI_COUNTER_IMAGE" \
      COUNTER_UID="$COUNTER_UID" \
      COUNTER_GID="$COUNTER_GID" \
      "$ROOT/docker/build.sh"; then
      if image_exists; then
        echo "==> Image ready: $AI_COUNTER_IMAGE"
        return 0
      fi
      echo "WARN: build OK but image not visible yet (attempt $attempt/$max_attempts)" >&2
    else
      echo "WARN: build failed (attempt $attempt/$max_attempts)" >&2
    fi
    [[ "$attempt" -lt "$max_attempts" ]] && sleep 2
  done

  if image_exists; then
    echo "==> Image ready: $AI_COUNTER_IMAGE"
    return 0
  fi

  echo "ERROR: failed to build or find $AI_COUNTER_IMAGE after $max_attempts attempts" >&2
  echo "       Check: $RUNTIME_BIN images $AI_COUNTER_IMAGE" >&2
  exit 1
}

# Avoid false positive: "Not logged in" also contains "logged in".
_cli_status_logged_in() {
  local out="$1"
  local low="${out,,}"
  [[ "$low" == *"not logged in"* ]] && return 1
  [[ "$low" == *"logged in"* || "$low" == *"authenticated"* ]]
}

have_interactive_tty() {
  [[ -t 0 ]] && return 0
  [[ -r /dev/tty && -w /dev/tty ]]
}

run_interactive() {
  if [[ -t 0 ]]; then
    "$@"
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    "$@" </dev/tty >/dev/tty 2>&1
  else
    return 1
  fi
}

wait_for_container() {
  local i
  for i in $(seq 1 15); do
    container_running && return 0
    sleep 1
  done
  return 1
}

z8l_authenticated() {
  [[ -f "$SANDBOX/.z8l/cli/supabase-auth.json" ]] && return 0
  local out
  out="$(HOME="$SANDBOX" "$ROOT/bin/z8l" auth status 2>/dev/null)" || return 1
  _cli_status_logged_in "$out"
}

cursor_authenticated() {
  container_running || return 1
  local out
  out="$("$RUNTIME_BIN" exec -u counter "$AI_COUNTER_CONTAINER_NAME" \
    cursor-agent status 2>/dev/null)" || return 1
  _cli_status_logged_in "$out"
}

# Copy z8l session from host ~/.z8l into mounted sandbox HOME.
copy_z8l_auth_to_sandbox() {
  local host_cli="${HOME}/.z8l/cli"
  local copied=0
  mkdir -p "$SANDBOX/.z8l/cli"
  for f in supabase-auth.json auth.json config.toml; do
    if [[ -f "$host_cli/$f" ]]; then
      cp -a "$host_cli/$f" "$SANDBOX/.z8l/cli/"
      copied=1
    fi
  done
  [[ "$copied" -eq 1 ]]
}

setup_z8l_auth() {
  if z8l_authenticated; then
    echo "==> z8l: logged in (sandbox)"
    return 0
  fi

  if copy_z8l_auth_to_sandbox; then
    chown_sandbox_path "$SANDBOX/.z8l" || true
    if z8l_authenticated; then
      echo "==> z8l: copied host credentials → $SANDBOX/.z8l/cli/"
      return 0
    fi
  fi

  if ! have_interactive_tty; then
    echo "WARN: z8l not logged in — needs TTY. Run:" >&2
    echo "       HOME=$SANDBOX $ROOT/bin/z8l auth login" >&2
    return 1
  fi

  echo "==> z8l: login (browser, HOME=$SANDBOX)..."
  if ! run_interactive env HOME="$SANDBOX" "$ROOT/bin/z8l" auth login; then
    echo "WARN: z8l auth login failed" >&2
    return 1
  fi

  chown_sandbox_path "$SANDBOX/.z8l" || true

  if z8l_authenticated; then
    echo "==> z8l: OK ($SANDBOX/.z8l/cli/)"
    return 0
  fi

  echo "WARN: z8l still not logged in in sandbox" >&2
  return 1
}

setup_cursor_auth() {
  if ! wait_for_container; then
    echo "WARN: container not ready — skipping cursor-agent login" >&2
    return 1
  fi

  if cursor_authenticated; then
    echo "==> cursor-agent: logged in"
    return 0
  fi

  if ! have_interactive_tty; then
    echo "WARN: cursor-agent login needs TTY (-it). Run:" >&2
    echo "       $RUNTIME_BIN exec -u counter -it $AI_COUNTER_CONTAINER_NAME cursor-agent login" >&2
    return 1
  fi

  echo "==> cursor-agent: login in container (browser)..."
  if run_interactive "$RUNTIME_BIN" exec -u counter -it "$AI_COUNTER_CONTAINER_NAME" \
    cursor-agent login; then
    if cursor_authenticated; then
      echo "==> cursor-agent: OK"
      return 0
    fi
  fi

  echo "WARN: cursor-agent not authenticated — rerun exec above" >&2
  return 1
}

setup_credentials() {
  echo ""
  echo "==> Credentials (z8l + cursor-agent after container start)"
  setup_z8l_auth || true
  setup_cursor_auth || true
}

container_exists() {
  "$RUNTIME_BIN" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$AI_COUNTER_CONTAINER_NAME"
}

container_running() {
  "$RUNTIME_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AI_COUNTER_CONTAINER_NAME"
}

_configured_projects() {
  [[ -f "$SANDBOX/ai-counter/config.yaml" ]] &&
    grep -Eq '^[[:space:]]+-[[:space:]]+name:[[:space:]]*[^#[:space:]]' "$SANDBOX/ai-counter/config.yaml"
}

print_next_steps() {
  local z8l_ok=$1
  local cursor_ok=$2
  local container_up=$3
  local dry_run_ok=$4

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Install complete — next steps"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "Configured:"
  echo "  • Repo:       $ROOT"
  echo "  • Sandbox:    $SANDBOX"
  echo "                (in container: /home/counter)"
  echo "  • Image:      $AI_COUNTER_IMAGE"
  if [[ "$container_up" -eq 1 ]]; then
    echo "  • Container:  $AI_COUNTER_CONTAINER_NAME — running ($RUNTIME_BIN)"
  elif [[ "$DO_START" -eq 0 ]]; then
    echo "  • Container:  not started (--no-start)"
  else
    echo "  • Container:  $AI_COUNTER_CONTAINER_NAME — not running"
  fi
  [[ "$SKIP_SKILLS" -eq 1 ]] && echo "  • Skills:     skipped (--skip-skills)"
  echo ""
  echo "── Auth ─────────────────────────────────────────────────────"
  if [[ "$z8l_ok" -eq 1 ]]; then
    echo "  ✓ z8l (sandbox: $SANDBOX/.z8l/cli/)"
  else
    cat <<EOF
  • z8l (sandbox HOME):
      HOME=$SANDBOX $ROOT/bin/z8l auth login

EOF
  fi

  if [[ "$cursor_ok" -eq 1 ]]; then
    echo "  ✓ cursor-agent (in container)"
  elif [[ "$container_up" -eq 1 ]]; then
    echo "  • cursor-agent:"
    echo "      $RUNTIME_BIN exec -u counter -it $AI_COUNTER_CONTAINER_NAME cursor-agent login"
  fi

  if [[ "$container_up" -eq 0 ]]; then
    cat <<EOF
  • Start container:
      $ROOT/install.sh

EOF
  fi

  echo "── Projects ─────────────────────────────────────────────────"
  if _configured_projects; then
    echo "  ✓ Projects in $SANDBOX/ai-counter/config.yaml"
    echo "    Add more: clone to $SANDBOX/projects/<name> and edit config."
  else
    cat <<EOF
  • Clone into sandbox:
      git clone <url> $SANDBOX/projects/my-app
  • Add to $SANDBOX/ai-counter/config.yaml:
      sandbox:
        projects:
          - name: my-app
            conversations_per_day: 4
  • Prompts (no image rebuild):
      $SANDBOX/ai-counter/prompts/daily.yaml

EOF
  fi

  if [[ "$SKIP_SKILLS" -eq 1 ]]; then
    echo "  • Agent skills (skipped during install):"
    echo "      SANDBOX=$SANDBOX $ROOT/scripts/install-sandbox-skills.sh"
    echo ""
  fi

  echo "── Verify ───────────────────────────────────────────────────"
  cat <<EOF
  • Doctor:    $ROOT/scripts/doctor.sh
EOF
  if [[ "$container_up" -eq 1 ]]; then
    if [[ "$dry_run_ok" -eq 1 ]]; then
      echo "  • Dry-run:   OK"
    elif [[ "$z8l_ok" -eq 0 ]] || ! _configured_projects; then
      echo "  • Dry-run:   (after z8l login + add project)"
      echo "               $RUNTIME_BIN exec -u counter $AI_COUNTER_CONTAINER_NAME \\"
      echo "                 /opt/ai-counter/docker/run-daily.sh --dry-run"
    else
      echo "  • Dry-run:   failed — run doctor above"
    fi
  fi
  echo ""
  echo "── Daily use ────────────────────────────────────────────────"
  cat <<EOF
  • Cron: Mon–Fri 06:30 (Asia/Ho_Chi_Minh)
  • Manual: $RUNTIME_BIN exec -u counter $AI_COUNTER_CONTAINER_NAME \\
              /opt/ai-counter/docker/run-daily.sh
  • Logs:   tail -f $SANDBOX/ai-counter/logs/daily-*.log
            tail -f $SANDBOX/ai-counter/logs/cron.log
  • Update: curl -fsSL https://raw.githubusercontent.com/magiskboy/ai-counter/main/install.sh | bash
════════════════════════════════════════════════════════════
EOF
}

start_container() {
  echo "==> Start container $AI_COUNTER_CONTAINER_NAME"
  export SANDBOX NAME="$AI_COUNTER_CONTAINER_NAME" IMAGE="$AI_COUNTER_IMAGE"
  export COUNTER_UID COUNTER_GID

  if container_exists; then
    if [[ "$REPLACE_CONTAINER" -eq 1 ]]; then
      "$RUNTIME_BIN" rm -f "$AI_COUNTER_CONTAINER_NAME" >/dev/null 2>&1 || true
    elif container_running; then
      echo "    already running"
      return 0
    else
      "$RUNTIME_BIN" start "$AI_COUNTER_CONTAINER_NAME" >/dev/null
      return 0
    fi
  fi

  if ! container_running; then
    SANDBOX="$SANDBOX" NAME="$AI_COUNTER_CONTAINER_NAME" IMAGE="$AI_COUNTER_IMAGE" \
      "$ROOT/scripts/podman-run.sh"
  fi
}

# --- main ---
echo "==> AI-counter install"
echo "    repo:      $AI_COUNTER_INSTALL_DIR"
echo "    sandbox:   $AI_COUNTER_SANDBOX"
echo "    container: $AI_COUNTER_CONTAINER_NAME"
echo ""

need_cmd git
RUNTIME_BIN="$(detect_runtime)"
[[ -n "$RUNTIME_BIN" ]] || {
  echo "ERROR: Install Podman or Docker first." >&2
  exit 1
}

if ROOT="$(resolve_local_root 2>/dev/null)"; then
  echo "==> Using repo: $ROOT"
elif [[ "$SKIP_CLONE" -eq 1 ]]; then
  ROOT="$AI_COUNTER_INSTALL_DIR"
else
  clone_or_update_repo
  ROOT="$AI_COUNTER_INSTALL_DIR"
fi

ensure_repo_checkout "$ROOT"

if should_reexec_from_clone; then
  echo "==> Re-run install from $ROOT/install.sh (curl | bash)"
  export AI_COUNTER_INSTALL_REEXEC=1
  exec /usr/bin/env bash "$ROOT/install.sh" "$@"
fi

# shellcheck source=scripts/lib/host-ids.sh
source "$ROOT/scripts/lib/host-ids.sh"
# shellcheck source=scripts/lib/image.sh
source "$ROOT/scripts/lib/image.sh"
echo "    counter uid:gid: ${COUNTER_UID}:${COUNTER_GID} (host $(id -un))"

bootstrap_sandbox "$ROOT" "$AI_COUNTER_SANDBOX"
chown_sandbox

[[ "$SKIP_BUILD" -eq 0 ]] && build_image || echo "==> Skipped image build"

install_sandbox_skills

z8l_ok=0
cursor_ok=0
container_up=0
dry_run_ok=0

if [[ "$DO_START" -eq 1 ]]; then
  start_container
  if container_running; then
    container_up=1
    if [[ "$SKIP_AUTH" -eq 0 ]]; then
      setup_credentials
    else
      echo "==> Skipped credential setup (--skip-auth)"
    fi
    z8l_authenticated && z8l_ok=1
    cursor_authenticated && cursor_ok=1
    if [[ "$z8l_ok" -eq 1 ]] && _configured_projects; then
      echo "==> Verify dry-run"
      if "$RUNTIME_BIN" exec -u counter "$AI_COUNTER_CONTAINER_NAME" \
        /opt/ai-counter/docker/run-daily.sh --dry-run; then
        dry_run_ok=1
      else
        echo "WARN: dry-run failed — see next-steps below" >&2
      fi
    fi
  fi
fi

print_next_steps "$z8l_ok" "$cursor_ok" "$container_up" "$dry_run_ok"
