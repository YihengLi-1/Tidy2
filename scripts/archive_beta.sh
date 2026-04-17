#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Tidy2}"
CONFIG="${CONFIG:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/Tidy2.xcarchive}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Tidy2.xcodeproj}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode.app and switch developer dir." >&2
  exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")"

echo "[archive] project: $PROJECT_PATH"
echo "[archive] scheme: $SCHEME"
echo "[archive] config: $CONFIG"
echo "[archive] output: $ARCHIVE_PATH"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE_PATH" \
  clean archive

echo "[archive] done: $ARCHIVE_PATH"
