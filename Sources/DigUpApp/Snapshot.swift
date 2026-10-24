import AppKit

/// Draws a window into a PNG without the window server, so it works with the screen locked and for windows that were
/// never shown (`-debugOffscreen`). Title bar and toolbar come along. What draws no background of its own lands on the
/// window's background color; `cornerRadius` rounds that for the borderless panel, whose glass doesn't draw this way.
enum Snapshot {
    enum Failure: Error {
        case noWindow, noBitmap
    }

    static func write(_ window: NSWindow?, to url: URL, cornerRadius: CGFloat = 0) throws {
        guard let window, let content = window.contentView else { throw Failure.noWindow }
        if UserDefaults.standard.bool(forKey: "debugCapture"), window.isVisible {
            try capture(window, to: url)
            if let path = UserDefaults.standard.string(forKey: "debugAccessibility") {
                try writeAccessibility(window, to: URL(fileURLWithPath: path))
            }
            return
        }
        let view = cornerRadius > 0 ? content : (content.superview ?? content)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure.noBitmap }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                            pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure.noBitmap }
        output.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: cornerRadius,
                         yRadius: cornerRadius).fill()
        }
        image.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = output.representation(using: .png, properties: [:]) else { throw Failure.noBitmap }
        try png.write(to: url)
        if let path = UserDefaults.standard.string(forKey: "debugAccessibility") {
            try writeAccessibility(window, to: URL(fileURLWithPath: path))
        }
    }

    /// Records actual native controls and bounds. Bitmap captures cannot validate glass compositing.
    private static func writeAccessibility(_ window: NSWindow, to url: URL) throws {
        struct Element: Encodable {
            let type: String
            let role: String
            let label: String
            let enabled: Bool
            let frame: [Double]
            let children: [Element]
        }
        struct Inventory: Encodable {
            let title: String
            let contentFrame: [Double]
            let root: Element?
        }
        func rect(_ frame: NSRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height] }
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: Any, depth: Int = 0) -> Element? {
            guard depth < 60, let node = object as? NSObject,
                  visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            let element = node as? any NSAccessibilityProtocol
            // Some SwiftUI accessibility wrappers expose the official informal API rather than
            // the full protocol. Keep this compatibility path confined to the diagnostic collector.
            let attributes = Set(node.accessibilityAttributeNames())
            func attribute(_ key: NSAccessibility.Attribute) -> Any? {
                attributes.contains(key) ? node.accessibilityAttributeValue(key) : nil
            }
            let label = [element?.accessibilityLabel(), element?.accessibilityTitle(), element?.accessibilityValue() as? String,
                         attribute(.description) as? String, attribute(.title) as? String, attribute(.value) as? String]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
            var children = element?.accessibilityChildren() ?? attribute(.children) as? [Any] ?? []
            if let view = object as? NSView { children += view.subviews }
            let position = (attribute(.position) as? NSValue)?.pointValue ?? .zero
            let size = (attribute(.size) as? NSValue)?.sizeValue ?? .zero
            let frame = element?.accessibilityFrame() ?? NSRect(origin: position, size: size)
            return Element(type: String(reflecting: Swift.type(of: object)),
                           role: element?.accessibilityRole()?.rawValue ?? attribute(.role) as? String ?? "",
                           label: label, enabled: element?.isAccessibilityEnabled() ?? attribute(.enabled) as? Bool ?? false,
                           frame: rect(frame), children: children.compactMap { walk($0, depth: depth + 1) })
        }
        let inventory = Inventory(title: window.title,
                                  contentFrame: rect(window.convertToScreen(window.contentLayoutRect)), root: walk(window))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(inventory).write(to: url)
    }

    /// A window that's on screen, as the window server shows it, content drawn by other processes included (Quick
    /// Look's previews are). An app may always capture its own windows. CGWindowListCreateImage is gone from the
    /// SDK's Swift interface, hence the lookup.
    static func capture(_ window: NSWindow, to url: URL) throws {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw Failure.noBitmap }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        guard let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure.noBitmap }
        try png.write(to: url)
    }
}
