#!/bin/bash
# Build script that injects git commit and build time
# Usage: ./build.sh [-d device] [--release] [--bucket bucket-name]

set -e

GIT_COMMIT=$(git rev-parse --short HEAD)
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M UTC")

echo "Building with commit: $GIT_COMMIT"
echo "Build time: $BUILD_TIME"

# Parse arguments
DEVICE=""
MODE="debug"
BUCKET=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--device)
      DEVICE="$2"
      shift 2
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --bucket)
      BUCKET="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Support GCS_BUCKET env var as fallback
BUCKET="${BUCKET:-$GCS_BUCKET}"

# Build command
CMD="flutter run"

if [ -n "$DEVICE" ]; then
  CMD="$CMD -d $DEVICE"
fi

if [ "$MODE" = "release" ]; then
  CMD="$CMD --release"
fi

CMD="$CMD --dart-define=GIT_COMMIT=$GIT_COMMIT --dart-define=BUILD_TIME=$BUILD_TIME"

if [ -n "$BUCKET" ]; then
  CMD="$CMD --dart-define=GCS_BUCKET=$BUCKET"
  echo "Using bucket: $BUCKET"
fi

echo "Running: $CMD"
exec $CMD
