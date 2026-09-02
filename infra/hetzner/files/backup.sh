#!/usr/bin/env bash
# Nightly pg_dump → private GCS bucket via rclone (SA key written by the deploy job). Keeps 30 days.
set -euo pipefail
cd /opt/pulse
set -a; . ./.env.defaults; . ./.env; set +a
STAMP=$(date -u +%F)
mkdir -p backups
docker compose exec -T postgres pg_dump -U pulse pulse | gzip > "backups/pulse-${STAMP}.sql.gz"
docker run --rm -v /opt/pulse/backups:/b -v /opt/pulse/gcs-backup-sa.json:/sa.json:ro rclone/rclone \
  --gcs-service-account-file /sa.json copy /b :gcs:tsvet01-pulse-backups/postgres
docker run --rm -v /opt/pulse/gcs-backup-sa.json:/sa.json:ro rclone/rclone \
  --gcs-service-account-file /sa.json delete --min-age 30d :gcs:tsvet01-pulse-backups/postgres
find backups -name '*.sql.gz' -mtime +3 -delete
