import AppKit
import WebKit

/// Platform maintenance UI; feature plugins continue to use the SDK.
final class DeveloperWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate {
    enum Kind: String { case documentation, logs, builds }
    let kind: Kind
    let window: NSWindow
    var onPresentationChange: (() -> Void)?
    private(set) var isPresented = false
    private let store: ExtensionStore
    private let browser = WKWebView()
    private let picker = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var timer: Timer?
    private var rows: [[String: Any]] = []
    private var lastData = Data()
    private let pages = [("开发入门", "developer/README.md"), ("SDK API", "developer/API.md"), ("调试指南", "developer/DEBUGGING.md"), ("插件底座", "architecture/PLUGIN-FOUNDATION.md"), ("设置说明", "developer/SETTINGS.md"), ("验证记录", "developer/VALIDATION.md")]
    private var docsRoot: URL { Bundle.main.resourceURL!.appendingPathComponent("Documentation") }
    init(_ kind: Kind, store: ExtensionStore) {
        self.kind = kind; self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = kind == .documentation ? "Vectracast 开发文档" : (kind == .builds ? "Vectracast 构建状态" : "Vectracast 查询日志")
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 700, height: 460)
        window.setFrameAutosaveName("LauncherDeveloper-" + kind.rawValue)
        let root = FlippedView(); window.contentView = root
        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        if kind != .logs {
            picker.addItems(withTitles: pages.map { $0.0 }); picker.target = self; picker.action = #selector(selectPage)
            picker.setAccessibilityLabel("文档章节"); header.addArrangedSubview(picker)
            picker.widthAnchor.constraint(equalToConstant: 170).isActive = true
            status.stringValue = "SDK 0.1 · 随应用提供，可离线阅读"
            if kind == .builds { picker.isHidden = true; status.stringValue = "每秒刷新 · 显示 platform dev 的构建状态与错误" }
            browser.navigationDelegate = self
            browser.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(browser)
            NSLayoutConstraint.activate([browser.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), browser.leadingAnchor.constraint(equalTo: root.leadingAnchor), browser.trailingAnchor.constraint(equalTo: root.trailingAnchor), browser.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        } else {
            let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshLogs)); refresh.bezelStyle = .rounded
            header.addArrangedSubview(refresh)
            table.headerView = NSTableHeaderView(); table.rowHeight = 32; table.style = .plain
            table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
            table.intercellSpacing = NSSize(width: 0, height: 1)
            for (id, title, width) in [("extension", "插件", 340.0), ("command", "命令", 220.0), ("elapsedMs", "耗时", 120.0), ("status", "状态", 120.0)] {
                let col = NSTableColumn(identifier: .init(id)); col.title = title; col.width = width; col.minWidth = 80
                col.headerCell = AlignedHeaderCell(title, inset: 14); table.addTableColumn(col)
            }
            let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(scroll)
            let note = NSTextField(labelWithString: "每秒自动刷新 · 最新记录在上 · 不记录查询内容或密钥")
            note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(note)
            NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10), note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
        }
        header.addArrangedSubview(status)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 28)])
    }
    func show() {
        let first = !isPresented; isPresented = true; onPresentationChange?()
        applyAppearance()
        if kind == .documentation { if first { selectPage() } }
        else {
            refreshStatus(); timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
        }
        if first && !window.isVisible { window.center() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func applyAppearance() { window.appearance = AppPreferences.shared.appearance }
    func windowWillClose(_ notification: Notification) { isPresented = false; timer?.invalidate(); timer = nil; onPresentationChange?() }
    deinit { timer?.invalidate() }
    private func refreshStatus() {
        if kind == .logs { refreshLogs(); return }
        let directory = store.root.appendingPathComponent("development")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries = urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url), data.count < 100_000 else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let raw = Data(jsonString(entries).utf8)
        guard raw != lastData else { return }; lastData = raw
        let names = ["building":"正在构建", "ready":"构建成功", "error":"构建失败", "paused":"自动重建已暂停", "stopped":"开发进程已停止"]
        var markdown = "# 插件构建状态\n\n"
        if entries.isEmpty { markdown += "运行 `npm run platform -- dev <插件目录> --accept-permissions` 后，构建状态会显示在这里。" }
        for entry in entries {
            let date = Date(timeIntervalSince1970: (entry["updatedAt"] as? Double ?? 0) / 1000)
            markdown += "\n## \(entry["extension"] as? String ?? "插件")\n\n\(names[entry["state"] as? String ?? ""] ?? "未知状态") · \(date.formatted())\n\n"
            if let message = entry["message"] as? String, !message.isEmpty { markdown += "```\n" + message + "\n```\n" }
        }
        browser.loadHTMLString(DocumentationHTML.render(markdown), baseURL: nil)
    }
    @objc private func selectPage() { loadDocument(docsRoot.appendingPathComponent(pages[picker.indexOfSelectedItem].1)) }
    private func loadDocument(_ url: URL) {
        let local = url.standardizedFileURL
        guard local.path.hasPrefix(Bundle.main.resourceURL!.standardizedFileURL.path + "/"), local.pathExtension == "md" else { return }
        if let index = pages.firstIndex(where: { docsRoot.appendingPathComponent($0.1).path == local.path }) { picker.selectItem(at: index) }
        guard let source = try? String(contentsOf: local, encoding: .utf8) else {
            browser.loadHTMLString("<p>此文档未随当前版本提供。</p>", baseURL: nil); return
        }
        browser.loadHTMLString(DocumentationHTML.render(source), baseURL: local.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if url.isFileURL { loadDocument(url) }
        else if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    @objc private func refreshLogs() {
        let url = store.root.appendingPathComponent("runtime.jsonl")
        guard let data = try? Data(contentsOf: url) else { lastData = Data(); rows = []; table.reloadData(); status.stringValue = "暂无日志 · 执行扩展查询后会显示在这里"; return }
        guard data != lastData else { return }; lastData = data
        rows = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(500).reversed().compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], row["extension"] is String, row["command"] is String else { return nil }
            return row
        }
        table.reloadData(); status.stringValue = rows.isEmpty ? "暂无日志 · 执行扩展查询后会显示在这里" : "最近 \(rows.count) 条查询记录"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let key = tableColumn!.identifier.rawValue
        let value: String
        switch key {
        case "elapsedMs": value = (rows[row][key] as? Int).map { "\($0) ms" } ?? "—"
        case "status": value = rows[row][key] as? String == "ok" ? "成功" : "失败"
        default: value = rows[row][key] as? String ?? "—"
        }
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: value)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular); label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}

