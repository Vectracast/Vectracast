import AppKit

/// Generic list-detail renderer; no plugin-specific matching or metadata rules.
final class PluginDetailView: FlippedView {
    private let previewScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let metadataScroll = NSScrollView()
    private let metadataView = FlippedView()
    private let divider = NSBox()
    private let empty = NSTextField(labelWithString: "选择一条记录查看详情")
    private var displayedContent: Data?
    private var imageRequest = UUID()
    private var fields: [ResultMetadata] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewScroll.drawsBackground = false; previewScroll.hasVerticalScroller = true; previewScroll.autohidesScrollers = true
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular); textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 15, height: 14)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        previewScroll.documentView = textView; addSubview(previewScroll)
        imageView.imageScaling = .scaleProportionallyUpOrDown; addSubview(imageView)
        divider.boxType = .separator; addSubview(divider); metadataScroll.drawsBackground = false; metadataScroll.hasVerticalScroller = true; metadataScroll.autohidesScrollers = true; metadataScroll.documentView = metadataView; addSubview(metadataScroll)
        empty.textColor = .secondaryLabelColor; empty.alignment = .center; addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError() }
    func display(_ item: ResultItem?) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let content = item.flatMap { try? encoder.encode($0) }
        guard content != displayedContent else { return }
        displayedContent = content
        imageRequest = UUID(); let request = imageRequest
        fields = item?.metadata ?? []
        textView.string = item?.preview?.text ?? item?.detail ?? ""
        textView.scrollToBeginningOfDocument(nil)
        imageView.image = nil
        imageView.isHidden = item?.preview?.historyImageID == nil
        previewScroll.isHidden = !imageView.isHidden || textView.string.isEmpty
        empty.isHidden = !previewScroll.isHidden || imageView.image != nil
        empty.stringValue = item?.preview?.historyImageID != nil && imageView.image == nil ? "正在载入图片…" : "选择一条记录查看详情"
        if let id = item?.preview?.historyImageID, let extensionID = item?.extensionID {
            ClipboardHistory.shared.loadImage(extensionID, entryID: id) { [weak self] image in
                guard let self, self.imageRequest == request else { return }
                self.imageView.image = image
                self.empty.isHidden = image != nil
                self.empty.stringValue = "图片已过期或无法读取"
            }
        } else { imageView.image = nil }
        metadataView.subviews.forEach { $0.removeFromSuperview() }
        if !fields.isEmpty {
            let header = NSTextField(labelWithString: "信息"); header.font = .systemFont(ofSize: 13, weight: .medium); header.textColor = .secondaryLabelColor
            header.frame = NSRect(x: 15, y: 15, width: 150, height: 20); metadataView.addSubview(header)
            for (index, field) in fields.enumerated() {
                let label = NSTextField(labelWithString: field.label); label.textColor = .secondaryLabelColor
                let value = NSTextField(labelWithString: field.value); value.alignment = .right; value.lineBreakMode = .byTruncatingMiddle
                label.font = .systemFont(ofSize: 13); value.font = .systemFont(ofSize: 13)
                label.frame = NSRect(x: 15, y: CGFloat(47 + index * 28), width: 100, height: 20)
                value.frame = NSRect(x: 118, y: CGFloat(47 + index * 28), width: max(0, bounds.width - 134), height: 20)
                value.autoresizingMask = [.width]; metadataView.addSubview(label); metadataView.addSubview(value)
                if index < fields.count - 1 { let line = NSBox(frame: NSRect(x: 15, y: CGFloat(71 + index * 28), width: max(0, bounds.width - 30), height: 1)); line.boxType = .separator; line.autoresizingMask = [.width]; metadataView.addSubview(line) }
            }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let metadataHeight = min(bounds.height * 0.43, fields.isEmpty ? 0 : CGFloat(54 + fields.count * 28))
        let previewHeight = bounds.height - metadataHeight
        previewScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: previewHeight)
        textView.setFrameSize(NSSize(width: bounds.width, height: max(previewHeight, textView.frame.height)))
        textView.textContainer?.containerSize = NSSize(width: max(1, bounds.width - 30), height: CGFloat.greatestFiniteMagnitude)
        imageView.frame = NSRect(x: 16, y: 16, width: max(0, bounds.width - 32), height: max(0, previewHeight - 32))
        empty.frame = NSRect(x: 10, y: max(20, previewHeight / 2 - 10), width: bounds.width - 20, height: 20)
        divider.isHidden = fields.isEmpty; divider.frame = NSRect(x: 0, y: previewHeight, width: bounds.width, height: 1)
        metadataScroll.frame = NSRect(x: 0, y: previewHeight, width: bounds.width, height: metadataHeight)
        metadataView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(metadataHeight, CGFloat(54 + fields.count * 28)))
    }
}

/// Retains native popup keyboard/menu behavior with the launcher's full-height outlined control.
final class DetailFilterCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.18).setFill(); shape.fill()
        NSColor.separatorColor.setStroke(); shape.lineWidth = 1; shape.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: rect.minX + 12, y: rect.midY - 10, width: rect.width - 42, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        let icon = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        icon?.draw(in: NSRect(x: rect.maxX - 22, y: rect.midY - 4, width: 10, height: 8), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
