#!/usr/bin/env bash
# Auth helper — CHẠY TRÊN HOST. Đăng nhập z8l + cursor-agent vào sandbox HOME đã mount.
#
# z8l SSO redirect về 127.0.0.1 nên KHÔNG login được trong container. Cách làm:
# login trên host với HOME=$SANDBOX → file credential nằm trong sandbox, mà sandbox
# được mount làm HOME của container → container dùng lại credential đó.
#
# Idempotent + non-fatal: đã auth thì skip; lỗi chỉ cảnh báo, không làm hỏng bootstrap.
#
# Usage:
#   SANDBOX=~/ai-counter-sandbox ./sandbox/auth.sh
#   ./sandbox/auth.sh /path/to/sandbox
#
# Env:
#   BOOTSTRAP_SKIP_AUTH=1   bỏ qua hoàn toàn
set -uo pipefail   # KHÔNG dùng -e: auth là best-effort, không được abort caller

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="${1:-${SANDBOX:-}}"

if [[ -z "$SANDBOX" ]]; then
  echo "auth: thiếu SANDBOX. Usage: SANDBOX=~/sandbox $0" >&2
  exit 0
fi
if ! SANDBOX="$(cd "$SANDBOX" 2>/dev/null && pwd)"; then
  echo "auth: không tìm thấy sandbox: ${1:-$SANDBOX}" >&2
  exit 0
fi

if [[ "${BOOTSTRAP_SKIP_AUTH:-0}" == "1" ]]; then
  echo "auth: bỏ qua (BOOTSTRAP_SKIP_AUTH=1)"
  exit 0
fi

_interactive() { [[ -t 0 && -t 1 ]]; }

_resolve_z8l() {
  if [[ -x "$SANDBOX/bin/z8l" ]]; then echo "$SANDBOX/bin/z8l"; return 0; fi
  if [[ -x "$REPO_ROOT/bin/z8l" ]]; then echo "$REPO_ROOT/bin/z8l"; return 0; fi
  command -v z8l 2>/dev/null
}

auth_z8l() {
  local z8l token host_token
  z8l="$(_resolve_z8l)"
  token="$SANDBOX/.z8l/cli/supabase-auth.json"

  if [[ -z "$z8l" ]]; then
    echo "z8l: không tìm thấy binary — bỏ qua (chạy scripts/vendor-z8l.sh)"
    return
  fi

  # 1. Đã auth trong sandbox?
  if HOME="$SANDBOX" "$z8l" auth status >/dev/null 2>&1; then
    echo "z8l: đã đăng nhập (sandbox) ✓"
    return
  fi

  # 2. Tái dùng token sẵn có trên host
  host_token="$HOME/.z8l/cli/supabase-auth.json"
  if [[ -f "$host_token" ]]; then
    mkdir -p "$SANDBOX/.z8l/cli"
    cp "$host_token" "$token" && chmod 600 "$token"
    echo "z8l: đã copy token từ host → $token ✓"
    return
  fi

  # 3. Login interactive trên host (HOME=$SANDBOX) → token rơi vào sandbox đã mount
  if _interactive; then
    echo "z8l: mở trình duyệt đăng nhập (HOME=$SANDBOX)…"
    if HOME="$SANDBOX" "$z8l" auth login; then
      echo "z8l: đăng nhập ok ✓"
    else
      echo "z8l: đăng nhập thất bại — chạy lại 'make login' sau"
    fi
    return
  fi

  echo "z8l: chưa auth và không có terminal — chạy 'make login' trên host sau"
}

# cursor-agent CLI auth headless dựa trên CURSOR_API_KEY (Cursor docs khuyến nghị cho
# automation/CI). Login interactive KHÔNG chuyển được host(macOS)→container(Linux):
# token CLI nằm ở keychain/path riêng theo OS, không portable qua sandbox HOME.
# Lưu ý: `cursor-agent status` trả exit 0 cả khi "Not logged in" → phải parse output.
_cursor_logged_in() {
  local cursor="$1" out
  out="$(HOME="$SANDBOX" "$cursor" status 2>&1)"
  grep -qi "logged in" <<<"$out" && ! grep -qi "not logged in" <<<"$out"
}

auth_cursor() {
  local cursor
  cursor="$(command -v cursor-agent 2>/dev/null)"

  # 1. Có API key trong env → cách dùng cho headless/cron (truyền vào container khi 'make up')
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    echo "cursor: dùng CURSOR_API_KEY (truyền vào container khi 'make up'/'make daily') ✓"
    return
  fi

  # 2. Có token CLI sẵn trong sandbox? (parse output, không tin exit code)
  if [[ -n "$cursor" ]] && _cursor_logged_in "$cursor"; then
    echo "cursor: đã đăng nhập CLI (sandbox) ✓"
    return
  fi

  # 3. Chưa có → hướng dẫn API key (đáng tin nhất cho setup container headless)
  echo "cursor: CHƯA auth. Khuyến nghị dùng API key (headless):"
  echo "        1) Lấy key: cursor.com → Dashboard → Integrations → API Keys"
  echo "        2) export CURSOR_API_KEY=...   rồi   make up   (key vào container)"
  echo "        (Login interactive không chuyển được macOS→container; xem 'make cursor-login' nếu muốn thử.)"
}

echo "── Auth (host → sandbox: $SANDBOX) ──"
auth_z8l
auth_cursor
echo "──"
