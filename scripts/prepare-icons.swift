import AppKit

// Package the approved transparent artwork without changing its alpha or geometry.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = root.appendingPathComponent("assets/branding")
let output = root.appendingPathComponent("build/branding")
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func load(_ name: String) throws -> NSImage {
    let data = try Data(contentsOf: assets.appendingPathComponent(name))
    guard let bitmap = NSBitmapImageRep(data: data), bitmap.hasAlpha,
          bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0,
          let image = NSImage(data: data) else { fatalError("Artwork requires a transparent alpha channel: \(name)") }
    return image
}

func render(_ image: NSImage, pixels: Int, background: NSColor? = nil) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context; context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill(); rect.fill(using: .copy)
    if let background { background.setFill(); rect.fill() }
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func save(_ bitmap: NSBitmapImageRep, _ url: URL) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let logo = try load("vectracast-logo.png")
for size in [16, 32, 128, 256, 512] {
    try save(render(logo, pixels: size), iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try save(render(logo, pixels: size * 2), iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let menu = try load("vectracast-menu-template.png")
for scale in 1...3 {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try save(render(menu, pixels: 18 * scale), output.appendingPathComponent("MenuBarTemplate\(suffix).png"))
}
// Review-only preview of the template artwork against white.
try save(render(menu, pixels: 216, background: .white), output.appendingPathComponent("menu-preview.png"))
print("Prepared application icon sizes and 18pt menu template (1x/2x/3x).")
