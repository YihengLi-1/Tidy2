#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Tidy2}"
CONFIG="${CONFIG:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/Tidy2.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/export}"
EXPORT_METHOD="${EXPORT_METHOD:-development}" # development | developer-id

case "$EXPORT_METHOD" in
  development)
    EXPORT_OPTIONS_PLIST_DEFAULT="$ROOT_DIR/Config/ExportOptions_Development.plist"
    ;;
  developer-id)
    EXPORT_OPTIONS_PLIST_DEFAULT="$ROOT_DIR/Config/ExportOptions_DeveloperID.plist"
    ;;
  *)
    echo "Unsupported EXPORT_METHOD: $EXPORT_METHOD (use development or developer-id)" >&2
    exit 1
    ;;
esac

EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$EXPORT_OPTIONS_PLIST_DEFAULT}"

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "Archive not found: $ARCHIVE_PATH" >&2
  echo "Run ./scripts/archive_beta.sh first." >&2
  exit 1
fi

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  echo "Export options plist not found: $EXPORT_OPTIONS_PLIST" >&2
  exit 1
fi

mkdir -p "$EXPORT_PATH"

echo "[export] archive: $ARCHIVE_PATH"
echo "[export] method: $EXPORT_METHOD"
echo "[export] options: $EXPORT_OPTIONS_PLIST"
echo "[export] output: $EXPORT_PATH"

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/Tidy2.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Export succeeded but app not found: $APP_PATH" >&2
  exit 1
fi

echo "[export] done: $APP_PATH"
