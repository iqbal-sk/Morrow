#!/bin/bash
# A fresh, ad-hoc signed local preview. Use release.sh for public distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 0 ]]; then
  echo "Usage: scripts/package-macos.sh (no arguments)" >&2
  exit 1
fi
APP="$PWD/build.noindex/preview/Morrow.app"
# build.sh validates the destination and keeps the regular development bundle intact.
RELEASE=0 SIGN_ID=- APP_PATH="$APP" ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCH="$(lipo -archs "$APP/Contents/MacOS/Morrow" | tr ' ' '-')"
DMG="${APP%/*}/Morrow-$VERSION-$ARCH-preview.dmg"
# Never silently replace an existing artifact.
scripts/create-dmg.sh "$APP" "$DMG"
cd "${DMG%/*}"
shasum -a 256 "${DMG##*/}" > "${DMG##*/}.sha256"
echo "Local preview only: ad-hoc signed, not notarized."
