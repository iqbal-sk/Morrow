# Icon assets

`build.sh` regenerates the app icon, menu-bar images and portable shell icons from `Sources/DigUpApp/RevealSymbol.swift`.

To regenerate only the artwork from the repository root:

```sh
mkdir -p .build
xcrun swiftc Sources/DigUpApp/RevealSymbol.swift scripts/render-reveal-icon.swift -o .build/morrow-render-reveal
.build/morrow-render-reveal
swift scripts/render-icon.swift
```

`render-reveal-icon.swift` exports `morrow-icon.png`, `reveal-symbol.png` and the transparent `reveal-*` layers. `AppIcon.icon/icon.json` selects these layers for Icon Composer. `render-icon.swift` generates the ICNS fallback, tray images and shell sizes. Keep the generated assets in Git so previews and platform packaging can use them without running the macOS renderer.
