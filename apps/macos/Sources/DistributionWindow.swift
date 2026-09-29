import AppKit

/// Updates the platform itself. Plugin discovery is provided by the separately packaged store plugin.
final class DistributionWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let status = NSTextField(labelWithString: "正在检查更新")
    private let subtitle = NSTextField(labelWithString: "正在获取最新版本信息…")
    private let notesTitle = NSTextField(labelWithString: "更新说明")
    private let detail = NSTextView()
    private let action = NSButton(title: "下载更新", target: nil, action: nil)
    private let refresh = NSButton(title: "重新检查", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let stateIcon = NSImageView()
    private var downloadURL: URL?
    private var generation = 0
    private var request: Task<Void, Never>?
    private var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0" }
    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "软件更新"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.titlebarAppearsTransparent = true
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 580, height: 510)); window.contentView = root
        let logo = NSImageView(frame: NSRect(x: 28, y: 22, width: 56, height: 56)); logo.image = BrandAssets.logo; logo.imageScaling = .scaleProportionallyUpOrDown; root.addSubview(logo)
        let title = NSTextField(labelWithString: "Vectracast"); title.font = .systemFont(ofSize: 22, weight: .semibold); title.frame = NSRect(x: 100, y: 25, width: 420, height: 28); root.addSubview(title)
        let version = NSTextField(labelWithString: "当前版本 \(currentVersion)"); version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor; version.frame = NSRect(x: 101, y: 58, width: 400, height: 18); root.addSubview(version)
        let card = FlippedView(frame: NSRect(x: 28, y: 100, width: 524, height: 82)); card.wantsLayer = true; card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor; root.addSubview(card)
        stateIcon.frame = NSRect(x: 18, y: 28, width: 25, height: 25); card.addSubview(stateIcon)
        status.font = .systemFont(ofSize: 15, weight: .semibold); status.frame = NSRect(x: 56, y: 16, width: 450, height: 23); card.addSubview(status)
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor; subtitle.frame = NSRect(x: 56, y: 44, width: 450, height: 22); subtitle.lineBreakMode = .byTruncatingTail; card.addSubview(subtitle)
        progress.style = .bar; progress.isIndeterminate = true; progress.frame = NSRect(x: 28, y: 189, width: 524, height: 5); root.addSubview(progress)
        notesTitle.font = .systemFont(ofSize: 12, weight: .semibold); notesTitle.textColor = .secondaryLabelColor; notesTitle.frame = NSRect(x: 28, y: 210, width: 524, height: 20); root.addSubview(notesTitle)
        let scroll = NSScrollView(frame: NSRect(x: 26, y: 240, width: 528, height: 200)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        detail.isEditable = false; detail.isSelectable = true; detail.drawsBackground = false; detail.textColor = .labelColor
        detail.textContainerInset = NSSize(width: 2, height: 0); detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false; detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        detail.frame = NSRect(origin: .zero, size: scroll.contentSize); scroll.documentView = detail; root.addSubview(scroll)
        let line = NSBox(); line.boxType = .separator; line.frame = NSRect(x: 0, y: 456, width: 580, height: 1); root.addSubview(line)
        refresh.frame = NSRect(x: 26, y: 469, width: 105, height: 28); refresh.bezelStyle = .rounded; refresh.target = self; refresh.action = #selector(loadRepository); root.addSubview(refresh)
        action.frame = NSRect(x: 426, y: 469, width: 128, height: 28); action.bezelStyle = .rounded; action.target = self; action.action = #selector(download); action.isHidden = true; root.addSubview(action)
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); loadRepository() }
    func windowWillClose(_ notification: Notification) { generation += 1; request?.cancel(); progress.stopAnimation(nil); refresh.isEnabled = true }
    @objc private func download() { if let downloadURL { if let url = try? DistributionSource.transportURL(downloadURL) { NSWorkspace.shared.open(url) } } }
    private func setState(_ title: String, _ message: String, symbol: String, color: NSColor) {
        status.stringValue = title; subtitle.stringValue = message
        stateIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); stateIcon.contentTintColor = color
    }
    private func renderNotes(_ text: String) {
        let result = NSMutableAttributedString()
        for line in text.components(separatedBy: .newlines) {
            let heading = line.hasPrefix("#")
            let content = heading ? line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression) : line.replacingOccurrences(of: "^[-*]\\s+", with: "•  ", options: .regularExpression)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4; paragraph.paragraphSpacing = content.isEmpty ? 2 : 9
            if content.hasPrefix("•  ") { paragraph.headIndent = 14 }
            let rendered: NSMutableAttributedString
            if let parsed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { rendered = NSMutableAttributedString(attributedString: NSAttributedString(parsed)) }
            else { rendered = NSMutableAttributedString(string: content) }
            rendered.append(NSAttributedString(string: "\n"))
            rendered.addAttributes([.font: NSFont.systemFont(ofSize: heading ? 15 : 13, weight: heading ? .semibold : .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: NSRange(location: 0, length: rendered.length))
            result.append(rendered)
        }
        detail.textStorage?.setAttributedString(result); detail.scrollToBeginningOfDocument(nil)
    }
    @objc private func loadRepository() {
        generation += 1; request?.cancel(); downloadURL = nil; action.isHidden = true
        let token = generation
        refresh.isEnabled = false; progress.isHidden = false; progress.startAnimation(nil)
        setState("正在检查更新", "正在获取最新版本信息…", symbol: "arrow.triangle.2.circlepath", color: .secondaryLabelColor)
        if detail.string.isEmpty { renderNotes("版本信息加载后，更新内容会显示在这里。") }
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let repo = try PublicRepository(DistributionSource.appRepository)
                let latest = try await DistributionSource.latest(repo)
                guard !Task.isCancelled, token == self.generation else { return }
                let version = try ReleaseVersion(latest.tag_name), current = try ReleaseVersion(self.currentVersion)
                if version > current {
                    self.downloadURL = try latest.asset("Vectracast-\(version.description)-macOS-arm64.zip", repository: repo, limit: 500_000_000)
                    self.setState("新版本 \(version.description) 已就绪", "下载后替换应用，你的设置和插件会保留。", symbol: "arrow.down.circle.fill", color: .controlAccentColor)
                    self.action.isHidden = false
                } else if version == current {
                    self.setState("已是最新版本", "Vectracast \(self.currentVersion) · 无需更新", symbol: "checkmark.circle.fill", color: .systemGreen)
                } else {
                    self.setState("你正在使用较新的版本", "当前 \(self.currentVersion) · 最新公开版本 \(version.description)", symbol: "checkmark.circle.fill", color: .systemGreen)
                }
                self.notesTitle.stringValue = "版本 \(version.description) · 更新说明"
                self.renderNotes(latest.body?.isEmpty == false ? latest.body! : "此版本暂无更新说明。")
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.setState("暂时无法检查更新", "请检查网络后重试。", symbol: "exclamationmark.circle", color: .systemOrange)
                self.subtitle.toolTip = error.localizedDescription
            }
            self.refresh.isEnabled = true; self.progress.stopAnimation(nil); self.progress.isHidden = true
        }
    }
}
