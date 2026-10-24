import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Resources/AppIcon/morrow-icon.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Missing app icon source at \(sourceURL.path)")
}
guard let symbol = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon/reveal-symbol.png")) else {
    fatalError("Render the shared Reveal artwork first; see Resources/AppIcon/README.md")
}

func pngData(size: Int, overlay: String? = nil, forTray: Bool = false) -> Data {
    let pixels = size
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    (forTray ? symbol : source).draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    if overlay == "dim" {
        context.compositingOperation = .sourceAtop
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(rect: bounds).fill()
    } else if overlay == "paused" {
        let scale = CGFloat(pixels) / 1024
        NSColor(calibratedRed: 0.40, green: 0.12, blue: 0.15, alpha: 1).setFill()
        for x in [CGFloat(442), 528] {
            NSBezierPath(roundedRect: NSRect(x: x * scale, y: 420 * scale,
                                             width: 54 * scale, height: 184 * scale),
                         xRadius: 24 * scale, yRadius: 24 * scale).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func writePNG(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

let appIconDirectory = root.appendingPathComponent("Resources/AppIcon")
let traySize = 128
try writePNG(pngData(size: traySize, forTray: true), to: appIconDirectory.appendingPathComponent("tray.png"))
try writePNG(pngData(size: traySize, overlay: "dim", forTray: true), to: appIconDirectory.appendingPathComponent("tray-dim.png"))
try writePNG(pngData(size: traySize, overlay: "paused", forTray: true), to: appIconDirectory.appendingPathComponent("tray-paused.png"))

let shellIcons = root.appendingPathComponent("shell/src-tauri/icons")
for (name, size) in [("32x32.png", 32), ("128x128.png", 128), ("128x128@2x.png", 256), ("icon.png", 512)] {
    try writePNG(pngData(size: size), to: shellIcons.appendingPathComponent(name))
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for (name, size) in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
] {
    try writePNG(pngData(size: size), to: iconset.appendingPathComponent(name))
}

func makeICNS(_ output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "MorrowIcon", code: Int(process.terminationStatus)) }
}

try makeICNS(root.appendingPathComponent("Resources/AppIcon.icns"))
try makeICNS(shellIcons.appendingPathComponent("icon.icns"))
try writePNG(pngData(size: 256), to: shellIcons.appendingPathComponent("128x128@2x.png"))

// Windows accepts PNG-compressed frames inside an ICO. Use the 256 px PNG as its single high-resolution frame.
let icoPNG = try Data(contentsOf: shellIcons.appendingPathComponent("128x128@2x.png"))
var ico = Data([0, 0, 1, 0, 1, 0])
func appendLE32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}
var directory = Data([0, 0, 0, 0, 1, 0, 32, 0])
appendLE32(UInt32(icoPNG.count), to: &directory)
appendLE32(22, to: &directory)
ico.append(directory)
ico.append(icoPNG)
try ico.write(to: shellIcons.appendingPathComponent("icon.ico"), options: .atomic)
