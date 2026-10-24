# Contributing to Morrow

Morrow is a personal local-search app. Keep changes focused, preserve on-device processing, and avoid adding telemetry
or cloud services without an explicit product decision.

## Before a larger change

Describe the expected user-visible effect and its impact on local data, search results, performance, and privacy before
starting larger work.

## Checks

- Run `swift test` for the engine and macOS app.
- Run `cargo test` in `shell/src-tauri` for portable-shell changes.
- For search-quality or performance changes, record before-and-after results on the same computer.

## Project layout

The shared search engine is in `Sources/DigUpKit`; platform-specific readers live in `Platform/Apple` and
`Platform/Portable`. The native macOS app is in `Sources/DigUpApp`. The Windows and Linux shell is in `shell/` (Tauri,
Rust, HTML, and JavaScript), and runs the engine as a helper program. `scripts/` builds llama.cpp, ffmpeg, and portable
packages. The README explains how to build the macOS app.

## Portable engine dependencies

`scripts/fetch-vendor.sh` verifies SQLite, miniz, PDFium, and stb downloads against the SHA-256 pins in
`scripts/vendor-checksums.json` before extraction. When changing a version, review its upstream release and update its
pin. Do not obtain an expected hash from the same untrusted download at build time.

## Reporting a problem

Include your computer, system and Morrow versions, what you did or searched for, and what you expected instead. Logs are
in:

- macOS: `~/Library/Application Support/Morrow/index.noindex` (`app.log` and `indexer.log`)
- Windows: `%LOCALAPPDATA%\com.iqbal.morrow\logs`, and `worker.log` in `%LOCALAPPDATA%\Morrow\index`
- Linux: `~/.local/share/com.iqbal.morrow/logs`, and `worker.log` in `~/.local/share/morrow/index`

Logs may contain file names and search terms, so review them before sharing.

Morrow includes code from DigUp. The upstream MIT license and required notices remain in `LICENSE` and
`Resources/Acknowledgements.txt`.
