#!/usr/bin/env bash
set -euo pipefail
umask 077

body=$(mktemp)
trap 'rm -f "$body"' EXIT
url=${PILOT_FRESHNESS_URL:-https://api.eng-pulse.tsvetkov.org/healthz/briefs}

# Do not follow redirects or print response bodies into public workflow logs.
if ! status=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
  --retry 2 --retry-delay 5 --retry-max-time 50 --retry-connrefused \
  --proto '=http,https' --output "$body" --write-out '%{http_code}' "$url"); then
  echo '::error::Pilot freshness request failed' >&2
  exit 1
fi
if [[ "$status" != 200 ]] || ! jq -e \
  'type == "object" and .status == "ok" and .reason == "current"' "$body" >/dev/null 2>&1; then
  echo '::error::Pilot feed is not confirmed current; inspect the protected reconciliation checkpoint' >&2
  exit 1
fi
echo 'Pilot engineering feed is current'
