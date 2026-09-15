#!/bin/bash
set -e

PROJECT_ID="tsvet01"
REGION="us-central1"
REPO_NAME="agent-repo"
IMAGE_NAME="se-daily-agent"
SERVICE_NAME="se-daily-agent-job"
IMAGE_TAG=$(git rev-parse HEAD)

# Always activate the correct project first
echo "🔧 Activating GCP project: $PROJECT_ID"
gcloud config set project $PROJECT_ID --quiet

# Load .env variables (safely, ignoring comments and empty lines)
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Check required API keys
for key in ANTHROPIC_API_KEY OPENAI_API_KEY; do
  if [ -z "${!key}" ]; then
    echo "Error: $key is not set. Please check your .env file."
    exit 1
  fi
done

echo "🚀 Starting deployment to GCP Project: $PROJECT_ID"
echo "   Providers: Claude (selection + brief), OpenAI (judge)"

# 1. Enable APIs
echo "Enabling APIs..."
gcloud services enable artifactregistry.googleapis.com run.googleapis.com secretmanager.googleapis.com \
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
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
echo "Building and Pushing image to $IMAGE_URI..."
# Use --platform linux/amd64 to ensure it runs on Cloud Run (which is x86_64)
# Build from project root to include libs/llm-client shared crate
cd ../..
docker build --platform linux/amd64 -t $IMAGE_URI -f apps/daily-agent/Dockerfile .
cd apps/daily-agent
docker push $IMAGE_URI

# 5. Create/Update Secrets in Secret Manager
echo "Setting up secrets..."

# Get the default compute service account
SERVICE_ACCOUNT=$(gcloud iam service-accounts list --project $PROJECT_ID \
  --filter="email~compute@developer.gserviceaccount.com" \
  --format="value(email)" | head -1)

# Helper function to create or update a secret
create_or_update_secret() {
  local secret_name=$1
  local secret_value=$2

  if [ -z "$secret_value" ]; then
    return
  fi

  if gcloud secrets describe $secret_name --project $PROJECT_ID > /dev/null 2>&1; then
    echo "   Updating secret: $secret_name"
    echo -n "$secret_value" | gcloud secrets versions add $secret_name --data-file=- --project $PROJECT_ID
  else
    echo "   Creating secret: $secret_name"
    echo -n "$secret_value" | gcloud secrets create $secret_name --data-file=- --project $PROJECT_ID
    # Grant Cloud Run access to new secret
    gcloud secrets add-iam-policy-binding $secret_name \
      --member="serviceAccount:$SERVICE_ACCOUNT" \
      --role="roles/secretmanager.secretAccessor" \
      --project=$PROJECT_ID --quiet
  fi
}

create_or_update_secret "anthropic-api-key" "$ANTHROPIC_API_KEY"
create_or_update_secret "openai-api-key" "$OPENAI_API_KEY"

# 6. Deploy Cloud Run Job with all configured secrets
echo "Deploying Cloud Run Job..."

SECRETS_FLAG="ANTHROPIC_API_KEY=anthropic-api-key:latest,OPENAI_API_KEY=openai-api-key:latest"

gcloud run jobs deploy $SERVICE_NAME \
  --image $IMAGE_URI \
  --region $REGION \
  --project $PROJECT_ID \
  --set-secrets "$SECRETS_FLAG" \
  --max-retries 1 \
  --task-timeout 10m

echo "✅ Deployment Complete!"
echo ""
echo "Run the job manually with:"
echo "  gcloud run jobs execute $SERVICE_NAME --region $REGION --project $PROJECT_ID"
echo ""
echo "View logs with:"
echo "  gcloud run jobs executions list --job $SERVICE_NAME --region $REGION --project $PROJECT_ID"
