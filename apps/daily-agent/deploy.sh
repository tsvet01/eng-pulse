#!/bin/bash
set -e

PROJECT_ID="tsvet01"
REGION="us-central1"
REPO_NAME="agent-repo"
IMAGE_NAME="se-daily-agent"
SERVICE_NAME="se-daily-agent-job"

# Load .env variables
if [ -f .env ]; then
  export $(cat .env | xargs)
fi

if [ -z "$GEMINI_API_KEY" ]; then
  echo "Error: GEMINI_API_KEY is not set. Please check your .env file."
  exit 1
fi

echo "🚀 Starting deployment to GCP Project: $PROJECT_ID"

# 1. Enable APIs
echo "Enable APIs..."
gcloud services enable artifactregistry.googleapis.com run.googleapis.com \
  --project $PROJECT_ID

# 2. Configure Docker Auth
echo "Configuring Docker auth..."
gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

# 3. Create Artifact Registry Repository (if not exists)
echo "Checking Artifact Registry..."
if ! gcloud artifacts repositories describe $REPO_NAME \
    --project $PROJECT_ID --location $REGION > /dev/null 2>&1; then
  echo "Creating repository $REPO_NAME..."
  gcloud artifacts repositories create $REPO_NAME \
    --repository-format=docker \
    --location=$REGION \
    --description="Docker repository for Agent images" \
    --project=$PROJECT_ID
else
  echo "Repository $REPO_NAME already exists."
fi

# 4. Build and Push Image
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:latest"
echo "Building and Pushing image to $IMAGE_URI..."
# Use --platform linux/amd64 to ensure it runs on Cloud Run (which is x86_64)
# Build from project root to include libs/gemini-engine shared crate
cd ../..
docker build --platform linux/amd64 -t $IMAGE_URI -f apps/daily-agent/Dockerfile .
cd apps/daily-agent
docker push $IMAGE_URI

# 5. Deploy Cloud Run Job (use Secret Manager for API key)
echo "Deploying Cloud Run Job..."
gcloud run jobs deploy $SERVICE_NAME \
  --image $IMAGE_URI \
  --region $REGION \
  --project $PROJECT_ID \
  --set-secrets GEMINI_API_KEY=gemini-api-key:latest \
  --max-retries 1 \
  --task-timeout 5m

echo "✅ Deployment Complete!"
echo "You can run the job manually with:"
echo "gcloud run jobs execute $SERVICE_NAME --region $REGION --project $PROJECT_ID"
