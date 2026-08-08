#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

SERVER_URL="${SPARK_SERVER_URL:-https://voice.photovault.live}"
BUILD_MODE="${BUILD_MODE:-release}"
CLEAN="${CLEAN:-0}"

if [[ "$CLEAN" == "1" ]]; then
  flutter clean
fi

flutter pub get

case "$BUILD_MODE" in
  release)
    flutter build apk --release --dart-define=SPARK_SERVER_URL="$SERVER_URL"
    ;;
  debug)
    flutter build apk --debug --dart-define=SPARK_SERVER_URL="$SERVER_URL"
    ;;
  profile)
    flutter build apk --profile --dart-define=SPARK_SERVER_URL="$SERVER_URL"
    ;;
  *)
    echo "Unsupported BUILD_MODE: $BUILD_MODE" >&2
    echo "Use release, debug, or profile." >&2
    exit 2
    ;;
esac

echo "Built StoryVault APK with SPARK_SERVER_URL=$SERVER_URL"
