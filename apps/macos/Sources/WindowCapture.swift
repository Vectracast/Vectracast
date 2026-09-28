import AppKit

enum WindowCapture {
    static func png(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // An opaque temporary surface avoids the gray placeholder produced when
        // AppKit caches a visual-effect backdrop. Restore the same controls immediately.
        let surface = CaptureSurface(frame: view.bounds)
        surface.appearance = view.effectiveAppearance
        surface.color = dark ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1) : .windowBackgroundColor
        let children = view.subviews
        view.addSubview(surface)
        for child in children { surface.addSubview(child) }
        defer {
            for child in children { view.addSubview(child) }
            surface.removeFromSuperview()
        }
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { throw LauncherError("无法创建窗口截图。") }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LauncherError("截图编码失败。") }
        return data
    }
}

private final class CaptureSurface: NSView {
    var color = NSColor.windowBackgroundColor
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
