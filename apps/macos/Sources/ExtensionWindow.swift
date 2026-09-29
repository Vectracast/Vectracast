import AppKit
import ServiceManagement

final class SettingsChoiceButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}

final class ExtensionWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 622), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    let table = NSTableView()
    let form = NSStackView()
    let store: ExtensionStore
    var onDeveloperWindow: ((DeveloperWindow.Kind) -> Void)?
    var onDistribution: ((Bool) -> Void)?
    var onChange: (() -> Void)?
    var onPresentationChange: ((Bool) -> Void)?
    private(set) var isPresented = false
    var onShortcut: ((String, Shortcut?) -> Bool)?
    var onImportPreferences: ((PreferenceValues) throws -> Void)?
    private var inputSources: [InputSourceController.Source] = []
    private let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 1000, height: 622))
    private let body = FlippedView(frame: NSRect(x: 0, y: 59, width: 1000, height: 563))
    private var navigation: [NSButton] = []
    private var page = "general"
    private var extensions: [InstalledExtension] = []
    private var fields: [String: NSControl] = [:]
    private let filter = NSSearchField()
    private var rendering = false
    private var contentScroll: NSScrollView?
    private var listScroll: NSScrollView?
    private var detailScroll: NSScrollView?
    private var splitLine: NSBox?
    private var preferredBodyHeight: CGFloat = 500
    private var current: InstalledExtension? { extensions.indices.contains(table.selectedRow) ? extensions[table.selectedRow] : nil }
    private let catalogService: PluginCatalogService
    private var catalogSnapshot: PluginCatalogService.Snapshot?
    private var catalogTask: Task<Void, Never>?
    private var catalogObserver: NSObjectProtocol?
    private let catalogStatus = NSTextField(labelWithString: "")
    private let catalogRefresh = NSButton(title: "检查更新", target: nil, action: nil)
    private var updatingID: String?
    private var updateMessage: [String: String] = [:]
    private var updateProgressValue: (received: Int64, expected: Int64)?
    private var updateProgressLabel: NSTextField?
    private var updateProgressBar: NSProgressIndicator?
    private let prefs = AppPreferences.shared

    init(store: ExtensionStore, catalogService: PluginCatalogService = .shared) {
        self.store = store; self.catalogService = catalogService; super.init()
        catalogRefresh.target = self; catalogRefresh.action = #selector(refreshCatalog)
        catalogRefresh.bezelStyle = .rounded; catalogRefresh.controlSize = .small
        catalogStatus.font = .systemFont(ofSize: 11); catalogStatus.textColor = .secondaryLabelColor
        catalogStatus.lineBreakMode = .byTruncatingTail
        catalogObserver = NotificationCenter.default.addObserver(forName: .init("VectracastCatalogUpdated"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.page == "extensions" else { return }; self.loadCatalog()
        }
        window.title = "Vectracast 设置"; window.isReleasedWhenClosed = false; window.delegate = self
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("LauncherSettings")
        window.contentView = root; root.addSubview(body)
        let title = NSTextField(labelWithString: "Vectracast 设置")
        title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = .secondaryLabelColor; title.alignment = .center
        title.frame = NSRect(x: 150, y: 4, width: 700, height: 18); root.addSubview(title)
        let tabs = [("general","通用","gearshape"),("extensions","扩展","puzzlepiece.extension"),("advanced","高级","slider.horizontal.3"),("about","关于","command.square")]
        for (index, item) in tabs.enumerated() {
            let button = SettingsChoiceButton(title: "", target: self, action: #selector(changePage(_:)))
            button.setAccessibilityLabel(item.1)
            button.isBordered = false; button.font = .systemFont(ofSize: 12, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier(item.0); button.frame = NSRect(x: 316 + index * 94, y: 25, width: 72, height: 47)
            // Explicit slots keep every symbol and caption on the same baseline.
            // NSButton.imageAbove uses symbol-specific cell metrics instead.
            let icon = NSImageView()
            icon.image = item.0 == "about" ? BrandAssets.menuBar : NSImage(systemSymbolName: item.2, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            icon.imageScaling = .scaleProportionallyUpOrDown; icon.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: item.1); label.font = button.font; label.textColor = .secondaryLabelColor; label.alignment = .center
            let content = NSStackView(views: [icon, label]); content.orientation = .vertical; content.alignment = .centerX; content.spacing = 4
            content.translatesAutoresizingMaskIntoConstraints = false; button.addSubview(content)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
                label.heightAnchor.constraint(equalToConstant: 15),
                content.centerXAnchor.constraint(equalTo: button.centerXAnchor), content.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            button.wantsLayer = true; button.layer?.cornerRadius = 8; root.addSubview(button); navigation.append(button)
        }
        let line = NSBox(frame: NSRect(x: 0, y: 79, width: 1000, height: 1)); line.boxType = .separator; line.autoresizingMask = [.width]; root.addSubview(line)
        filter.placeholderString = "搜索扩展或命令…"; filter.delegate = self
        table.headerView = SettingsTableHeaderView(frame: NSRect(x: 0, y: 0, width: 614, height: 28)); table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsEmptySelection = false; table.rowHeight = 40; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.style = .plain; table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = false
        table.delegate = self; table.dataSource = self
        for (key, title, width) in [("name","名称",210.0),("type","类型",65.0),("alias","关键词",145.0),("hotkey","快捷键",115.0),("enabled","启用",79.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.resizingMask = []; column.headerCell = AlignedHeaderCell(title, inset: key == "name" ? 39 : 8, centered: key == "enabled"); table.addTableColumn(column)
        }
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 12
        form.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 24, right: 8)
        form.translatesAutoresizingMaskIntoConstraints = false
        applyAppearance(); render()
    }
    deinit { if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }; catalogTask?.cancel() }
    func applyAppearance() {
        window.appearance = prefs.appearance
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for button in navigation {
            let selected = button.identifier?.rawValue == page
            button.layer?.backgroundColor = selected ? NSColor(calibratedWhite: dark ? 0 : 1, alpha: dark ? 0.18 : 0.8).cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = selected ? 1 : 0
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.setAccessibilityValue(selected ? "已选择" : "未选择")
            if let stack = button.subviews.first as? NSStackView {
                (stack.arrangedSubviews.first as? NSImageView)?.contentTintColor = selected ? .labelColor : .secondaryLabelColor
                (stack.arrangedSubviews.last as? NSTextField)?.textColor = selected ? .labelColor : .secondaryLabelColor
            }
        }
    }
    func show(_ id: String?) {
        isPresented = true; onPresentationChange?(true)
        if id != nil { page = "extensions" }
        render()
        if let id, let index = extensions.firstIndex(where: { $0.manifest.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); renderForm() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        isPresented = false; onPresentationChange?(false)
    }
    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc private func changePage(_ sender: NSButton) {
        guard page != sender.identifier!.rawValue else { return }
        page = sender.identifier!.rawValue; render(animated: true)
    }
    private func render(animated: Bool = false) {
        if animated { InterfaceMotion.fade(body) }
        rendering = true
        defer { rendering = false }
        body.subviews.forEach { $0.removeFromSuperview() }
        contentScroll = nil; listScroll = nil; detailScroll = nil; splitLine = nil
        let width = SettingsSizing.width
        root.frame.size.width = width
        body.frame = NSRect(x: 0, y: SettingsSizing.headerHeight, width: width, height: max(0, window.frame.height - SettingsSizing.headerHeight))
        for (index, button) in navigation.enumerated() { button.frame.origin.x = (width - 342) / 2 + CGFloat(index * 90) }
        applyAppearance()
        if page == "extensions" { renderExtensions(); fitExtensions(animated: animated); return }
        let scroll = NSScrollView(frame: body.bounds); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 560)); scroll.documentView = document; body.addSubview(scroll); contentScroll = scroll
        var y: CGFloat = 26
        func row(_ title: String, _ control: NSView, height: CGFloat = 32, note: String? = nil) {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .secondaryLabelColor; label.alignment = .right
            label.frame = NSRect(x: 156, y: y + 6, width: 210, height: 22); document.addSubview(label)
            control.frame = NSRect(x: 390, y: y, width: 430, height: height); document.addSubview(control); y += height + 12
            if let note {
                let text = NSTextField(wrappingLabelWithString: note); text.font = .systemFont(ofSize: 11); text.textColor = .secondaryLabelColor
                let textHeight = ceil((note as NSString).boundingRect(with: NSSize(width: 424, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!]).height) + 4
                text.frame = NSRect(x: 393, y: y - 8, width: 424, height: textHeight); document.addSubview(text); y += textHeight
            }
        }
        func divider() { let line = NSBox(frame: NSRect(x: 0, y: y + 3, width: width, height: 1)); line.boxType = .separator; document.addSubview(line); y += 25 }
        switch page {
        case "general":
            let login = check("登录时启动 Vectracast", key: "login", value: SMAppService.mainApp.status == .enabled)
            row("启动", login)
            let recorder = ShortcutRecorder(prefs.values.shortcut)
            recorder.onRecord = { [weak self] value in
                self?.onShortcut?("launcher", value) ?? false
            }
            let shortcutGroup = NSStackView(); shortcutGroup.orientation = .horizontal; shortcutGroup.spacing = 8
            shortcutGroup.addArrangedSubview(recorder); recorder.widthAnchor.constraint(equalToConstant: 320).isActive = true
            shortcutGroup.addArrangedSubview(button("恢复默认", #selector(resetShortcut)))
            row("Vectracast 快捷键", shortcutGroup, note: "点击后录制；使用 ⌘、⌃ 或 ⌥ 与其他按键组合。")
            row("菜单栏图标", check("在菜单栏显示 Vectracast", key: "menu", value: prefs.values.showMenuBar))
            divider()
            row("文字大小", segments(["标准 Aa", "较大 Aa"], key: "size", selected: prefs.values.textSize == "large" ? 1 : 0))
            row("外观", segments(["浅色", "深色", "跟随系统"], key: "appearance", selected: ["light","dark","system"].firstIndex(of: prefs.values.appearance) ?? 2), height: 78)
            row("窗口模式", segments(["标准", "紧凑"], key: "compact", selected: prefs.values.compact ? 1 : 0), height: 76, note: "紧凑模式随结果数调整高度，空搜索统一收起列表。")
            divider()
            row("窗口焦点", check("失去焦点时自动隐藏主窗口", key: "blur", value: prefs.values.hideOnBlur))
            row("复制结果后", check("自动关闭主窗口", key: "copy", value: prefs.values.closeAfterCopy))
        case "advanced":
            row("显示 Vectracast 的屏幕", popup(["鼠标所在屏幕", "主屏幕"], key: "screen", selected: prefs.values.screen == "main" ? 1 : 0))
            row("重新打开时清空搜索", popup(["立即", "90 秒后", "保留上次搜索"], key: "reset", selected: ["immediate","90","never"].firstIndex(of: prefs.values.resetSearch) ?? 1))
            row("Escape 键行为", popup(["先清空搜索，再关闭窗口", "直接关闭窗口"], key: "escape", selected: prefs.values.escape == "close" ? 1 : 0))
            inputSources = InputSourceController.available()
            row("唤起时切换输入法", popup(["保持当前输入法"] + inputSources.map(\.name), key: "inputSource", selected: inputSources.firstIndex(where: { $0.id == prefs.values.inputSource }).map { $0 + 1 } ?? 0), note: "关闭后恢复原输入法；若在窗口中手动切换，则保留你的选择。")
            row("搜索匹配", popup(["宽松 · 支持模糊匹配", "适中 · 支持首字母缩写", "严格 · 名称直接匹配"], key: "sensitivity", selected: ["low", "medium", "high"].firstIndex(of: prefs.values.searchSensitivity ?? "medium") ?? 1), note: "控制应用搜索的匹配范围，不改变输入防抖时间。")
            divider()
            let backups = NSStackView(views: [button("导入配置…", #selector(importConfiguration)), button("导出配置…", #selector(exportConfiguration))]); backups.spacing = 12
            row("配置备份", backups, note: "包含设置、快捷键、插件清单和普通配置，不含密钥。恢复前会显示预览并自动备份当前配置。")
            row("窗口截图", NSTextField(labelWithString: "主窗口按 ⇧⌘S，或在操作菜单中选择“窗口截图”"))
            row("截图输出", check("复制到剪贴板", key: "captureCopy", value: prefs.values.captureCopy ?? true))
            row("", check("保存 PNG 并在 Finder 中显示", key: "captureReveal", value: prefs.values.captureReveal ?? false), note: "仅生成 Vectracast 内容快照，使用固定背景，不包含后方桌面。")
            divider()
            row("开发模式", check("启用开发模式", key: "developerMode", value: prefs.values.developerMode ?? false))
            row("开发期间", check("失焦后仍保持主窗口可见", key: "developerKeepVisible", value: prefs.values.developerKeepVisible ?? true))
            row("", check("重新打开时保留查询", key: "developerPreserveQuery", value: prefs.values.developerPreserveQuery ?? true))
            row("保存源码后", check("自动重建并刷新开发插件", key: "developerAutoReload", value: prefs.values.developerAutoReload ?? true), note: "需先运行 platform dev。关闭后暂停自动重建，重新启用时处理等待中的修改。")
            row("构建状态", button("查看构建状态与错误", #selector(openBuilds)))
            divider()
            row("开发者工具", button("打开开发文档", #selector(openDocs)))
            row("诊断", button("打开查询日志", #selector(openLogs)), note: "日志只包含命令、耗时和状态，不保存查询内容或密钥。")
            row("本地数据", button("在 Finder 中显示数据目录", #selector(openData)))
        case "about":
            let icon = NSImageView(frame: NSRect(x: 308, y: 48, width: 86, height: 86))
            icon.image = BrandAssets.logo; icon.imageScaling = .scaleProportionallyUpOrDown; document.addSubview(icon)
            let title = NSTextField(labelWithString: "Vectracast"); title.font = .systemFont(ofSize: 24, weight: .semibold)
            title.frame = NSRect(x: 430, y: 43, width: 400, height: 32); document.addSubview(title)
            let version = NSTextField(labelWithString: "版本 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0") + " · 开发预览")
            version.font = .systemFont(ofSize: 14); version.textColor = .secondaryLabelColor; version.frame = NSRect(x: 430, y: 84, width: 410, height: 24); document.addSubview(version)
            let description = NSTextField(wrappingLabelWithString: "Cast vectors, summon anything.\n原生 macOS 插件底座")
            description.font = .systemFont(ofSize: 13); description.textColor = .secondaryLabelColor; description.frame = NSRect(x: 430, y: 116, width: 410, height: 46); document.addSubview(description)
            let line = NSBox(frame: NSRect(x: 0, y: 196, width: width, height: 1)); line.boxType = .separator; document.addSubview(line)
            let docs = button("开发文档", #selector(openDocs)); docs.frame = NSRect(x: 24, y: 211, width: 140, height: 32); document.addSubview(docs)
            let update = button("检查更新…", #selector(checkUpdates)); update.frame = NSRect(x: 180, y: 211, width: 140, height: 32); document.addSubview(update)
            let logs = button("查询日志", #selector(openLogs)); logs.frame = NSRect(x: width - 164, y: 211, width: 140, height: 32); document.addSubview(logs)
            y = 249
        default: break
        }
        preferredBodyHeight = y + 16
        fitContent(preferredBodyHeight, animated: animated)
        document.setFrameSize(NSSize(width: width, height: max(body.bounds.height, preferredBodyHeight)))
    }
    private func fitContent(_ requested: CGFloat, animated: Bool) {
        preferredBodyHeight = requested
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = SettingsSizing.height(forPage: page, body: requested, availableHeight: visible.height)
        let old = window.frame
        let top = min(visible.maxY - 20, max(old.maxY, visible.minY + 20 + height))
        let x = min(max(old.midX - SettingsSizing.width / 2, visible.minX), max(visible.minX, visible.maxX - SettingsSizing.width))
        let target = NSRect(x: x, y: top - height, width: SettingsSizing.width, height: height)
        window.setFrame(target, display: true, animate: animated && window.isVisible && target != old && InterfaceMotion.duration > 0)
        root.frame = NSRect(origin: .zero, size: target.size)
        body.frame = NSRect(x: 0, y: SettingsSizing.headerHeight, width: SettingsSizing.width, height: height - SettingsSizing.headerHeight)
        contentScroll?.frame = body.bounds
        listScroll?.frame = NSRect(x: 8, y: 78, width: 629, height: max(0, body.bounds.height - 88))
        detailScroll?.frame = NSRect(x: 675, y: 24, width: 308, height: max(0, body.bounds.height - 40))
        splitLine?.frame = NSRect(x: 650, y: 0, width: 1, height: body.bounds.height)
        let state: [String: Any] = ["page": page, "width": window.frame.width, "height": window.frame.height, "requestedBodyHeight": requested, "maximumHeight": min(SettingsSizing.maximumHeight, visible.height - 40), "top": window.frame.maxY]
        try? Data(jsonString(state).utf8).write(to: store.root.appendingPathComponent("settings-layout.json"), options: .atomic)
    }
    private func fitExtensions(animated: Bool) {
        root.layoutSubtreeIfNeeded(); form.layoutSubtreeIfNeeded()
        let listHeight = 78 + 28 + CGFloat(extensions.count) * (table.rowHeight + 1) + 16
        let detailHeight = ceil(form.fittingSize.height) + 40
        fitContent(max(280, listHeight, detailHeight), animated: animated)
    }
    func windowDidChangeScreen(_ notification: Notification) { fitContent(preferredBodyHeight, animated: false) }
    private func check(_ title: String, key: String, value: Bool) -> NSButton {
        let item = NSButton(checkboxWithTitle: title, target: self, action: #selector(togglePreference(_:))); item.identifier = NSUserInterfaceItemIdentifier(key); item.state = value ? .on : .off; item.font = .systemFont(ofSize: 13); return item
    }
    private func segments(_ titles: [String], key: String, selected: Int) -> NSView {
        let group = NSView()
        let vertical = key != "size"
        let itemWidth: CGFloat = key == "size" ? 46 : (key == "appearance" ? 90 : 112)
        let height: CGFloat = vertical ? 72 : 32
        for (index, title) in titles.enumerated() {
            let button = SettingsChoiceButton(title: "", target: self, action: #selector(choiceChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(key); button.tag = index
            button.setAccessibilityLabel(title); button.setAccessibilityValue(index == selected ? "已选择" : "未选择")
            button.isBordered = false; button.wantsLayer = true; button.layer?.cornerRadius = 9
            button.frame = NSRect(x: CGFloat(index) * (itemWidth + 12), y: 0, width: itemWidth, height: height)
            button.layer?.backgroundColor = index == selected ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = index == selected ? 1 : 0; button.layer?.borderColor = NSColor.separatorColor.cgColor
            if !vertical {
                button.title = "Aa"; button.font = .systemFont(ofSize: index == 0 ? 17 : 22, weight: .semibold)
            } else {
                let symbol = key == "appearance" ? ["sun.max", "moon", "circle.lefthalf.filled"][index] : ["rectangle.split.1x2", "rectangle.topthird.inset.filled"][index]
                let icon = NSImageView(); icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
                icon.contentTintColor = index == selected ? .labelColor : .secondaryLabelColor; icon.imageScaling = .scaleProportionallyUpOrDown
                let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: index == selected ? .semibold : .medium); label.textColor = icon.contentTintColor
                let stack = NSStackView(views: [icon, label]); stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .centerX
                stack.translatesAutoresizingMaskIntoConstraints = false; button.addSubview(stack)
                NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30), stack.centerXAnchor.constraint(equalTo: button.centerXAnchor), stack.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
            }
            group.addSubview(button)
        }
        return group
    }
    @objc private func choiceChanged(_ sender: NSButton) {
        prefs.change { v in
            switch sender.identifier?.rawValue {
            case "size": v.textSize = sender.tag == 1 ? "large" : "standard"
            case "appearance": v.appearance = ["light","dark","system"][sender.tag]
            case "compact": v.compact = sender.tag == 1
            default: break
            }
        }; render(animated: true)
    }
    private func popup(_ titles: [String], key: String, selected: Int) -> NSPopUpButton {
        let item = NSPopUpButton(); item.addItems(withTitles: titles); item.selectItem(at: selected); item.identifier = NSUserInterfaceItemIdentifier(key); item.target = self; item.action = #selector(popupChanged(_:)); return item
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let item = NSButton(title: title, target: self, action: action); item.bezelStyle = .rounded; return item }
    @objc private func resetShortcut() {
        if onShortcut?("launcher", .initial) == true { render() }
        else { notify("默认快捷键已被占用", "请录制其他组合。") }
    }
    @objc private func togglePreference(_ sender: NSButton) {
        let enabled = sender.state == .on
        if sender.identifier?.rawValue == "login" {
            do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off; notify("无法修改登录启动", error.localizedDescription) }; return
        }
        prefs.change { v in
            switch sender.identifier?.rawValue {
            case "menu": v.showMenuBar = enabled
            case "blur": v.hideOnBlur = enabled
            case "copy": v.closeAfterCopy = enabled
            case "captureCopy": v.captureCopy = enabled
            case "captureReveal": v.captureReveal = enabled
            case "developerMode": v.developerMode = enabled
            case "developerKeepVisible": v.developerKeepVisible = enabled
            case "developerPreserveQuery": v.developerPreserveQuery = enabled
            case "developerAutoReload": v.developerAutoReload = enabled
            default: break
            }
        }
    }
    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        prefs.change { v in
            switch sender.identifier?.rawValue {
            case "size": v.textSize = sender.selectedSegment == 1 ? "large" : "standard"
            case "appearance": v.appearance = ["light","dark","system"][sender.selectedSegment]
            case "compact": v.compact = sender.selectedSegment == 1
            default: break
            }
        }
    }
    @objc private func popupChanged(_ sender: NSPopUpButton) {
        prefs.change { v in
            switch sender.identifier?.rawValue {
            case "screen": v.screen = sender.indexOfSelectedItem == 1 ? "main" : "mouse"
            case "reset": v.resetSearch = ["immediate","90","never"][sender.indexOfSelectedItem]
            case "escape": v.escape = sender.indexOfSelectedItem == 1 ? "close" : "clear"
            case "inputSource": v.inputSource = sender.indexOfSelectedItem > 0 ? inputSources[sender.indexOfSelectedItem - 1].id : nil
            case "sensitivity": v.searchSensitivity = ["low", "medium", "high"][sender.indexOfSelectedItem]
            default: break
            }
        }
    }
    @objc private func openBuilds() { onDeveloperWindow?(.builds) }
    @objc private func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Vectracast-config.json"; panel.title = "导出配置（不含密钥）"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do { try ConfigurationBackup.make(store: self.store, preferences: self.prefs.values).data().write(to: url, options: .atomic); self.notify("配置已导出", "插件清单和版本已记录；插件程序与钥匙串密钥不包含在备份中。") }
            catch { self.notify("导出失败", error.localizedDescription) }
        }
    }
    @objc private func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let backup = try ConfigurationBackup.read(url)
                let skipped = backup.skipped(in: self.store)
                let alert = NSAlert(); alert.messageText = "恢复这份配置？"
                alert.informativeText = "将替换应用设置、别名和快捷键，恢复 \(backup.plugins.count - skipped.count) 个版本匹配插件的普通配置。钥匙串密钥保持不变。\n\n" + (skipped.isEmpty ? "插件版本均匹配。" : "以下插件未安装或版本不同，将跳过配置恢复：\n" + skipped.joined(separator: "\n")) + "\n\n恢复前会在数据目录保存当前配置备份。"
                alert.addButton(withTitle: "恢复配置"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let recovery = try backup.restore(store: self.store, current: self.prefs.values) { values in
                    guard let apply = self.onImportPreferences else { throw LauncherError("设置服务不可用。") }
                    try apply(values)
                }
                self.onChange?(); self.render(); self.notify("配置已恢复", "恢复前的配置保存在：\n" + recovery.path)
            } catch { self.notify("无法恢复配置", error.localizedDescription) }
        }
    }
    private func renderExtensions() {
        filter.frame = NSRect(x: 16, y: 14, width: 330, height: 28); body.addSubview(filter)
        let catalog = button("发现插件…", #selector(openCatalog)); catalog.frame = NSRect(x: 362, y: 12, width: 130, height: 32); body.addSubview(catalog)
        let install = button("安装扩展…", #selector(installPackage)); install.frame = NSRect(x: 502, y: 12, width: 130, height: 32); body.addSubview(install)
        catalogStatus.frame = NSRect(x: 20, y: 49, width: 505, height: 20); body.addSubview(catalogStatus)
        catalogRefresh.frame = NSRect(x: 538, y: 46, width: 94, height: 24); body.addSubview(catalogRefresh)
        loadCatalog()
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 78, width: 629, height: 470)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.documentView = table; body.addSubview(scroll); listScroll = scroll
        let line = NSBox(frame: NSRect(x: 650, y: 0, width: 1, height: 563)); line.boxType = .separator; body.addSubview(line); splitLine = line
        let formScroll = NSScrollView(frame: NSRect(x: 675, y: 25, width: 308, height: 520)); formScroll.hasVerticalScroller = true; formScroll.autohidesScrollers = true; formScroll.drawsBackground = false
        form.removeFromSuperview()
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(form); formScroll.documentView = document; body.addSubview(formScroll); detailScroll = formScroll
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor), form.leadingAnchor.constraint(equalTo: document.leadingAnchor), form.trailingAnchor.constraint(equalTo: document.trailingAnchor), form.topAnchor.constraint(equalTo: document.topAnchor), form.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        reloadExtensions(); if !extensions.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; renderForm()
    }
    private func reloadExtensions() {
        let selectedID = current?.manifest.id
        let text = filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        extensions = store.list().filter { text.isEmpty || ([$0.manifest.name, $0.manifest.id] + $0.manifest.commands.flatMap { [$0.title] + $0.keywords }).contains(where: { $0.localizedCaseInsensitiveContains(text) }) }; table.reloadData()
        if let selectedID, let index = extensions.firstIndex(where: { $0.manifest.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    func refreshInstalledExtensions() { if page == "extensions" { if catalogSnapshot != nil { refreshCatalogPresentation() } else { reloadExtensions(); renderForm() } } }
    func controlTextDidChange(_ obj: Notification) { guard obj.object as? NSSearchField === filter else { return }; reloadExtensions(); if !extensions.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; renderForm() }
    func controlTextDidEndEditing(_ obj: Notification) { if let field = obj.object as? NSTextField, field.identifier?.rawValue.contains("/") == true { saveAlias(field) } }
    @objc private func saveAlias(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }; let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: "^[a-z][a-z0-9-]{0,20}$", options: .regularExpression) != nil else { notify("关键词无效", "使用以字母开头的英文、数字或短横线。"); return }
        if prefs.values.aliases[key] == value { return }
        for info in store.list() where info.enabled {
            for command in info.manifest.commands where info.manifest.id + "/" + command.id != key {
                if prefs.keywords(info, command).contains(value) { notify("关键词冲突", "\(value) 已用于 \(command.title)。"); return }
            }
        }
        let selection = table.selectedRow
        prefs.change { $0.aliases[key] = value }; table.reloadData()
        if extensions.indices.contains(selection) { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        onChange?()
    }
    @objc private func clearCommandShortcut(_ sender: NSButton) { if let key = sender.identifier?.rawValue { _ = onShortcut?(key, nil); changed(current?.manifest.id) } }
    @objc private func openData() { NSWorkspace.shared.open(store.root) }
    @objc private func openLogs() { onDeveloperWindow?(.logs) }
    @objc private func refreshCatalog() { loadCatalog(force: true) }
    private func loadCatalog(force: Bool = false) {
        guard catalogTask == nil else { return }
        catalogStatus.stringValue = "正在检查插件更新…"; catalogRefresh.isEnabled = false
        catalogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.catalogTask = nil; self.catalogRefresh.isEnabled = true }
            do {
                if force { await self.catalogService.invalidate() }
                self.catalogSnapshot = try await self.catalogService.load()
                self.refreshCatalogPresentation()
            } catch { self.catalogStatus.stringValue = "检查失败，点击重试 · " + error.localizedDescription }
        }
    }
    private func refreshCatalogPresentation() {
        let count = store.list().filter { catalogSnapshot?.update(for: $0) != nil }.count
        catalogStatus.stringValue = count > 0 ? "有 \(count) 个插件可更新" : "所有商店插件均为最新版本"
        if page == "extensions" { reloadExtensions(); renderForm() }
    }
    private func compatible(_ entry: PluginIndex.Entry) -> Bool {
        guard let required = try? ReleaseVersion(entry.minimumAppVersion),
              let current = try? ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0") else { return false }
        return current >= required
    }
    @objc private func updatePlugin(_ sender: NSButton) {
        guard updatingID == nil, let id = sender.identifier?.rawValue,
              let original = store.list().first(where: { $0.manifest.id == id }), !original.development else { return }
        updatingID = id; updateProgressValue = nil; updateMessage[id] = "正在下载并校验…"
        if let row = extensions.firstIndex(where: { $0.manifest.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        }
        refreshCatalogPresentation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updatingID = nil; self.refreshCatalogPresentation() }
            do {
                // Refresh opaque handles before downloading, including after a long-open settings session.
                let snapshot = try await self.catalogService.load(); self.catalogSnapshot = snapshot
                guard let (handle, entry) = snapshot.update(for: original), self.compatible(entry) else {
                    throw LauncherError("没有兼容的更新，请检查插件目录或更新 Vectracast。")
                }
                let (data, _, _) = try await self.catalogService.download(handle) { [weak self] received, expected in
                    Task { @MainActor [weak self] in self?.recordUpdateProgress(received: received, expected: expected) }
                }
                guard let current = self.store.list().first(where: { $0.manifest.id == id }),
                      !current.development, current.manifest.version == original.manifest.version else {
                    throw LauncherError("插件状态已改变，请重新尝试更新。")
                }
                let manifest = try self.store.install(data, acceptPermissions: true)
                self.updateMessage[id] = "已更新到 v" + manifest.version; self.updateProgressValue = nil
                self.onChange?()
            } catch { self.updateMessage[id] = "更新失败：" + error.localizedDescription; self.updateProgressValue = nil }
        }
    }
    @objc private func openCatalog() { onDistribution?(true) }
    @objc private func checkUpdates() { onDistribution?(false) }
    private func label(_ value: String, size: CGFloat = 13, secondary: Bool = false) {
        let view = NSTextField(wrappingLabelWithString: value)
        view.font = .systemFont(ofSize: size, weight: size > 18 ? .semibold : .regular)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
        form.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -10).isActive = true
    }
    private func renderForm() {
        defer { if page == "extensions" && !rendering { fitExtensions(animated: window.isVisible) } }
        form.arrangedSubviews.forEach { form.removeArrangedSubview($0); $0.removeFromSuperview() }; fields = [:]
        guard let info = current else {
            let installed = !store.list().isEmpty
            label(installed ? "选择一个扩展" : "安装你的第一个扩展", size: 22)
            label(installed ? "从左侧选择扩展查看配置；没有搜索结果时可尝试其他关键词。" : "点击左上方的“安装扩展…”，或通过开发 CLI 创建并安装。", secondary: true); return
        }
        label(info.manifest.name, size: 19)
        label(info.manifest.id + " · v" + info.manifest.version + (info.development ? " · 开发模式" : " · 本地安装"), size: 11, secondary: true)
        if let message = updateMessage[info.manifest.id] { label(message, size: 12, secondary: true) }
        if let (_, entry) = catalogSnapshot?.update(for: info) {
            label("可更新 · v\(info.manifest.version) → v\(entry.manifest.version)", size: 12)
            if !compatible(entry) { label("需要 Vectracast " + entry.minimumAppVersion + " 或更新版本", size: 11, secondary: true) }
            let update = button(updatingID == info.manifest.id ? "正在更新…" : "更新插件", #selector(updatePlugin(_:)))
            update.identifier = NSUserInterfaceItemIdentifier(info.manifest.id); update.isEnabled = updatingID == nil && compatible(entry)
            form.addArrangedSubview(update)
        }
        if updatingID == info.manifest.id {
            let status = NSTextField(labelWithString: updateProgressDescription())
            status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
            form.addArrangedSubview(status); updateProgressLabel = status
            let progress = NSProgressIndicator(); progress.style = .bar; progress.maxValue = 1
            progress.isIndeterminate = (updateProgressValue?.expected ?? 0) <= 0
            if let value = updateProgressValue, value.expected > 0 {
                progress.doubleValue = min(1, Double(value.received) / Double(value.expected))
            }
            form.addArrangedSubview(progress); progress.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -15).isActive = true
            if progress.isIndeterminate { progress.startAnimation(nil) }
            updateProgressBar = progress
        } else {
            updateProgressLabel = nil; updateProgressBar = nil
        }
        label(info.manifest.description, secondary: true)
        let enabled = NSButton(checkboxWithTitle: "启用扩展", target: self, action: #selector(toggleEnabled(_:)))
        enabled.state = info.enabled ? .on : .off; form.addArrangedSubview(enabled)
        let keywords = info.manifest.commands.flatMap { AppPreferences.shared.keywords(info, $0) }
        if !keywords.isEmpty { label("关键词  " + keywords.joined(separator: "、"), size: 12) }
        label("权限", size: 14)
        label(info.manifest.permissionSummary.isEmpty ? "无外部能力" : info.manifest.permissionSummary, size: 11, secondary: true)
        for command in info.manifest.commands {
            if command.isImplicit { label("无需关键词 · 直接在主搜索框输入", size: 12, secondary: true) }
            label(command.title + " · 关键词", size: 13)
            let alias = NSTextField(string: AppPreferences.shared.keywords(info, command).first ?? "")
            alias.placeholderString = "关键词别名"; alias.identifier = NSUserInterfaceItemIdentifier(info.manifest.id + "/" + command.id)
            alias.delegate = self; alias.target = self; alias.action = #selector(saveAlias(_:)); alias.setAccessibilityLabel(command.title + "关键词")
            form.addArrangedSubview(alias); alias.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -15).isActive = true
            let key = info.manifest.id + "/" + command.id
            let hotkey = ShortcutRecorder(AppPreferences.shared.values.commandShortcuts[key])
            hotkey.onRecord = { [weak self] shortcut in
                guard let self else { return false }
                let result = self.onShortcut?(key, shortcut) ?? false
                if result { DispatchQueue.main.async { [weak self] in self?.changed(info.manifest.id) } }; return result
            }
            let group = NSStackView(); group.spacing = 6; group.addArrangedSubview(hotkey)
            let clear = NSButton(title: "清除", target: self, action: #selector(clearCommandShortcut(_:))); clear.identifier = NSUserInterfaceItemIdentifier(key); clear.bezelStyle = .rounded; group.addArrangedSubview(clear)
            form.addArrangedSubview(group)
        }
        for preference in info.manifest.preferences {
            label(preference.title + (preference.required == true ? " *" : ""), size: 12)
            let control: NSControl
            if preference.type == "dropdown" {
                let popup = NSPopUpButton()
                popup.addItems(withTitles: preference.options ?? [])
                popup.selectItem(withTitle: info.preferences[preference.name] ?? preference.defaultValue ?? "")
                control = popup
            } else {
                let field = preference.type == "secret" ? NSSecureTextField() : NSTextField()
                if preference.type != "secret" { field.stringValue = info.preferences[preference.name] ?? preference.defaultValue ?? "" }
                field.placeholderString = preference.type == "secret" ? "填写密钥；留空保留已保存的值" : preference.title
                field.font = .systemFont(ofSize: 13)
                field.setAccessibilityLabel(preference.title)
                control = field
            }
            form.addArrangedSubview(control); control.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -15).isActive = true
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
            fields[preference.name] = control
        }
        if !info.manifest.preferences.isEmpty {
            label("密钥保存在 macOS 钥匙串；查询文本不会保存为历史记录。", size: 11, secondary: true)
            let save = NSButton(title: "保存设置", target: self, action: #selector(savePreferences)); save.bezelStyle = .rounded
            form.addArrangedSubview(save)
        }
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 10
        let rollback = NSButton(title: "回滚版本", target: self, action: #selector(rollback)); rollback.bezelStyle = .rounded; rollback.isEnabled = info.previous != nil
        let uninstall = NSButton(title: "卸载…", target: self, action: #selector(uninstall)); uninstall.bezelStyle = .rounded
        actions.addArrangedSubview(rollback); actions.addArrangedSubview(uninstall); form.addArrangedSubview(actions)
        if let previous = info.previous { label("可回滚到 v" + previous, size: 11, secondary: true) }
    }
    private func updateProgressDescription() -> String {
        guard let value = updateProgressValue else { return "正在连接下载服务器…" }
        let received = ByteCountFormatter.string(fromByteCount: max(0, value.received), countStyle: .file)
        guard value.expected > 0 else { return "已下载 \(received)" }
        let expected = ByteCountFormatter.string(fromByteCount: value.expected, countStyle: .file)
        let percent = min(100, max(0, Int(Double(value.received) / Double(value.expected) * 100)))
        return "\(received) / \(expected) · \(percent)%"
    }
    private func recordUpdateProgress(received: Int64, expected: Int64) {
        guard updatingID != nil else { return }
        updateProgressValue = (max(0, received), max(0, expected))
        updateProgressLabel?.stringValue = updateProgressDescription()
        if expected > 0, let bar = updateProgressBar {
            bar.stopAnimation(nil); bar.isIndeterminate = false
            bar.doubleValue = min(1, Double(max(0, received)) / Double(expected))
        }
    }
    private func notify(_ title: String, _ message: String = "") {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    private func changed(_ id: String?) { reloadExtensions(); if let id, let index = extensions.firstIndex(where: { $0.manifest.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }; renderForm(); onChange?() }
    @objc private func savePreferences() {
        guard let info = current else { return }
        var preferences = info.preferences
        do {
            for field in info.manifest.preferences {
                let value = (fields[field.name] as? NSPopUpButton)?.titleOfSelectedItem ?? (fields[field.name] as? NSTextField)?.stringValue ?? ""
                if field.required == true && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (field.type != "secret" || Keychain.get(info.manifest.id, field.name) == nil) { throw LauncherError("请填写\(field.title)。") }
                if field.type == "secret" { if !value.isEmpty { try Keychain.set(info.manifest.id, field.name, value.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                else { preferences[field.name] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            try store.savePreferences(info.manifest.id, preferences); changed(info.manifest.id); notify("设置已保存")
        } catch { notify("无法保存", error.localizedDescription) }
    }
    @objc private func toggleEnabled(_ sender: NSButton) {
        guard let info = current else { return }
        do { try store.setEnabled(info.manifest.id, sender.state == .on); changed(info.manifest.id) } catch { sender.state = info.enabled ? .on : .off; notify("无法修改", error.localizedDescription) }
    }
    @objc private func rollback() { guard let info = current else { return }; do { try store.rollback(info.manifest.id); changed(info.manifest.id) } catch { notify("无法回滚", error.localizedDescription) } }
    @objc private func uninstall() {
        guard let info = current else { return }
        let alert = NSAlert(); alert.messageText = "卸载 \(info.manifest.name)？"; alert.informativeText = "将移除扩展、版本记录、设置和已保存的密钥。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "卸载")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            do { try self.store.uninstall(info.manifest.id); self.changed(nil) } catch { self.notify("卸载失败", error.localizedDescription) }
        }
    }
    @objc private func installPackage() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.message = "选择 .launcher-extension 本地扩展包"
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = picker.url else { return }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count < 3_000_000 else { throw LauncherError("安装包过大。") }
                let pkg = try JSONDecoder().decode(ExtensionPackage.self, from: data); try pkg.validate()
                let alert = NSAlert(); alert.messageText = "安装 \(pkg.manifest.name) v\(pkg.manifest.version)？"
                alert.informativeText = "此包来自本地，尚无商店签名。\n\n" + pkg.manifest.permissionSummary
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "安装")
                alert.beginSheetModal(for: self.window) { response in
                    guard response == .alertSecondButtonReturn else { return }
                    do { let manifest = try self.store.install(data, acceptPermissions: true); self.changed(manifest.id) }
                    catch { self.notify("安装失败", error.localizedDescription) }
                }
            } catch { self.notify("无法读取扩展", error.localizedDescription) }
        }
    }
    @objc private func openDocs() { onDeveloperWindow?(.documentation) }
    func numberOfRows(in tableView: NSTableView) -> Int { extensions.count }
    func tableViewSelectionDidChange(_ notification: Notification) { renderForm() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard extensions.indices.contains(row) else { return nil }
        let info = extensions[row]; let cell = NSTableCellView()
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "enabled":
            let item = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
            item.translatesAutoresizingMaskIntoConstraints = false; item.identifier = NSUserInterfaceItemIdentifier(info.manifest.id); item.state = info.enabled ? .on : .off; item.setAccessibilityLabel("启用" + info.manifest.name); cell.addSubview(item); NSLayoutConstraint.activate([item.centerXAnchor.constraint(equalTo: cell.centerXAnchor), item.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]); return cell
        case "type":
            if let (_, entry) = catalogSnapshot?.update(for: info) {
                let update = button(updatingID == info.manifest.id ? "更新中" : "更新", #selector(updatePlugin(_:)))
                update.identifier = NSUserInterfaceItemIdentifier(info.manifest.id)
                update.isEnabled = updatingID == nil && compatible(entry)
                update.toolTip = "v\(info.manifest.version) → v\(entry.manifest.version)" + (compatible(entry) ? "" : " · 请先更新 Vectracast")
                update.setAccessibilityLabel("更新" + info.manifest.name + "到" + entry.manifest.version)
                update.frame = NSRect(x: 2, y: 6, width: 61, height: 28); cell.addSubview(update); return cell
            }
            value = info.development ? "开发扩展" : "扩展"
        case "alias":
            let keywords = info.manifest.commands.flatMap { prefs.keywords(info, $0) }
            value = ((info.manifest.commands.contains(where: \.isImplicit) ? ["直接输入"] : []) + keywords).joined(separator: " · ")
        case "hotkey": value = info.manifest.commands.compactMap { prefs.values.commandShortcuts[info.manifest.id + "/" + $0.id]?.label }.first ?? "—"
        default:
            let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 20, height: 20)); icon.image = NSImage(systemSymbolName: info.manifest.icon, accessibilityDescription: nil); icon.contentTintColor = info.manifest.id == "local.youdao" ? .systemRed : .systemBlue; cell.addSubview(icon)
            let text = NSTextField(labelWithString: info.manifest.name); text.font = .systemFont(ofSize: 13, weight: .medium); let hasUpdate = catalogSnapshot?.update(for: info) != nil
            text.frame = NSRect(x: 39, y: 10, width: (tableColumn?.width ?? 210) - (hasUpdate ? 101 : 47), height: 20); text.lineBreakMode = .byTruncatingTail; cell.addSubview(text)
            if hasUpdate {
                let badge = NSTextField(labelWithString: "有更新"); badge.font = .systemFont(ofSize: 10, weight: .medium); badge.textColor = .systemBlue
                badge.frame = NSRect(x: (tableColumn?.width ?? 210) - 56, y: 12, width: 50, height: 17); cell.addSubview(badge)
            }
            return cell
        }
        let text = NSTextField(labelWithString: value); text.font = .systemFont(ofSize: 12); text.textColor = .secondaryLabelColor; text.frame = NSRect(x: 8, y: 10, width: (tableColumn?.width ?? 90) - 16, height: 20); text.lineBreakMode = .byTruncatingTail; cell.addSubview(text); return cell
    }
    @objc private func toggleRow(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do { try store.setEnabled(id, sender.state == .on); changed(id) } catch { sender.state = sender.state == .on ? .off : .on; notify("无法修改", error.localizedDescription) }
    }
}
