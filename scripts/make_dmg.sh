#!/bin/bash
# Package a .app into a drag-to-Applications DMG.
# Usage: make_dmg.sh <path-to-app> <output-dmg-name>
set -euo pipefail

APP_PATH="${1:?usage: make_dmg.sh <app> <dmg-name>}"
DMG_NAME="${2:?usage: make_dmg.sh <app> <dmg-name>}"
APP_NAME="$(basename "$APP_PATH")"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "${APP_NAME%.app}" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_NAME"

echo "Created $DMG_NAME"
ls -lh "$DMG_NAME"
