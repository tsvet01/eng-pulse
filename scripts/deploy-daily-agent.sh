#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

: "${PROJECT_ID:?}" "${REGION:?}" "${REPO_NAME:?}" "${IMAGE_TAG:?}"
secrets='ANTHROPIC_API_KEY=anthropic-api-key:latest,OPENAI_API_KEY=openai-api-key:latest'
env_updates='SHADOW_MODEL=claude-fable-5-1'
env_removals='ANTHROPIC_API_KEY,OPENAI_API_KEY,PIPELINE_SERVICE_TOKEN,PULSE_API_URL'

case "${PULSE_API_ENABLED:-false}" in
  false) ;;
  true)
    : "${PULSE_API_URL:?PULSE_API_URL is required when integration is enabled}"
    work_dir=$(mktemp -d)
    trap 'rm -rf "$work_dir"' EXIT
    token=$(gcloud secrets versions access latest --secret=pipeline-service-token --project "$PROJECT_ID")
    [ -n "$token" ] || { echo 'Pipeline service token is empty' >&2; exit 1; }
    printf 'Authorization: Bearer %s\n' "$token" > "$work_dir/auth-header"
    unset token

    # No redirects: credentials must stay on the configured API host.
    status=$(curl --silent --show-error --fail --connect-timeout 5 --max-time 20 \
      --output "$work_dir/health.json" --write-out '%{http_code}' "${PULSE_API_URL%/}/healthz")
    if [ "$status" != 200 ] || ! jq -e '.status == "ok" and .db == "ok"' "$work_dir/health.json" >/dev/null; then
      echo 'API/database is not ready; running job unchanged' >&2
      exit 1
    fi
    status=$(curl --silent --show-error --fail --connect-timeout 5 --max-time 20 \
      --header "@$work_dir/auth-header" --output "$work_dir/feeds.json" --write-out '%{http_code}' \
      "${PULSE_API_URL%/}/internal/feeds")
    if [ "$status" != 200 ] || ! jq -e 'type == "array" and length == 1 and .[0].slug == "engineering" and .[0].is_active == true' "$work_dir/feeds.json" >/dev/null; then
      echo 'API must expose exactly the active engineering feed; running job unchanged' >&2
      exit 1
    fi
    secrets+=',PIPELINE_SERVICE_TOKEN=pipeline-service-token:latest'
    env_updates+=",PULSE_API_URL=${PULSE_API_URL%/}"
    echo 'API authentication and engineering seed verified'
    ;;
  *) echo 'PULSE_API_ENABLED must be true or false' >&2; exit 1 ;;
esac

gcloud builds submit --config=apps/daily-agent/cloudbuild.yaml \
  --substitutions="_IMAGE_TAG=${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/se-daily-agent:${IMAGE_TAG}" \
  --machine-type=E2_HIGHCPU_8 .
# Replace configuration in one operation; do not clear credentials on the live job first.
gcloud run jobs deploy se-daily-agent-job \
  --image "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/se-daily-agent:${IMAGE_TAG}" \
  --region "$REGION" --project "$PROJECT_ID" \
  --set-secrets "$secrets" \
  --remove-env-vars="$env_removals" --update-env-vars="$env_updates" \
  --task-timeout 10m
