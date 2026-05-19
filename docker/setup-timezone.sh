#!/usr/bin/env bash
# Fixed timezone for cron and logs (Vietnam).
set -euo pipefail

readonly AI_COUNTER_TZ="Asia/Ho_Chi_Minh"

export TZ="$AI_COUNTER_TZ"
if [[ -f "/usr/share/zoneinfo/$AI_COUNTER_TZ" ]]; then
  ln -sf "/usr/share/zoneinfo/$AI_COUNTER_TZ" /etc/localtime
  echo "$AI_COUNTER_TZ" > /etc/timezone
fi

echo "Timezone: $AI_COUNTER_TZ ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
