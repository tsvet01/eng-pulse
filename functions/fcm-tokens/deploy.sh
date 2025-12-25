#!/bin/bash
set -e

REGION="us-central1"
PROJECT_ID="tsvet01"

echo "Deploying FCM Token Registration functions..."

# Deploy register-token function
echo "Deploying register-token..."
gcloud functions deploy register-token \
    --gen2 \
    --runtime=python312 \
    --region="$REGION" \
    --source=. \
    --entry-point=register_token \
    --trigger-http \
    --allow-unauthenticated \
    --project="$PROJECT_ID" \
    --memory=256MB \
    --timeout=30s

# Deploy unregister-token function
echo "Deploying unregister-token..."
gcloud functions deploy unregister-token \
    --gen2 \
    --runtime=python312 \
    --region="$REGION" \
    --source=. \
    --entry-point=unregister_token \
    --trigger-http \
    --allow-unauthenticated \
    --project="$PROJECT_ID" \
    --memory=256MB \
    --timeout=30s

echo "Deployment complete!"
echo ""
echo "Endpoints:"
echo "  POST https://${REGION}-${PROJECT_ID}.cloudfunctions.net/register-token"
echo "  POST https://${REGION}-${PROJECT_ID}.cloudfunctions.net/unregister-token"
