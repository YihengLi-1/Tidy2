#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Tidy2}"
CONFIG="${CONFIG:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/Tidy2.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/export}"
APP_PATH="$EXPORT_PATH/Tidy2.app"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

mkdir -p "$DIST_DIR"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[package] export app not found, run archive+export first."
  echo "         ./scripts/archive_beta.sh"
  echo "         ./scripts/export_beta.sh"
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Missing Info.plist in app: $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.0.0")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0")"
STAMP="$(date +%Y%m%d)"
BASENAME="Tidy2_Beta_${VERSION}_${BUILD_NO}_${STAMP}"
ZIP_PATH="$DIST_DIR/${BASENAME}.zip"
DMG_PATH="$DIST_DIR/${BASENAME}.dmg"

echo "[1/3] Creating zip from export app..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[2/3] Creating DMG with /Applications shortcut..."
rm -f "$DMG_PATH"
STAGE_DIR="$(mktemp -d "$ROOT_DIR/build/dmg_stage.XXXXXX")"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGE_DIR/Tidy2.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "Tidy2 Beta" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO "$DMG_PATH" >/dev/null

echo "[3/3] Done."
echo "Scheme: $SCHEME"
echo "Config: $CONFIG"
echo "Archive: $ARCHIVE_PATH"
echo "Export: $EXPORT_PATH"
echo "App: $APP_PATH"
echo "Zip: $ZIP_PATH"
echo "DMG: $DMG_PATH"
