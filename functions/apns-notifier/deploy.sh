#!/bin/bash
set -e

REGION="us-central1"
PROJECT="tsvet01"

echo "Deploying APNs token registration function..."
gcloud functions deploy register-apns-token \
  --gen2 \
  --runtime=python312 \
  --region=$REGION \
  --source=. \
  --entry-point=register_apns_token \
  --trigger-http \
  --allow-unauthenticated \
  --memory=256MB \
  --timeout=30s \
  --project=$PROJECT

echo "Deploying APNs notification trigger function..."
gcloud functions deploy trigger-apns-notification \
  --gen2 \
  --runtime=python312 \
  --region=$REGION \
  --source=. \
  --entry-point=trigger_apns_notification \
  --trigger-http \
  --allow-unauthenticated \
  --memory=256MB \
  --timeout=60s \
  --project=$PROJECT

echo "Done! Functions deployed."
echo ""
echo "Endpoints:"
echo "  Register: https://$REGION-$PROJECT.cloudfunctions.net/register-apns-token"
echo "  Trigger:  https://$REGION-$PROJECT.cloudfunctions.net/trigger-apns-notification"
