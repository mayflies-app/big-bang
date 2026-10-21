import AppKit

// Code-native artwork: the app's existing text.quote symbol with a small processing spark.
// Render every icon size from the vector symbols, avoiding scaled-up bitmap artwork.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift tools/make-icon.swift <iconset directory> <1024pt preview.png>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let preview = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func symbol(_ name: String, color: NSColor, in frame: NSRect) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let image = base.withSymbolConfiguration(.init(paletteColors: [color])) else {
        fatalError("System symbol unavailable: \(name)")
    }
    let ratio = min(frame.width / image.size.width, frame.height / image.size.height)
    let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
    image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                         width: size.width, height: size.height))
}
func render(_ size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon canvas") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 106, width: 832, height: 832), xRadius: 188, yRadius: 188)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0xF2F5FA).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFDFEFF), ending: color(0xE4EAF3))!.draw(in: tile, angle: -60)
    color(0xD6DEE9).withAlphaComponent(0.7).setStroke()
    tile.lineWidth = 2; tile.stroke()
    symbol("text.quote", color: color(0x303A49), in: NSRect(x: 254, y: 296, width: 488, height: 400))
    symbol("sparkle", color: color(0x6E94D6), in: NSRect(x: 664, y: 686, width: 116, height: 134))
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return png
}
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in variants { try render(size).write(to: directory.appendingPathComponent(name), options: .atomic) }
try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
try render(1024).write(to: preview, options: .atomic)
print("Rendered app icon at 16–1024 px")
