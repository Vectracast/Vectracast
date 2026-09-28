import AppKit

final class LauncherDragGuides {
    private let panel: NSPanel
    private let guides = GuideView()
    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = guides
    }
    func show(screen: NSScreen, frame: NSRect, snap: LauncherPlacement.Snap) {
        panel.setFrame(screen.frame, display: false)
        guides.area = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        guides.launcher = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        guides.snap = snap; guides.needsDisplay = true
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

private final class GuideView: NSView {
    var area = NSRect.zero
    var launcher = NSRect.zero
    var snap = LauncherPlacement.Snap()
    override func draw(_ dirtyRect: NSRect) {
        let x = area.midX, y = area.maxY - LauncherPlacement.defaultTop(area)
        func line(_ start: NSPoint, _ end: NSPoint, active: Bool) {
            let path = NSBezierPath(); path.move(to: start); path.line(to: end)
            path.lineWidth = 1
            path.setLineDash([5, 6], count: 2, phase: 0)
            (active ? NSColor.systemBlue.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.28)).setStroke()
            path.stroke()
        }
        // Aligned edges make the horizontal center target visible without crossing the text.
        for edge in [x - launcher.width / 2, x + launcher.width / 2] {
            line(NSPoint(x: edge, y: area.minY), NSPoint(x: edge, y: area.maxY), active: snap.horizontal)
        }
        line(NSPoint(x: area.minX, y: y), NSPoint(x: area.maxX, y: y), active: snap.vertical)
        if snap.horizontal || snap.vertical {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.systemBlue.withAlphaComponent(0.65)
            shadow.shadowBlurRadius = 12; shadow.shadowOffset = .zero; shadow.set()
            let outline = NSBezierPath(roundedRect: launcher.insetBy(dx: -2, dy: -2), xRadius: 16, yRadius: 16)
            outline.lineWidth = 2; NSColor.systemBlue.withAlphaComponent(0.85).setStroke(); outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
