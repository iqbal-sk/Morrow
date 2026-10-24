# Morrow

A private, local-first search app for the files you choose on your Mac. Search with the words you remember, find photos by who is in them, and open every match at its source.

Morrow includes the people-search and index-management work from this personal branch. Add friends by name and reference photos, review uncertain face matches with their source file visible, and reset the index for one folder or all folders without deleting people or references.

## Build on macOS

Requirements: macOS 14 or later, Xcode command-line tools, and Swift 6.2.

```sh
swift test
./build.sh
open build.noindex/Morrow.app
```

On first launch, choose the folders Morrow should search. It never starts indexing your home directory on its own. Morrow downloads its own Gemma model files to `~/Library/Application Support/Morrow/Models`; it does not read DigUp's model folder.

## macOS installer

Create a local preview DMG with a fresh app and an Applications shortcut:

```sh
scripts/package-macos.sh
```

The DMG and SHA-256 checksum appear in `build.noindex/preview/`. The current build targets Apple Silicon. Open the DMG and drag Morrow to Applications. This preview is ad-hoc signed and not notarized; it is for local testing, not a public release. The script refuses to overwrite an existing DMG: move the previous artifact aside before packaging the same version again.

For public distribution, install a Developer ID Application certificate from your Apple Developer account, save a notarytool keychain profile, then run:

```sh
BUNDLE_ID=com.yourcompany.morrow \
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=Morrow scripts/release.sh
```

Choose a stable bundle identifier before the first public release and replace the example values. `scripts/release.sh` builds with the hardened runtime, signs and notarizes the app and DMG, staples their tickets, and checks Gatekeeper acceptance. Upload the DMG and checksum from `build.noindex/release/` as release assets on your own hosting or GitHub Releases; do not commit installer binaries. No publishing happens automatically. Test the downloaded installer on a separate Mac before releasing it. See Apple's [distribution guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Local data

- Morrow's search and people index: `~/Library/Application Support/Morrow/index.noindex`.
- Morrow preferences use the bundle identifier `com.iqbal.morrow`.
- Existing files are read in place. Resetting an index removes indexed records, not source files, friend names, or reference photos.
- Morrow starts with its own empty index. It does not import a DigUp index.
- This personal build has no upstream update feed configured.

## Project notes

The native macOS app is the supported Morrow build. The repository retains shared search/indexing code and inherited platform code. People search uses Apple's Vision face detection with the local SFace model; semantic image and file search uses EmbeddingGemma 2 locally.

This repository is a personal fork of [DigUp](https://github.com/ARahim3/DigUp). The original MIT license and required notices remain in `LICENSE` and `Resources/Acknowledgements.txt`.
