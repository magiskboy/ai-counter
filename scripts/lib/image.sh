# shellcheck shell=bash
# Portable local image check (`docker image exists` requires Docker 23+).

runtime_image_exists() {
  local runtime="${1:?runtime}"
  local ref="${2:?image ref}"

  if "$runtime" image inspect "$ref" >/dev/null 2>&1; then
    return 0
  fi

  # Docker 23+ / Podman
  if "$runtime" image exists "$ref" >/dev/null 2>&1; then
    return 0
  fi

  local id
  id="$("$runtime" images -q "$ref" 2>/dev/null | head -1)"
  [[ -n "$id" ]]
}
