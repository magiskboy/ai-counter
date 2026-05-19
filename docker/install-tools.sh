#!/usr/bin/env bash
# Install SpecStory CLI and Cursor Agent CLI into /usr/local/bin.
# z8l is vendored in bin/z8l and copied in the Dockerfile.
set -euo pipefail

SPECSTORY_VERSION="${SPECSTORY_VERSION:-v1.12.0}"

echo "==> Installing SpecStory CLI ${SPECSTORY_VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SPECSTORY_ASSET="SpecStoryCLI_Linux_x86_64.tar.gz"
curl -fsSL \
  "https://github.com/specstoryai/getspecstory/releases/download/${SPECSTORY_VERSION}/${SPECSTORY_ASSET}" \
  | tar -xz -C "$TMP"
install -m 755 "$TMP/specstory" /usr/local/bin/specstory
specstory --version || specstory version || true

echo "==> Installing Cursor Agent CLI"
curl -fsSL https://cursor.com/install | bash
agent_bin=""
for dir in "${HOME}/.local/bin" /root/.local/bin; do
  if [[ -x "${dir}/cursor-agent" ]]; then
    agent_bin="${dir}/cursor-agent"
    break
  fi
  if [[ -x "${dir}/agent" ]]; then
    agent_bin="${dir}/agent"
    break
  fi
done
if [[ -z "${agent_bin}" ]]; then
  echo "ERROR: cursor-agent not found after install (HOME=${HOME})" >&2
  exit 1
fi

# Install under /opt so non-root user `counter` can execute (not only via /root/.local)
resolved="$(readlink -f "${agent_bin}")"
version_dir="$(dirname "$resolved")"
CURSOR_SHARE="/root/.local/share/cursor-agent"

if [[ -d "${CURSOR_SHARE}/versions" ]]; then
  rm -rf /opt/cursor-agent
  cp -a "${CURSOR_SHARE}" /opt/cursor-agent
  VERSION="$(ls -1 /opt/cursor-agent/versions | head -1)"
  ln -sf "/opt/cursor-agent/versions/${VERSION}/cursor-agent" /usr/local/bin/cursor-agent
  chmod -R a+rX /opt/cursor-agent
elif [[ -x "$resolved" ]]; then
  rm -rf /opt/cursor-agent
  install -d -m 755 /opt/cursor-agent/versions
  VERSION="$(basename "$version_dir")"
  cp -a "$version_dir" "/opt/cursor-agent/versions/${VERSION}"
  ln -sf "/opt/cursor-agent/versions/${VERSION}/cursor-agent" /usr/local/bin/cursor-agent
  chmod -R a+rX /opt/cursor-agent
else
  ln -sf "${agent_bin}" /usr/local/bin/cursor-agent
  chmod -R a+rX /root/.local/share/cursor-agent /root/.local/bin 2>/dev/null || true
fi
/usr/local/bin/cursor-agent --version

echo "==> CLI tools installed:"
ls -la /usr/local/bin/specstory /usr/local/bin/cursor-agent
