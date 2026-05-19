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
  [[ -n "$script" && -f "$script" ]] || return 1
  local dir
  dir="$(cd "$(dirname "$script")" && pwd)"
  [[ -x "$dir/bin/z8l" && -f "$dir/docker/build.sh" ]] || return 1
  printf '%s\n' "$dir"
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

  if [[ "$SKIP_SKILLS" -eq 1 ]]; then
    echo "    skipped agent skills (--skip-skills)"
  elif command -v npx >/dev/null 2>&1; then
    SANDBOX="$box" "$repo/scripts/install-sandbox-skills.sh" "$box" || {
      echo "WARN: skill install failed — rerun: SANDBOX=$box $repo/scripts/install-sandbox-skills.sh" >&2
    }
  else
    echo "    skipped agent skills (npx not found)"
  fi

  SANDBOX="$box"
}

chown_sandbox() {
  echo "==> chown sandbox (uid 1000)"
  if ! "$ROOT/scripts/chown-sandbox.sh" "$SANDBOX" 2>/dev/null; then
    sudo "$ROOT/scripts/chown-sandbox.sh" "$SANDBOX"
  fi
}

build_image() {
  echo "==> Build image $AI_COUNTER_IMAGE"
  "$ROOT/docker/build.sh"
}

z8l_authenticated() {
  [[ -f "$SANDBOX/.z8l/cli/supabase-auth.json" ]] && return 0
  HOME="$SANDBOX" "$ROOT/bin/z8l" auth status 2>/dev/null | grep -qi 'logged in'
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
  local container_up=$2
  local dry_run_ok=$3

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
  echo "── Một lần (auth) ───────────────────────────────────────────"

  local n=1
  if [[ "$z8l_ok" -eq 0 ]]; then
    cat <<EOF
  $n) z8l (trên HOST — cần browser):
       HOME=$SANDBOX $ROOT/bin/z8l auth login

EOF
    n=$((n + 1))
  else
    echo "  ✓ z8l đã đăng nhập"
  fi

  if [[ "$container_up" -eq 0 ]]; then
    cat <<EOF
  $n) Khởi động container:
       $ROOT/install.sh
       # hoặc: $ROOT/scripts/podman-run.sh

EOF
    n=$((n + 1))
  fi

  cat <<EOF
  $n) Cursor (trong container):
       $RUNTIME_BIN exec -u counter -it $AI_COUNTER_CONTAINER_NAME cursor-agent login

EOF

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
  [[ -x "$ROOT/bin/z8l" ]] || {
    echo "ERROR: incomplete checkout at $ROOT" >&2
    exit 1
  }
else
  clone_or_update_repo
  ROOT="$AI_COUNTER_INSTALL_DIR"
fi

[[ -x "$ROOT/bin/z8l" ]] || {
  echo "ERROR: missing $ROOT/bin/z8l — run ./scripts/vendor-z8l.sh" >&2
  exit 1
}

bootstrap_sandbox "$ROOT" "$AI_COUNTER_SANDBOX"
chown_sandbox

[[ "$SKIP_BUILD" -eq 0 ]] && build_image || echo "==> Skipped image build"

z8l_ok=0
if z8l_authenticated; then
  z8l_ok=1
  echo "==> z8l: authenticated"
else
  echo "==> z8l: chưa login (xem hướng dẫn cuối script)"
fi

container_up=0
dry_run_ok=0

if [[ "$DO_START" -eq 1 ]]; then
  start_container
  if container_running; then
    container_up=1
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

print_next_steps "$z8l_ok" "$container_up" "$dry_run_ok"
