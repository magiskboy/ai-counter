# shellcheck shell=bash
# Container user `counter` uses the installing host user's uid/gid (bind-mount permissions).
# Override: COUNTER_UID=... COUNTER_GID=... install.sh

if [[ -z "${COUNTER_UID:-}" ]]; then
  COUNTER_UID="$(id -u)"
fi
if [[ -z "${COUNTER_GID:-}" ]]; then
  COUNTER_GID="$(id -g)"
fi
export COUNTER_UID COUNTER_GID