/// Small renderer for our bundled, trusted Markdown (no remote scripts or HTML).
enum DocumentationHTML {
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    static func inline(_ text: String) -> String {
        var result = escape(text)
        for (pattern, template) in [("`([^`]+)`", "<code>$1</code>"), ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"), ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>")] {
            let regex = try! NSRegularExpression(pattern: pattern)
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
    static func render(_ markdown: String) -> String {
        var html = "", code = false, table = false
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") { html += code ? "</code></pre>" : "<pre><code>"; code.toggle(); continue }
            if code { html += escape(line) + "\n"; continue }
            if line.hasPrefix("|") {
                if line.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if !table { html += "<table>"; table = true }
                html += "<tr>" + line.split(separator: "|", omittingEmptySubsequences: true).map { "<td>" + inline(String($0)) + "</td>" }.joined() + "</tr>"; continue
            }
            if table { html += "</table>"; table = false }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") { html += "<h\(hashes)>" + inline(String(line.dropFirst(hashes + 1))) + "</h\(hashes)>" }
            else if line.hasPrefix("- ") { html += "<p class='bullet'>• " + inline(String(line.dropFirst(2))) + "</p>" }
            else if !line.isEmpty { html += "<p>" + inline(line) + "</p>" }
        }
        if table { html += "</table>" }; if code { html += "</code></pre>" }
        return """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><style>
        :root{color-scheme:light dark}body{font:14px/1.75 -apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:26px 38px 60px;color:light-dark(#26282b,#e5e7eb);background:light-dark(#fafafa,#222629)}h1{font-size:26px;line-height:1.4;margin:0 0 24px}h2{font-size:19px;margin:30px 0 12px}h3{font-size:16px;margin-top:24px}p{margin:10px 0}.bullet{padding-left:14px}a{color:light-dark(#006bc7,#65b5ff)}code{font:12px/1.6 ui-monospace,SFMono-Regular,monospace;background:light-dark(#eaecef,#34383c);padding:2px 4px;border-radius:4px}pre{padding:16px;overflow:auto;border-radius:8px;background:light-dark(#eaecef,#1b1e21)}pre code{background:none;padding:0}table{border-collapse:collapse;width:100%;font-size:13px}td{border-bottom:1px solid light-dark(#d7dade,#42474c);padding:10px;text-align:left}tr:first-child{font-weight:600}
        </style><body>\(html)</body></html>
        """
    }
}
