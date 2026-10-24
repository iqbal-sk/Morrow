import AppKit
import SwiftUI

/// Build with RevealSymbol.swift so exported assets cannot drift from the animated logo.
@main @MainActor struct RenderRevealIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Resources/AppIcon")
        let assets = output.appendingPathComponent("AppIcon.icon/Assets")
        let preview = root.appendingPathComponent(".dev/reveal-logo")
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        let previous = preview.appendingPathComponent("previous-morrow-icon.png")
        let original = output.appendingPathComponent("morrow-icon.png")
        if !FileManager.default.fileExists(atPath: previous.path), FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: original, to: previous)
        }
        func write<V: View>(_ view: V, to url: URL) throws {
            let renderer = ImageRenderer(content: view.frame(width: 1024, height: 1024).environment(\.colorScheme, .light))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw NSError(domain: "RevealIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render \(url.path)"])
            }
            try data.write(to: url, options: .atomic)
        }
        try write(RevealSymbol(), to: output.appendingPathComponent("reveal-symbol.png"))
        try write(RevealSymbol(only: .coral), to: assets.appendingPathComponent("reveal-coral.png"))
        try write(RevealSymbol(only: .peach), to: assets.appendingPathComponent("reveal-peach.png"))
        try write(ZStack {
            Color(red: 1, green: 0.965, blue: 0.925)
            RevealSymbol()
        }, to: original)
        // Fixed poses are evidence of artwork/geometry, not a claim of measured live animation performance.
        for (name, coral, peach) in [("start", 0.25, 0.0), ("middle", 0.85, 0.55), ("settled", 1.0, 1.0)] {
            try write(ZStack {
                Color(red: 1, green: 0.965, blue: 0.925)
                RevealSymbol(coralProgress: coral, peachProgress: peach)
            }, to: preview.appendingPathComponent("\(name).png"))
        }
        try write(RevealSymbol(monochrome: true), to: preview.appendingPathComponent("monochrome.png"))
        print("Rendered Reveal icon, transparent layers, and pose previews from the shared vector source.")
    }
}
