#!/usr/bin/env bash
set -euo pipefail

fail() { echo "$1" >&2; exit 1; }
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ ${EXPECTED_API_REVISION:-} =~ ^[a-f0-9]{40}$ ]] || fail 'Invalid API revision'
[[ ${TEST_ID:-} =~ $uuid && ${PILOT_PUSH_TEST_USER_ID:-} =~ $uuid ]] || fail 'Invalid test ID or missing account receipt'
[[ ${PILOT_PUSH_TEST_TOKEN_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid fingerprint receipt'
[[ ${TEST_MODE:-} == check || ${TEST_MODE:-} == send ]] || fail 'Expected check or send'
if [[ $# -eq 1 && $1 == --check-inputs ]]; then exit 0; fi
[[ $# -eq 0 ]] || fail 'Unsupported arguments'

container=$(docker compose ps --status running -q pulse-api)
[[ $container =~ ^[a-f0-9]{12,64}$ ]] || fail 'Exactly one running API container is required'
image=$(docker inspect --format '{{.Config.Image}}' "$container")
[[ $image == "ghcr.io/tsvet01/pulse-api:$EXPECTED_API_REVISION" ]] || fail 'Running API is not the approved revision'

# Mask both selectors from process arguments; Docker copies their named environment variables.
args=(--env PILOT_PUSH_TEST_USER_ID --env PILOT_PUSH_TEST_TOKEN_SHA256)
source=$(docker exec "$container" sh -c '
  if [ -n "${APNS_KEY_BASE64:-}" ] && [ -n "${APNS_KEY_ID:-}" ] && [ -n "${APNS_TEAM_ID:-}" ]; then echo container
  elif [ -z "${APNS_KEY_BASE64:-}${APNS_KEY_ID:-}${APNS_TEAM_ID:-}" ]; then echo environment
  else echo partial; fi')
case $source in
  container) ;;
  environment)
    [[ -n ${APNS_KEY_BASE64:-} && -n ${APNS_KEY_ID:-} && -n ${APNS_TEAM_ID:-} ]] || fail 'No complete APNs credential set; no send'
    args+=(--env APNS_KEY_BASE64 --env APNS_KEY_ID --env APNS_TEAM_ID)
    ;;
  *) fail 'Incomplete container APNs credentials; no send' ;;
esac
exec docker exec "${args[@]}" "$container" pulse-api pilot-push-test "$TEST_MODE" "$TEST_ID"
