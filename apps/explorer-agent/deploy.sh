#!/bin/bash
set -e

PROJECT_ID="tsvet01"
REGION="us-central1"
REPO_NAME="agent-repo"
IMAGE_NAME="se-explorer-agent"
SERVICE_NAME="se-explorer-agent-job"

# Load .env variables
if [ -f .env ]; then
  export $(cat .env | xargs)
fi

if [ -z "$GEMINI_API_KEY" ]; then
  echo "Error: GEMINI_API_KEY is not set."
  exit 1
fi

echo "🚀 Deploying Explorer Agent to GCP Project: $PROJECT_ID"

# 1. Configure Docker Auth
gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

# 2. Build and Push Image
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:latest"
echo "Building and Pushing image to $IMAGE_URI..."
# Build from project root to include libs/gemini-engine shared crate
cd ../..
docker build --platform linux/amd64 -t $IMAGE_URI -f apps/explorer-agent/Dockerfile .
cd apps/explorer-agent
docker push $IMAGE_URI

# 3. Deploy Cloud Run Job (use Secret Manager for API key)
echo "Deploying Cloud Run Job..."
gcloud run jobs deploy $SERVICE_NAME \
  --image $IMAGE_URI \
  --region $REGION \
  --project $PROJECT_ID \
  --set-secrets GEMINI_API_KEY=gemini-api-key:latest \
  --max-retries 1 \
  --task-timeout 30m

echo "✅ Deployment Complete!"