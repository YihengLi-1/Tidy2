#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/export}"
APP_PATH="${APP_PATH:-$EXPORT_PATH/Tidy2.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  echo "Run ./scripts/export_beta.sh first." >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Missing Info.plist: $INFO_PLIST" >&2
  exit 1
fi

echo "== codesign -dv --verbose=4 =="
codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true

echo
echo "== codesign --verify --deep --strict =="
codesign --verify --deep --strict "$APP_PATH"
echo "codesign verify: PASS"

echo
echo "== plutil -p Info.plist =="
plutil -p "$INFO_PLIST"

echo
echo "== codesign entitlements =="
ENT_TMP="$(mktemp)"
codesign -d --entitlements :- "$APP_PATH" >"$ENT_TMP" 2>/dev/null || true
cat "$ENT_TMP"

if grep -q "com.apple.security.app-sandbox" "$ENT_TMP" && grep -q "com.apple.security.files.user-selected.read-write" "$ENT_TMP"; then
  echo "entitlements check: PASS (sandbox + user-selected read/write found)"
else
  echo "entitlements check: WARNING (required keys not found in dump)"
fi
rm -f "$ENT_TMP"

echo
echo "== spctl assess =="
if spctl --assess --type execute --verbose "$APP_PATH"; then
  echo "spctl assess: PASS"
else
  echo "spctl assess: FAIL/REJECTED"
  echo "Note: this may fail before notarization; signing can still be valid."
fi
