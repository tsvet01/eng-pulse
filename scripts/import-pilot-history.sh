#!/usr/bin/env bash
set -euo pipefail
umask 077
fail() { printf '%s\n' "$1" >&2; exit 1; }
[[ ${EXPECTED_API_REVISION:-} =~ ^[a-f0-9]{40}$ ]] || fail 'Expected API revision must be a full commit SHA'
if [[ $# -eq 1 && $1 == --check-inputs ]]; then
  exit 0
fi
[[ $# -eq 0 ]] || fail 'Unsupported history import arguments'
container=$(docker compose ps --status running -q pulse-api)
[[ $container =~ ^[a-f0-9]{12,64}$ ]] || fail 'Exactly one running API container is required'
image=$(docker inspect --format '{{.Config.Image}}' "$container")
[[ $image == "ghcr.io/tsvet01/pulse-api:$EXPECTED_API_REVISION" ]] || fail 'Running API revision does not match the requested revision'
curl --fail --silent --show-error --max-time 15 --noproxy '*' http://127.0.0.1:8080/healthz |
  jq -e '.status == "ok" and .db == "ok"' >/dev/null || fail 'API database health check failed'
report=$(mktemp)
trap 'rm -f "$report"' EXIT
docker compose exec -T pulse-api pulse-api import-history > "$report" || fail 'History import failed'
jq -e '.verified > 0 and .verified == (.expected_dates | length) and
  .verified == (.inserted + .unchanged) and (.verified + (.missing_dates | length)) == 30' \
  "$report" >/dev/null || fail 'History import did not return a complete parity report'
cat "$report"
