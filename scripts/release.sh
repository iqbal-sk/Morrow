#!/bin/bash
# Builds Morrow for release: signed with a Developer ID and the hardened runtime, notarized and stapled, in a DMG.
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=Morrow scripts/release.sh
# NOTARY_PROFILE names notarytool credentials in your keychain, saved once with
#   xcrun notarytool store-credentials Morrow --apple-id you@example.com --team-id TEAMID
# (it asks for an app-specific password from appleid.apple.com). Output: build.noindex/release/Morrow-<version>.dmg
# With APPCAST=<path to appcast.xml> (and NOTES=<an HTML fragment> for the update window), the DMG is also signed for
# Sparkle and listed first in that update feed (scripts/appcast.py). Publishing the DMG and the feed is a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd -P)"
if [[ -L build.noindex ]]; then
  echo "build.noindex must be a real directory, not a symlink" >&2
  exit 1
fi
mkdir -p build.noindex
BUILD_ROOT="$(cd -P build.noindex && pwd)"
if [[ "$BUILD_ROOT" != "$REPO_ROOT/build.noindex" ]]; then
  echo "build.noindex resolves outside this repository" >&2
  exit 1
fi
: "${SIGN_ID:?set SIGN_ID to a Developer ID Application identity (security find-identity -v -p codesigning)}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile (see the top of this script)}"
if [[ "${BUNDLE_ID:-com.iqbal.morrow}" == "com.iqbal.morrow" ]]; then
  echo "Set an explicit release BUNDLE_ID before publishing a Morrow build." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="$BUILD_ROOT/release/Morrow.app"
OUT="$BUILD_ROOT/release"
# This personal build removes Sparkle's upstream feed. Don't publish an appcast entry for a build that won't check it.
if [[ -n "${APPCAST:-}" && -z "${SPARKLE_FEED:-}" ]]; then
  echo "APPCAST is set, but this build has no Sparkle feed. Set SPARKLE_FEED as well or unset APPCAST." >&2
  exit 1
fi
if [[ -n "${APPCAST:-}" && -z "${DOWNLOAD_BASE:-}" ]]; then
  echo "APPCAST is set; set DOWNLOAD_BASE to this Morrow repository's GitHub releases/download URL." >&2
  exit 1
fi
# With APPCAST set the DMG gets signed for Sparkle at the end: make sure the key is in the keychain before the minutes of
# building and notarizing (sign_update -p prints the public key, or fails without one).
if [[ -n "${APPCAST:-}" ]]; then
  SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update
  if [[ -x "$SIGN_UPDATE" ]] && ! "$SIGN_UPDATE" -p >/dev/null 2>&1; then
    echo "APPCAST is set but sign_update finds no Sparkle key in the keychain: not building a DMG that can't be signed" >&2
    exit 1
  fi
fi
rm -rf "$OUT"
mkdir -p "$OUT"

RELEASE=1 APP_PATH="$APP" ./build.sh
codesign --verify --strict --deep --verbose=2 "$APP"

# The app itself is notarized and stapled first, so a copy dragged out of the DMG passes Gatekeeper offline too.
ditto -c -k --keepParent "$APP" "$OUT/Morrow.zip"
xcrun notarytool submit "$OUT/Morrow.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/Morrow.zip"

# The DMG: the same drag-to-Applications layout as local previews.
DMG="$OUT/Morrow-$VERSION.dmg"
scripts/create-dmg.sh "$APP" "$DMG"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(cd "$OUT" && shasum -a 256 "${DMG##*/}" > "${DMG##*/}.sha256")
if [[ -n "${APPCAST:-}" ]]; then
  scripts/appcast.py "$DMG" "$APPCAST" --app "$APP" ${NOTES:+--notes "$NOTES"}
fi
echo "Released $DMG ($(du -h "$DMG" | cut -f1))"
