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

chown_sandbox() {
  echo "==> chown sandbox (uid 1000)"
  if ! "$ROOT/scripts/chown-sandbox.sh" "$SANDBOX" 2>/dev/null; then
    sudo "$ROOT/scripts/chown-sandbox.sh" "$SANDBOX"
  fi
}

image_exists() {
  "$RUNTIME_BIN" image exists "$AI_COUNTER_IMAGE" >/dev/null 2>&1
}

build_image() {
  local attempt max_attempts=3
  echo "==> Build image $AI_COUNTER_IMAGE ($RUNTIME_BIN)"
  export AI_COUNTER_RUNTIME="$RUNTIME_BIN" AI_COUNTER_IMAGE="$AI_COUNTER_IMAGE"

  for attempt in $(seq 1 "$max_attempts"); do
    if "$ROOT/docker/build.sh"; then
      if image_exists; then
        echo "==> Image ready: $AI_COUNTER_IMAGE"
        return 0
      fi
      echo "WARN: build finished but image not listed yet (attempt $attempt/$max_attempts)" >&2
    else
      echo "WARN: build failed (attempt $attempt/$max_attempts)" >&2
    fi
    [[ "$attempt" -lt "$max_attempts" ]] && sleep 2
  done

  echo "ERROR: failed to build $AI_COUNTER_IMAGE after $max_attempts attempts" >&2
  exit 1
}

z8l_authenticated() {
  [[ -f "$SANDBOX/.z8l/cli/supabase-auth.json" ]] && return 0
  HOME="$SANDBOX" "$ROOT/bin/z8l" auth status 2>/dev/null | grep -qi 'logged in'
}

cursor_authenticated() {
  container_running || return 1
  local out
  out="$("$RUNTIME_BIN" exec -u counter "$AI_COUNTER_CONTAINER_NAME" \
    cursor-agent status 2>/dev/null)" || return 1
  [[ "$out" != *"Not logged in"* ]] && echo "$out" | grep -qi 'logged in'
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
    echo "==> z8l: đã đăng nhập (sandbox)"
    return 0
  fi

  if copy_z8l_auth_to_sandbox; then
    chown -R 1000:1000 "$SANDBOX/.z8l" 2>/dev/null \
      || sudo chown -R 1000:1000 "$SANDBOX/.z8l" 2>/dev/null \
      || true
    if z8l_authenticated; then
      echo "==> z8l: đã copy credential từ host → $SANDBOX/.z8l/cli/"
      return 0
    fi
  fi

  if [[ ! -t 0 ]]; then
    echo "WARN: z8l chưa login — cần TTY. Chạy trên host:" >&2
    echo "       $ROOT/bin/z8l auth login" >&2
    echo "       rồi: cp ~/.z8l/cli/supabase-auth.json $SANDBOX/.z8l/cli/" >&2
    return 1
  fi

  echo "==> z8l: đăng nhập trên host (browser, HOME=$HOME)..."
  if ! "$ROOT/bin/z8l" auth login; then
    echo "WARN: z8l auth login thất bại" >&2
    return 1
  fi

  if ! copy_z8l_auth_to_sandbox; then
    echo "WARN: không tìm thấy ~/.z8l/cli/supabase-auth.json sau login" >&2
    return 1
  fi

  chown -R 1000:1000 "$SANDBOX/.z8l" 2>/dev/null \
    || sudo chown -R 1000:1000 "$SANDBOX/.z8l" 2>/dev/null \
    || true

  if z8l_authenticated; then
    echo "==> z8l: OK (credential trong $SANDBOX/.z8l/cli/)"
    return 0
  fi

  echo "WARN: z8l auth status vẫn chưa logged in trong sandbox" >&2
  return 1
}

setup_cursor_auth() {
  if ! container_running; then
    echo "WARN: container chưa chạy — bỏ qua cursor-agent login" >&2
    return 1
  fi

  if cursor_authenticated; then
    echo "==> cursor-agent: đã đăng nhập"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "WARN: cursor-agent login cần TTY (-it). Chạy:" >&2
    echo "       $RUNTIME_BIN exec -u counter -it $AI_COUNTER_CONTAINER_NAME cursor-agent login" >&2
    return 1
  fi

  echo "==> cursor-agent: đăng nhập trong container (browser)..."
  if "$RUNTIME_BIN" exec -u counter -it "$AI_COUNTER_CONTAINER_NAME" cursor-agent login; then
    if cursor_authenticated; then
      echo "==> cursor-agent: OK"
      return 0
    fi
  fi

  echo "WARN: cursor-agent chưa authenticated — chạy lại lệnh exec ở trên" >&2
  return 1
}

