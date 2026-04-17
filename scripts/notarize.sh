#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
DMG_PATH="${DMG_PATH:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_LOG="${NOTARY_LOG:-$ROOT_DIR/build/notarytool_result.json}"

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$(ls -1t "$DIST_DIR"/Tidy2_Beta_*.dmg 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "DMG not found. Provide DMG_PATH or build one via ./scripts/package_beta.sh" >&2
  exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "NOTARY_PROFILE is required (xcrun notarytool keychain profile)." >&2
  echo "Example: NOTARY_PROFILE=AC_NOTARY ./scripts/notarize.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "$NOTARY_LOG")"

echo "[notarize] submit: $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json | tee "$NOTARY_LOG"

echo "[notarize] stapling..."
xcrun stapler staple "$DMG_PATH"

echo "[notarize] done. log: $NOTARY_LOG"
