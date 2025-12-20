#!/bin/bash
# Build script that injects git commit and build time

set -e

GIT_COMMIT=$(git rev-parse --short HEAD)
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M UTC")

echo "Building with commit: $GIT_COMMIT"
echo "Build time: $BUILD_TIME"

# Parse arguments
DEVICE=""
MODE="debug"

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
    *)
      shift
      ;;
  esac
done

# Build command
CMD="flutter run"

if [ -n "$DEVICE" ]; then
  CMD="$CMD -d $DEVICE"
fi

if [ "$MODE" = "release" ]; then
  CMD="$CMD --release"
fi

CMD="$CMD --dart-define=GIT_COMMIT=$GIT_COMMIT --dart-define=BUILD_TIME=$BUILD_TIME"

echo "Running: $CMD"
exec $CMD
