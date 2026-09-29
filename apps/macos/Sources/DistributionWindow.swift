import AppKit
import Sparkle

/// Updates the platform itself. Plugin discovery is provided by the separately packaged store plugin.
final class DistributionWindow: NSObject, NSWindowDelegate, SPUUserDriver {
    let window: NSWindow
    private let status = NSTextField(labelWithString: "正在检查更新")
    private let subtitle = NSTextField(labelWithString: "正在获取最新版本信息…")
    private let notesTitle = NSTextField(labelWithString: "更新说明")
    private let detail = NSTextView()
    private let action = NSButton(title: "下载更新", target: nil, action: nil)
    private let refresh = NSButton(title: "重新检查", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let stateIcon = NSImageView()
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
    private var started = false
    private var cancelUpdate: (() -> Void)?
    private var chooseUpdate: ((SPUUserUpdateChoice) -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var installRequested = false
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
        refresh.frame = NSRect(x: 26, y: 469, width: 105, height: 28); refresh.bezelStyle = .rounded; refresh.target = self; refresh.action = #selector(refreshOrCancel); root.addSubview(refresh)
        action.frame = NSRect(x: 426, y: 469, width: 128, height: 28); action.bezelStyle = .rounded; action.target = self; action.action = #selector(download); action.isHidden = true; root.addSubview(action)
    }
    func show() {
        showUpdateInFocus()
        if !updater.sessionInProgress { loadRepository() }
    }
    func windowWillClose(_ notification: Notification) {
        // Closing a check/download cancels it; an installation already handed to Sparkle may finish.
        if let cancel = cancelUpdate { clearCallbacks(); cancel() }
        else if let reply = chooseUpdate { clearCallbacks(); reply(.dismiss) }
    }
    @objc private func download() {
        guard let reply = chooseUpdate else { return }
        chooseUpdate = nil; installRequested = true; action.isHidden = true
        reply(.install)
    }
    @objc private func refreshOrCancel() {
        if let cancel = cancelUpdate {
            clearCallbacks(); cancel()
            setState("已取消更新", "可以随时重新检查。", symbol: "pause.circle", color: .secondaryLabelColor)
        } else { loadRepository() }
    }
    private func clearCallbacks() { cancelUpdate = nil; chooseUpdate = nil }
    private func busy(_ cancellable: (() -> Void)? = nil) {
        cancelUpdate = cancellable; action.isHidden = true
        refresh.title = cancellable == nil ? "重新检查" : "取消"
        refresh.isEnabled = cancellable != nil
        progress.isHidden = false; progress.isIndeterminate = true; progress.startAnimation(nil)
    }
    private func idle() {
        clearCallbacks(); progress.stopAnimation(nil); progress.isHidden = true
        action.isHidden = true; refresh.title = "重新检查"; refresh.isEnabled = true
    }
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
    private func loadRepository() {
        guard !updater.sessionInProgress else { return }
        installRequested = false
        do {
            if !started { try updater.start(); started = true }
            updater.checkForUpdates()
        } catch { showUpdaterError(error, acknowledgement: {}) }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Updates are explicitly initiated from Settings/the menu, with no background telemetry.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        busy(cancellation)
        setState("正在检查更新", "正在获取并验证更新信息…", symbol: "arrow.triangle.2.circlepath", color: .secondaryLabelColor)
        renderNotes("版本信息加载后，更新内容会显示在这里。")
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        idle()
        notesTitle.stringValue = "版本 \(appcastItem.displayVersionString) · 更新说明"
        renderNotes(appcastItem.itemDescription ?? "此版本暂无更新说明。")
        if appcastItem.isInformationOnlyUpdate {
            setState("此版本需要手动安装", "请前往项目的发布页面查看说明。", symbol: "info.circle", color: .secondaryLabelColor)
            reply(.dismiss); return
        }
        setState("新版本 \(appcastItem.displayVersionString) 已就绪", "更新将自动安装并重启，设置和插件会保留。", symbol: "arrow.down.circle.fill", color: .controlAccentColor)
        chooseUpdate = reply; refresh.isEnabled = false
        action.title = "更新并重启"; action.isHidden = false
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        renderNotes(String(data: downloadData.data, encoding: .utf8) ?? "无法显示更新说明。")
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { renderNotes("暂时无法加载更新说明。") }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        idle()
        let value = error as NSError
        setState("暂无可安装的更新", value.localizedDescription, symbol: "checkmark.circle", color: .secondaryLabelColor)
        if let latest = value.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem {
            notesTitle.stringValue = "版本 \(latest.displayVersionString) · 更新说明"
            renderNotes(latest.itemDescription ?? "此版本暂无更新说明。")
            if latest.versionString == Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                setState("已是最新版本", "Vectracast \(currentVersion) · 无需更新", symbol: "checkmark.circle.fill", color: .systemGreen)
            }
        }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        idle(); installRequested = false
        setState("更新未完成", error.localizedDescription, symbol: "exclamationmark.circle", color: .systemOrange)
        subtitle.toolTip = (error as NSError).localizedRecoverySuggestion ?? error.localizedDescription
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0; receivedBytes = 0; busy(cancellation)
        setState("正在下载更新", "正在连接下载服务器…", symbol: "arrow.down.circle", color: .controlAccentColor)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength; updateDownloadProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes = receivedBytes.addingReportingOverflow(length).overflow ? UInt64.max : receivedBytes + length
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        let downloaded = ByteCountFormatter.string(fromByteCount: Int64(clamping: receivedBytes), countStyle: .file)
        if expectedBytes > 0 {
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.maxValue = 1
            progress.doubleValue = min(1, Double(receivedBytes) / Double(expectedBytes))
            let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: expectedBytes), countStyle: .file)
            subtitle.stringValue = "\(downloaded) / \(total) · \(Int(progress.doubleValue * 100))%"
        } else { subtitle.stringValue = "已下载 \(downloaded)" }
    }
    func showDownloadDidStartExtractingUpdate() {
        busy()
        setState("正在准备安装", "验证更新包并解压文件…", symbol: "shippingbox", color: .controlAccentColor)
    }
    func showExtractionReceivedProgress(_ value: Double) {
        progress.stopAnimation(nil); progress.isIndeterminate = false; progress.maxValue = 1
        progress.doubleValue = value.isFinite ? max(0, min(1, value)) : 0
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The user already chose “更新并重启”; only Sparkle's verified ready state can trigger installation.
        if installRequested { reply(.install) }
        else {
            idle(); chooseUpdate = reply; action.title = "安装并重启"; action.isHidden = false; refresh.isEnabled = false
            setState("更新已准备好", "安装后将重新打开 Vectracast。", symbol: "checkmark.circle", color: .systemGreen)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        busy()
        setState("正在安装更新", "Vectracast 即将重新启动…", symbol: "arrow.triangle.2.circlepath", color: .controlAccentColor)
        if !applicationTerminated { action.title = "重新启动"; action.isHidden = false; chooseUpdate = { choice in if choice == .install { retryTerminatingApplication() } } }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        idle(); setState("更新已安装", "可以继续使用 Vectracast。", symbol: "checkmark.circle.fill", color: .systemGreen); acknowledgement()
    }
    func dismissUpdateInstallation() { idle(); installRequested = false }
    func showUpdateInFocus() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
