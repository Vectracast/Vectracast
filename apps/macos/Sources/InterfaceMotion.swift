import AppKit
import QuartzCore

enum InterfaceMotion {
    static var duration: TimeInterval { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18 }
    static func fade(_ view: NSView) {
        guard duration > 0 else { return }
        view.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade; transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(transition, forKey: "contentTransition")
    }
}
final class SettingsWindow: NSWindow {
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { InterfaceMotion.duration }
}
final class AlignedHeaderCell: NSTableHeaderCell {
    let inset: CGFloat
    let centered: Bool
    init(_ title: String, inset: CGFloat = 8, centered: Bool = false) {
        self.inset = inset; self.centered = centered
        super.init(textCell: title)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
        let rect = NSRect(x: cellFrame.minX + (centered ? 0 : inset + 2), y: cellFrame.midY - 8,
                          width: cellFrame.width - (centered ? 0 : inset + 4), height: 17)
        (stringValue as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) { draw(withFrame: cellFrame, in: controlView) }
}

final class SettingsTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor(srgbRed: 0.105, green: 0.12, blue: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)).setFill()
        dirtyRect.fill()
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            column.headerCell.draw(withFrame: headerRect(ofColumn: index), in: self)
        }
    }
}
