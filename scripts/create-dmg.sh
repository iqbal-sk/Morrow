#!/bin/bash
# Package an already built/signed app. Signing and notarization belong to release.sh.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "Usage: scripts/create-dmg.sh <Morrow.app> <output.dmg>" >&2
  exit 1
fi
APP="$1"
DMG="$2"
[[ -d "$APP" && "$APP" == *.app ]] || { echo "Expected an app bundle: $APP" >&2; exit 1; }
[[ "$DMG" == *.dmg && ! -e "$DMG" && ! -L "$DMG" ]] || {
  echo "Output must be a new .dmg file: $DMG" >&2; exit 1;
}
codesign --verify --strict --deep "$APP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/morrow-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Morrow.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Morrow" -srcfolder "$STAGE" -fs HFS+ -format ULFO "$DMG"
hdiutil verify -quiet "$DMG"
echo "Created $DMG"