setup_credentials() {
  echo ""
  echo "==> Thiết lập credential (z8l trên host → sandbox, cursor trong container)"
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
  echo "  Cài đặt xong — việc cần làm tiếp"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "Đã thiết lập:"
  echo "  • Repo:       $ROOT"
  echo "  • Sandbox:    $SANDBOX"
  echo "                (trong container: /home/counter)"
  echo "  • Image:      $AI_COUNTER_IMAGE"
  if [[ "$container_up" -eq 1 ]]; then
    echo "  • Container:  $AI_COUNTER_CONTAINER_NAME — đang chạy ($RUNTIME_BIN)"
  elif [[ "$DO_START" -eq 0 ]]; then
    echo "  • Container:  chưa start (bạn dùng --no-start)"
  else
    echo "  • Container:  $AI_COUNTER_CONTAINER_NAME — chưa chạy"
  fi
  [[ "$SKIP_SKILLS" -eq 1 ]] && echo "  • Skills:     chưa cài (--skip-skills)"
  echo ""
  echo "── Auth ─────────────────────────────────────────────────────"
  if [[ "$z8l_ok" -eq 1 ]]; then
    echo "  ✓ z8l (sandbox: $SANDBOX/.z8l/cli/)"
  else
    cat <<EOF
  • z8l (host → copy vào sandbox):
      $ROOT/bin/z8l auth login
      cp ~/.z8l/cli/supabase-auth.json $SANDBOX/.z8l/cli/

EOF
  fi

  if [[ "$cursor_ok" -eq 1 ]]; then
    echo "  ✓ cursor-agent (trong container)"
  elif [[ "$container_up" -eq 1 ]]; then
    echo "  • cursor-agent:"
    echo "      $RUNTIME_BIN exec -u counter -it $AI_COUNTER_CONTAINER_NAME cursor-agent login"
  fi

  if [[ "$container_up" -eq 0 ]]; then
    cat <<EOF
  • Khởi động container:
      $ROOT/install.sh

EOF
  fi

  echo "── Cấu hình project ─────────────────────────────────────────"
  if _configured_projects; then
    echo "  ✓ Đã có project trong $SANDBOX/ai-counter/config.yaml"
    echo "    Thêm repo: clone vào $SANDBOX/projects/<tên> rồi sửa config."
  else
    cat <<EOF
  • Clone repo thật vào sandbox:
      git clone <url> $SANDBOX/projects/my-app
  • Khai báo trong $SANDBOX/ai-counter/config.yaml:
      sandbox:
        projects:
          - name: my-app
            conversations_per_day: 4
  • Prompts (sửa không cần rebuild image):
      $SANDBOX/ai-counter/prompts/daily.yaml

EOF
  fi

  if [[ "$SKIP_SKILLS" -eq 1 ]]; then
    echo "  • Cài agent skills (đã bỏ lúc cài):"
    echo "      SANDBOX=$SANDBOX $ROOT/scripts/install-sandbox-skills.sh"
    echo ""
  fi

  echo "── Kiểm tra ─────────────────────────────────────────────────"
  cat <<EOF
  • Doctor:    $ROOT/scripts/doctor.sh
EOF
  if [[ "$container_up" -eq 1 ]]; then
    if [[ "$dry_run_ok" -eq 1 ]]; then
      echo "  • Dry-run:   OK"
    elif [[ "$z8l_ok" -eq 0 ]] || ! _configured_projects; then
      echo "  • Dry-run:   (sau khi z8l login + thêm project)"
      echo "               $RUNTIME_BIN exec -u counter $AI_COUNTER_CONTAINER_NAME \\"
      echo "                 /opt/ai-counter/docker/run-daily.sh --dry-run"
    else
      echo "  • Dry-run:   thất bại — chạy doctor ở trên"
    fi
  fi
  echo ""
  echo "── Dùng hàng ngày ───────────────────────────────────────────"
  cat <<EOF
  • Cron tự động: T2–T6 06:30 (Asia/Ho_Chi_Minh)
  • Chạy tay:     $RUNTIME_BIN exec -u counter $AI_COUNTER_CONTAINER_NAME \\
                    /opt/ai-counter/docker/run-daily.sh
  • Log:          tail -f $SANDBOX/ai-counter/logs/daily-*.log
                  tail -f $SANDBOX/ai-counter/logs/cron.log
  • Cập nhật:     curl -fsSL https://raw.githubusercontent.com/magiskboy/ai-counter/main/install.sh | bash
════════════════════════════════════════════════════════════
EOF
}

start_container() {
  echo "==> Start container $AI_COUNTER_CONTAINER_NAME"
  export SANDBOX NAME="$AI_COUNTER_CONTAINER_NAME" IMAGE="$AI_COUNTER_IMAGE"

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
        echo "WARN: dry-run thất bại — xem hướng dẫn cuối script" >&2
      fi
    fi
  fi
fi

print_next_steps "$z8l_ok" "$cursor_ok" "$container_up" "$dry_run_ok"
