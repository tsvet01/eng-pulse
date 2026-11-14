#!/usr/bin/env bash
set -euo pipefail
umask 077

body=$(mktemp)
trap 'rm -f "$body"' EXIT
url=${PILOT_NOTIFICATIONS_URL:-https://api.eng-pulse.tsvetkov.org/healthz/notifications}

# Do not follow redirects or print response bodies into public workflow logs.
if ! status=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
  --retry 2 --retry-delay 5 --retry-max-time 50 --retry-connrefused \
  --proto '=http,https' --output "$body" --write-out '%{http_code}' "$url"); then
  echo '::error::Pilot notifications request failed' >&2
  exit 1
fi
if [[ "$status" == 200 ]] && jq -e \
  'type == "object" and .status == "ok" and .reason == "current"' "$body" >/dev/null 2>&1; then
  echo 'Pilot push notifications are current'
  exit 0
fi
if [[ "$status" == 503 ]] && jq -e \
  'type == "object" and .reason == "disabled"' "$body" >/dev/null 2>&1; then
  echo 'Pilot push notifications are disabled'
  exit 0
fi
echo '::error::Pilot push notifications are not confirmed healthy; inspect the notification outbox' >&2
exit 1
