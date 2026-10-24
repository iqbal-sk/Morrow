# Morrow

A private, local-first search app for the files you choose on your Mac. Search with the words you remember, find photos by who is in them, and open every match at its source.

Morrow includes the people-search and index-management work from this personal branch. Add friends by name and reference photos, review uncertain face matches with their source file visible, and reset the index for one folder or all folders without deleting people or references.

## Install without a DMG (build from source)

The app runs on Apple Silicon Macs with macOS 14 or later; Liquid Glass requires macOS 26 or later. Building requires full Xcode 26.1 or later with its command-line tools, Swift 6.2 or later, Git, Python 3, and CMake on your PATH (or `uv`, which the build script can use to install local CMake tools). Internet access is needed to fetch build dependencies and models. You do not need a paid Apple Developer membership to build or run Morrow locally.

Clone the repository or download and extract its source ZIP, then open Terminal in the repository folder and run:

```sh
./build.sh
open build.noindex/Morrow.app
```

`build.sh` prepares the native dependencies, fetches the checksum-verified face model, builds the app and helper, and signs the app locally. To install it permanently, quit the running copy, open `build.noindex` in Finder, and drag `Morrow.app` into Applications (or `~/Applications` for your user only). Open that installed copy for subsequent launches. No DMG is required.

To run the automated tests after the first build:

```sh
swift test
```

On first launch, choose the folders Morrow should search. It never starts indexing your home directory on its own. Morrow downloads its own Gemma model files to `~/Library/Application Support/Morrow/Models`; it does not read DigUp's model folder.

## macOS installer

Create an ad-hoc signed DMG with a fresh app and an Applications shortcut; no paid Apple Developer membership is required:

```sh
scripts/package-macos.sh
```

The DMG (for example, `Morrow-0.1.0-arm64.dmg`) and SHA-256 checksum appear in `build.noindex/preview/`. Open the DMG and drag Morrow to Applications, then launch the installed app. The script refuses to overwrite an existing DMG: move the previous artifact aside before packaging the same version again.

This build is not notarized. When a downloaded copy is blocked because Apple cannot verify its developer, users who trust the source can try launching it, then choose **System Settings → Privacy & Security → Open Anyway** and confirm. Managed Macs may restrict this option. See [Apple's instructions](https://support.apple.com/en-us/102445).

### Optional Developer ID signing and notarization

For a smoother downloaded-app installation experience, install a Developer ID Application certificate from your paid Apple Developer account, save a notarytool keychain profile, then run:

```sh
BUNDLE_ID=com.yourcompany.morrow \
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=Morrow scripts/release.sh
```

Choose a stable bundle identifier before the first public release and replace the example values. `scripts/release.sh` builds with the hardened runtime, signs and notarizes the app and DMG, staples their tickets, and checks Gatekeeper acceptance. Upload the DMG and checksum from `build.noindex/release/` as release assets on your own hosting or GitHub Releases; do not commit installer binaries. No publishing happens automatically. Test the downloaded installer on a separate Mac before releasing it. See Apple's [distribution guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

### GitHub downloads

Keep source code in Git and attach the DMG plus its matching `.dmg.sha256` file to a GitHub Release for the corresponding source revision. Ad-hoc builds come from `build.noindex/preview/`; notarized builds come from `build.noindex/release/`. State whether a release is notarized and include the installation instructions above. The initial unnotarized build should be labeled as an early release while testing continues.

Git LFS is not needed for these installers: [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) hosts downloadable binaries separately from repository history. Add the actual release download link to this README after the repository and release are published.

## Local data

- Morrow's search and people index: `~/Library/Application Support/Morrow/index.noindex`.
- Morrow preferences use the bundle identifier `com.iqbal.morrow`.
- Existing files are read in place. Resetting an index removes indexed records, not source files, friend names, or reference photos.
- Morrow starts with its own empty index. It does not import a DigUp index.
- This personal build has no upstream update feed configured.

## Project notes

The native macOS app is the supported Morrow build. The repository retains shared search/indexing code and inherited platform code. People search uses Apple's Vision face detection with the local SFace model; semantic image and file search uses EmbeddingGemma 2 locally.

This repository is a personal fork of [DigUp](https://github.com/ARahim3/DigUp). The original MIT license and required notices remain in `LICENSE` and `Resources/Acknowledgements.txt`.
