#!/usr/bin/env bash
# Resolve TZ and configure container clock display + cron timezone.
# Priority: TZ env > ai-counter/config.yaml schedule.timezone > /etc/timezone > UTC
set -euo pipefail

COUNTER_HOME="${COUNTER_HOME:-/home/counter}"

_resolve_tz_from_config() {
  local cfg="$COUNTER_HOME/ai-counter/config.yaml"
  [[ -f "$cfg" ]] || return 1
  /opt/ai-counter/.venv/bin/python -c "
import sys
from pathlib import Path
import yaml
raw = yaml.safe_load(Path(sys.argv[1]).read_text(encoding='utf-8')) or {}
tz = (raw.get('schedule') or {}).get('timezone', '')
print(str(tz).strip())
" "$cfg" 2>/dev/null || return 1
}

if [[ -n "${TZ:-}" ]]; then
  RESOLVED_TZ="$TZ"
elif cfg_tz="$(_resolve_tz_from_config)" && [[ -n "$cfg_tz" ]]; then
  RESOLVED_TZ="$cfg_tz"
elif [[ -f /etc/timezone ]] && read -r file_tz </etc/timezone && [[ -n "$file_tz" ]]; then
  RESOLVED_TZ="$file_tz"
else
  RESOLVED_TZ="UTC"
fi

export TZ="$RESOLVED_TZ"

if [[ -f "/usr/share/zoneinfo/$RESOLVED_TZ" ]]; then
  ln -sf "/usr/share/zoneinfo/$RESOLVED_TZ" /etc/localtime
  echo "$RESOLVED_TZ" > /etc/timezone
fi

echo "Timezone: TZ=$RESOLVED_TZ ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
