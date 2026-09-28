import AppKit

/// Full-page rendering for any plugin result. Content and actions remain plugin-owned.
final class PluginPageView: FlippedView {
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var item: ResultItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = document; addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    func display(_ item: ResultItem) { self.item = item; rebuild(); scroll.contentView.scroll(to: .zero) }
    override func layout() { super.layout(); scroll.frame = bounds; rebuild() }
    private func rebuild() {
        guard let item else { return }
        document.subviews.forEach { $0.removeFromSuperview() }
        let width = max(400, bounds.width), side: CGFloat = 224, left = width - side - 72
        let icon = NSImageView(frame: NSRect(x: 28, y: 26, width: 62, height: 62))
        icon.image = NSImage(systemSymbolName: item.icon ?? "puzzlepiece.extension", accessibilityDescription: nil); icon.contentTintColor = .controlAccentColor; document.addSubview(icon)
        let title = NSTextField(wrappingLabelWithString: item.title); title.font = .systemFont(ofSize: 23, weight: .semibold)
        title.frame = NSRect(x: 112, y: 25, width: width - 144, height: 35); document.addSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: item.subtitle ?? ""); subtitle.font = .systemFont(ofSize: 13); subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 112, y: 65, width: width - 144, height: 44); document.addSubview(subtitle)
        let line = NSBox(frame: NSRect(x: 28, y: 124, width: width - 56, height: 1)); line.boxType = .separator; document.addSubview(line)
        let text = NSTextField(wrappingLabelWithString: item.preview?.text ?? item.detail ?? "")
        text.isSelectable = true; text.font = .systemFont(ofSize: 14)
        let height = max(200, text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: left, height: .greatestFiniteMagnitude)).height ?? 200)
        text.frame = NSRect(x: 28, y: 148, width: left, height: height); document.addSubview(text)
        let fields = item.metadata ?? []
        for (index, field) in fields.enumerated() {
            let y = CGFloat(148 + index * 65)
            let label = NSTextField(labelWithString: field.label); label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: width - side - 20, y: y, width: side, height: 20); document.addSubview(label)
            let value = NSTextField(wrappingLabelWithString: field.value); value.font = .systemFont(ofSize: 14); value.isSelectable = true
            value.frame = NSRect(x: width - side - 20, y: y + 24, width: side, height: 36); document.addSubview(value)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, max(180 + height, CGFloat(170 + fields.count * 65))))
    }
}
