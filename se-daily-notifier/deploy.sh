#!/bin/bash
set -e

PROJECT_ID="tsvet01"
REGION="us-central1"
FUNCTION_NAME="se-daily-notifier"
BUCKET_NAME="tsvet01-agent-brain"
GMAIL_USER="atsvetkov@gmail.com"
DEST_EMAIL="anton.tsvetkov@gmail.com"

# Check for Password
if [ -z "$GMAIL_APP_PASSWORD" ]; then
  echo "Error: GMAIL_APP_PASSWORD environment variable is not set."
  echo "Please run: export GMAIL_APP_PASSWORD='your-app-password'"
  exit 1
fi

echo "🚀 Deploying Cloud Function to Project: $PROJECT_ID"

# 1. Enable APIs
echo "Enabling APIs..."
gcloud services enable cloudfunctions.googleapis.com eventarc.googleapis.com run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com \
  --project $PROJECT_ID

# 2. Grant Pub/Sub Publisher role to Cloud Storage service account (needed for Eventarc)
# (This is often auto-done but good to ensure for 2nd gen functions)
# SERVICE_ACCOUNT="$(gcloud storage service-agent --project=$PROJECT_ID)"
# echo "Granting Pub/Sub Publisher role to $SERVICE_ACCOUNT"
# gcloud projects add-iam-policy-binding $PROJECT_ID \
#    --member="serviceAccount:$SERVICE_ACCOUNT" \
#    --role="roles/pubsub.publisher" > /dev/null


# 3. Deploy
echo "Deploying Function..."
gcloud functions deploy $FUNCTION_NAME \
  --gen2 \
  --runtime=python311 \
  --region=$REGION \
  --source=. \
  --entry-point=send_summary_email \
  --trigger-location=$REGION \
  --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
  --trigger-event-filters="bucket=$BUCKET_NAME" \
  --set-env-vars "GMAIL_USER=$GMAIL_USER,DEST_EMAIL=$DEST_EMAIL,GMAIL_APP_PASSWORD=$GMAIL_APP_PASSWORD" \
  --project $PROJECT_ID

echo "✅ Function Deployed!"
