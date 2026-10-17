#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { printf '%s\n' "$1" >&2; exit 1; }

[[ ${EXPECTED_API_REVISION:-} =~ ^[a-f0-9]{40}$ ]] || fail 'Expected API revision must be a full commit SHA'
[[ ${PILOT_INVITE_CODE:-} =~ ^[A-Za-z0-9_-]{32,128}$ ]] || fail 'A private bootstrap invite of 32–128 safe characters is required'
if [[ $# -eq 1 && $1 == --check-inputs ]]; then
  echo 'Pilot setup inputs are valid'
  exit 0
fi
[[ $# -eq 0 ]] || fail 'Unsupported pilot setup arguments'

# Run from the existing Compose directory; never pull or restart services here.
container=$(docker compose ps --status running -q pulse-api)
[[ $container =~ ^[a-f0-9]{12,64}$ ]] || fail 'Exactly one running API container is required'
image=$(docker inspect --format '{{.Config.Image}}' "$container")
[[ $image == "ghcr.io/tsvet01/pulse-api:$EXPECTED_API_REVISION" ]] || fail 'Running API revision does not match the requested revision'

private_dir=$(mktemp -d)
trap 'rm -rf "$private_dir"' EXIT

request() {
  local path=$1 status
  shift
  status=$(curl --silent --show-error --max-time 15 --noproxy '*' \
    --output "$private_dir/response.json" --write-out '%{http_code}' "$@" \
    "http://127.0.0.1:8080$path") || fail 'Local API request failed'
  [[ $status == 200 ]] || fail 'Local API request did not return HTTP 200'
}

request /healthz
jq -e '.status == "ok" and .db == "ok"' "$private_dir/response.json" >/dev/null 2>&1 || fail 'API database health check failed'
token=$(docker compose exec -T pulse-api printenv PIPELINE_SERVICE_TOKEN)
[[ -n $token && $token != *$'\n'* && $token != *$'\r'* ]] || fail 'Running API service token is unavailable or malformed'
printf 'Authorization: Bearer %s\n' "$token" > "$private_dir/header"
unset token
request /internal/feeds --header "@$private_dir/header"
jq -e 'type == "array" and all(.[]; .slug == "engineering" and .is_active == true)' \
  "$private_dir/response.json" >/dev/null 2>&1 || fail 'Authenticated feed preflight failed'

inactive=$(docker compose exec -T postgres psql -U pulse -d pulse -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT count(*) FROM feeds WHERE slug = 'engineering' AND is_active = false;
SQL
)
[[ $inactive == 0 ]] || fail 'Engineering is disabled; bootstrap will not reactivate it'

# The existing seed CLI prints its invite; suppress both output streams.
if ! docker compose exec -T pulse-api pulse-api seed \
  --sources https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json \
  --invite "$PILOT_INVITE_CODE" --invite-uses 1 >/dev/null 2>&1; then
  fail 'Pilot seed failed; no invite or credentials have been printed'
fi

request /internal/feeds --header "@$private_dir/header"
jq -e 'type == "array" and length == 1 and .[0].slug == "engineering" and
  .[0].is_active == true and (.[0].sources | type == "array" and length > 0)' \
  "$private_dir/response.json" >/dev/null 2>&1 || fail 'Engineering feed verification failed after seeding'
invite_valid=$(docker compose exec -T postgres psql -U pulse -d pulse -X -tA -v ON_ERROR_STOP=1 \
  --set="invite_code=$PILOT_INVITE_CODE" <<'SQL'
SELECT EXISTS (SELECT 1 FROM invites WHERE code = :'invite_code' AND max_uses = 1
  AND used_count BETWEEN 0 AND 1 AND (expires_at IS NULL OR expires_at > now()));
SQL
)
[[ $invite_valid == t ]] || fail 'Bootstrap invite verification failed after seeding'
echo 'Engineering feed and private single-use bootstrap invite verified'
