import AppKit

/// A borderless quick-search panel has no system chrome, so it owns exactly one glass host.
/// NSGlassEffectView owns/resizes its content and supplies native adaptive legibility.
enum NativeGlassPanel {
    static func hosting(_ content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = content
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        material.layer?.masksToBounds = true
        content.frame = material.bounds
        content.autoresizingMask = [.width, .height]
        material.addSubview(content)
        return material
    }
}
