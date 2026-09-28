import AppKit

/// Updates the platform itself. Plugin discovery is provided by the separately packaged store plugin.
final class DistributionWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextView()
    private let action = NSButton(title: "下载新版", target: nil, action: nil)
    private let refresh = NSButton(title: "检查更新", target: nil, action: nil)
    private var downloadURL: URL?
    private var generation = 0
    private var request: Task<Void, Never>?
    private var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0" }
    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 500), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Vectracast 检查更新"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 860, height: 500)); window.contentView = root
        let title = NSTextField(labelWithString: "Vectracast"); title.font = .systemFont(ofSize: 20, weight: .semibold); title.frame = NSRect(x: 20, y: 20, width: 450, height: 28); root.addSubview(title)
        let version = NSTextField(labelWithString: "当前版本 \(currentVersion)"); version.textColor = .secondaryLabelColor; version.frame = NSRect(x: 20, y: 54, width: 450, height: 22); root.addSubview(version)
        refresh.frame = NSRect(x: 718, y: 17, width: 120, height: 30); refresh.target = self; refresh.action = #selector(loadRepository); root.addSubview(refresh)
        status.frame = NSRect(x: 20, y: 85, width: 820, height: 24); status.textColor = .secondaryLabelColor; root.addSubview(status)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 116, width: 820, height: 314)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        detail.isEditable = false; detail.isSelectable = true; detail.drawsBackground = false; detail.font = .systemFont(ofSize: 14)
        detail.textContainerInset = NSSize(width: 10, height: 10); detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false; detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        detail.frame = NSRect(origin: .zero, size: scroll.contentSize); scroll.documentView = detail; root.addSubview(scroll)
        action.frame = NSRect(x: 644, y: 445, width: 196, height: 32); action.target = self; action.action = #selector(download); action.isEnabled = false; root.addSubview(action)
    }
    func show() {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        loadRepository()
    }
    func windowWillClose(_ notification: Notification) { generation += 1; request?.cancel(); refresh.isEnabled = true }
    @objc private func download() { if let downloadURL { NSWorkspace.shared.open(downloadURL) } }
    @objc private func loadRepository() {
        generation += 1; request?.cancel(); downloadURL = nil; action.isEnabled = false; detail.string = ""
        do {
            let repo = try PublicRepository(DistributionSource.appRepository), token = generation
            refresh.isEnabled = false; status.stringValue = "正在检查更新…"
            request = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let latest = try await DistributionSource.latest(repo)
                    guard !Task.isCancelled, token == self.generation else { return }
                    let version = try ReleaseVersion(latest.tag_name), current = try ReleaseVersion(self.currentVersion)
                    self.status.stringValue = version > current ? "发现新版 \(version.description)" : "你使用的已是最新版本"
                    self.detail.string = "版本 \(version.description)\n\n" + (latest.body?.isEmpty == false ? latest.body! : "此版本未提供更新说明。")
                    if version > current { self.downloadURL = try latest.asset("Vectracast-\(version.description)-macOS-arm64.zip", repository: repo, limit: 500_000_000); self.action.isEnabled = true }
                    self.refresh.isEnabled = true
                } catch { guard token == self.generation, !Task.isCancelled else { return }; self.refresh.isEnabled = true; self.status.stringValue = "读取失败：" + error.localizedDescription }
            }
        } catch { refresh.isEnabled = true; status.stringValue = error.localizedDescription }
    }
}
