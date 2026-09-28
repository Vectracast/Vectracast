import AppKit

final class LauncherPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var dragHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, dragHandler?(event) == true { return }
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
final class ResultTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}
class FlippedView: NSView { override var isFlipped: Bool { true } }
/// A foreground tint stays above the system blur, so bright desktops cannot wash it out.
private final class SurfaceTint: NSView {
    var color = NSColor.clear
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
final class LauncherSurface: NSVisualEffectView {
    private let tint = SurfaceTint()
    override var isFlipped: Bool { true }
    var onDrag: ((NSEvent) -> Void)?
    init(frame: NSRect, cornerRadius: CGFloat = 14) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        // The compositor's behind-window blur and shadow need their own mask;
        // clipping the backing layer alone leaves rectangular material at the corners.
        let size = NSSize(width: cornerRadius * 2 + 1, height: cornerRadius * 2 + 1)
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        maskImage = mask
        tint.frame = bounds; tint.autoresizingMask = [.width, .height]; addSubview(tint)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { window?.invalidateShadow() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateShadow()
    }
    override func mouseDown(with event: NSEvent) { onDrag?(event) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        tint.color = dark ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: reduced ? 1 : 0.84)
                          : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: reduced ? 1 : 0.90)
        tint.needsDisplay = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.14 : 0.12).cgColor
    }
}
final class ResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

final class LauncherWindow: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let panel: LauncherPanel
    let search = NSTextField()
    let table = ResultTable()
    let sectionLabel = NSTextField(labelWithString: "建议")
    let footer = NSTextField(labelWithString: "⌃⌥Space 随时唤起")
    let actionLabel = NSTextField(labelWithString: "打开 ↵")
    let store: ExtensionStore
    let runtime = RuntimeClient()
    let implicitQueries = ImplicitQueryRunner()
    var onPluginsChanged: (() -> Void)?
    var onSettings: ((String?) -> Void)?
    private var results: [ResultItem] = []
    private var browserCommand: (InstalledExtension, ExtensionManifest.Command)?
    private var pageItem: ResultItem?
    private let pageView = PluginPageView(frame: .zero)
    private var installingPlugin = false
    private var isList: Bool { browserCommand?.1.presentation == "list" }
    private let detailView = PluginDetailView(frame: .zero)
    private let detailDivider = NSBox()
    private let typeFilter = NSPopUpButton()
    private var backButton: NSButton!
    private var selectedFilter = ""
    private var isDetail: Bool { browserCommand != nil }
    private let pendingQuery = QueryDebouncer()
    private let queryProgress = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在加载插件内容…")
    private var catalogObserver: NSObjectProtocol?
    private var resultsPending = false
    private var queryGeneration = UUID()
    private var previousApplication: NSRunningApplication?
    private var revision = ""
    private var refreshTimer: Timer?
    private var currentExtension: String?
    private var actionsButton: NSButton!
    private var primaryActionButton: NSButton!
    private var settingsButton: NSButton!
    private let actionDivider = NSBox()
    private let scroll = NSScrollView()
    private var bottomLine: NSBox!
    private let bottomBackground = NSView()
    private var logo: NSImageView!
    private var hiddenAt: Date?
    private var menuIsOpen = false
    private var actionMenu: ActionMenu?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var pendingSearchFocus: DispatchWorkItem?
    private let prefs = AppPreferences.shared
    private let positions: LauncherPositionStore
    private let dragGuides = LauncherDragGuides()
    private var isDragging = false
    private var accessibilityObserver: NSObjectProtocol?
    private let inputSource = InputSourceController()
    private var capturing = false
    private var developmentMode: Bool { prefs.values.developerMode ?? false }

    init(store: ExtensionStore) {
        self.store = store
        positions = LauncherPositionStore(root: store.root)
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 774, height: 474), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "Vectracast"; panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.appearance = prefs.appearance
        let root = LauncherSurface(frame: NSRect(x: 0, y: 0, width: 774, height: 474))
        root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
        root.onDrag = { [weak self] event in self?.drag(with: event) }
        root.wantsLayer = true
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.viewDidChangeEffectiveAppearance()
        panel.contentView = root

        search.frame = NSRect(x: 16, y: 14, width: 700, height: 34)
        search.font = .systemFont(ofSize: 20)
        search.isBordered = false; search.drawsBackground = false; search.focusRingType = .none
        search.placeholderString = "搜索应用与命令…"
        search.delegate = self
        search.setAccessibilityLabel("搜索应用和扩展")
        root.addSubview(search)
        backButton = NSButton(image: NSImage(systemSymbolName: "arrow.left", accessibilityDescription: "返回主搜索")!, target: self, action: #selector(exitDetail))
        backButton.wantsLayer = true; backButton.layer?.cornerRadius = 6; backButton.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.16).cgColor
        backButton.isBordered = false; backButton.frame = NSRect(x: 20, y: 18, width: 26, height: 26); root.addSubview(backButton)
        typeFilter.cell = DetailFilterCell(textCell: "", pullsDown: false)
        typeFilter.frame = NSRect(x: 560, y: 15, width: 194, height: 34); typeFilter.target = self; typeFilter.action = #selector(filterChanged)
        typeFilter.font = .systemFont(ofSize: 15); typeFilter.setAccessibilityLabel("内容类型"); root.addSubview(typeFilter)
        detailDivider.boxType = .separator; root.addSubview(detailDivider); root.addSubview(detailView); root.addSubview(pageView)
        panel.initialFirstResponder = search
        panel.dragHandler = { [weak self] event in
            guard let self, !self.isDetail, self.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.locationInWindow.y > self.panel.frame.height - 60 else { return false }
            self.drag(with: event)
            return true
        }
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!, target: self, action: #selector(openSettings))
        gear.frame = NSRect(x: 731, y: 19, width: 25, height: 25); gear.isBordered = false
        settingsButton = gear
        root.addSubview(gear)
        addLine(root, y: 60)
        queryProgress.style = .bar; queryProgress.isIndeterminate = true; queryProgress.isHidden = true
        queryProgress.frame = NSRect(x: 16, y: 61, width: 742, height: 6); root.addSubview(queryProgress)
        loadingLabel.font = .systemFont(ofSize: 13); loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center; loadingLabel.frame = NSRect(x: 40, y: 150, width: 694, height: 24)
        loadingLabel.isHidden = true; root.addSubview(loadingLabel)
        catalogObserver = NotificationCenter.default.addObserver(forName: .init("VectracastCatalogUpdated"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible, self.browserCommand?.0.manifest.permissions.catalog?.contains("read") == true else { return }
            self.updateQuery(immediate: true)
        }
        sectionLabel.frame = NSRect(x: 16, y: 76, width: 738, height: 20)
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium); sectionLabel.textColor = .secondaryLabelColor
        root.addSubview(sectionLabel)
        scroll.frame = NSRect(x: 8, y: 100, width: 758, height: 326)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.tableColumns[0].width = 742
        table.headerView = nil; table.rowHeight = 46; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear; table.style = .plain
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(executeSelected)
        table.onReturn = { [weak self] in self?.executeSelected() }
        table.setAccessibilityLabel("查询结果")
        scroll.documentView = table; root.addSubview(scroll); root.addSubview(loadingLabel)
        bottomBackground.wantsLayer = true; bottomBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.09).cgColor; root.addSubview(bottomBackground)
        bottomLine = NSBox(); bottomLine.boxType = .separator; root.addSubview(bottomLine)
        logo = NSImageView(frame: NSRect(x: 16, y: 445, width: 19, height: 19))
        logo.image = BrandAssets.logo
        logo.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(logo)
        footer.frame = NSRect(x: 44, y: 445, width: 390, height: 20)
        footer.font = .systemFont(ofSize: 13); footer.textColor = .secondaryLabelColor; footer.lineBreakMode = .byTruncatingTail
        root.addSubview(footer)
        primaryActionButton = SettingsChoiceButton(title: "", target: self, action: #selector(executeSelected))
        primaryActionButton.isBordered = false; primaryActionButton.frame = NSRect(x: 450, y: 438, width: 182, height: 30)
        actionLabel.frame = NSRect(x: 0, y: 6, width: 146, height: 18)
        actionLabel.alignment = .right; actionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        primaryActionButton.addSubview(actionLabel); primaryActionButton.addSubview(keycap("↵", x: 154))
        root.addSubview(primaryActionButton)
        actionDivider.boxType = .separator; root.addSubview(actionDivider)
        actionsButton = SettingsChoiceButton(title: "", target: self, action: #selector(showActions))
        actionsButton.isBordered = false; actionsButton.setAccessibilityLabel("操作 ⌘K")
        actionsButton.frame = NSRect(x: 654, y: 438, width: 104, height: 30)
        let actionsTitle = NSTextField(labelWithString: "操作"); actionsTitle.font = .systemFont(ofSize: 13, weight: .medium); actionsTitle.textColor = .secondaryLabelColor
        actionsTitle.frame = NSRect(x: 0, y: 6, width: 32, height: 18); actionsButton.addSubview(actionsTitle)
        actionsButton.addSubview(keycap("⌘", x: 39)); actionsButton.addSubview(keycap("K", x: 68)); root.addSubview(actionsButton)
        panel.keyHandler = { [weak self] event in
            guard let self else { return false }
            if self.pageItem != nil, [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { self.executeSelected(); return true }
            if event.keyCode == 53, (self.search.currentEditor() as? NSTextView)?.hasMarkedText() != true {
                self.escape(); return true
            }
            if (self.search.currentEditor() as? NSTextView)?.hasMarkedText() != true,
               let item = self.selected, let action = item.actions.first(where: { $0.shortcut?.matches(event) == true }) {
                self.execute(action, item: item); return true
            }
            guard event.modifierFlags.contains(.command) else { return false }
            if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "s" { self.captureWindow(); return true }
            switch event.charactersIgnoringModifiers {
            case "k": self.showActions(); return true
            case ",": self.openSettings(); return true
            case "r": self.updateQuery(); return true
            default: return false
            }
        }
        runtime.onLog = { [weak self] line in
            guard let self else { return }
            let url = self.store.root.appendingPathComponent("runtime.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > 1_000_000 { try? handle.truncate(atOffset: 0) }
                try? handle.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        implicitQueries.onLog = runtime.onLog
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismissOnBlur() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.dismissOnBlur()
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak root] _ in
            root?.viewDidChangeEffectiveAppearance()
        }
        layoutPanel()
        updateQuery()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self else { return }
            let next = (try? self.store.run("PRAGMA data_version").description) ?? ""
            if next != self.revision { self.revision = next; if self.panel.isVisible { self.updateQuery() } }
        }
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        refreshTimer?.invalidate()
    }
    func windowDidBecomeKey(_ notification: Notification) { focusSearch(); recordVisibility("focus") }
    func focusSearch() {
        pendingSearchFocus?.cancel()
        focusSearchIfReady()
        // Activation and makeKeyAndOrderFront can finish in different run-loop turns.
        // Recheck after AppKit has restored the window's previous first responder.
        let work = DispatchWorkItem { [weak self] in self?.focusSearchIfReady() }
        pendingSearchFocus = work; DispatchQueue.main.async(execute: work)
    }
    private func focusSearchIfReady() {
        guard panel.isVisible, panel.isKeyWindow, NSApp.isActive, !menuIsOpen else { return }
        if pageItem != nil { panel.makeFirstResponder(backButton); return }
        if let editor = search.currentEditor(), panel.firstResponder === editor { recordVisibility("search-focus"); return }
        guard panel.makeFirstResponder(search) else { return }
        if let editor = search.currentEditor() as? NSTextView, !editor.hasMarkedText() {
            editor.setSelectedRange(NSRange(location: search.stringValue.utf16.count, length: 0))
        }
        recordVisibility("search-focus")
    }
    private func addLine(_ root: NSView, y: CGFloat) {
        let line = NSBox(frame: NSRect(x: 0, y: y, width: 774, height: 1)); line.boxType = .separator; root.addSubview(line)
    }
    private func keycap(_ title: String, x: CGFloat) -> NSView {
        let cap = NSView(frame: NSRect(x: x, y: 3, width: 24, height: 24))
        cap.wantsLayer = true; cap.layer?.cornerRadius = 6
        cap.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.22).cgColor
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 14, weight: .medium); label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false; cap.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: cap.centerXAnchor), label.centerYAnchor.constraint(equalTo: cap.centerYAnchor)])
        return cap
    }
    func show(commandInput: String? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApplication = front }
        let setting = prefs.values.resetSearch
        if !(developmentMode && (prefs.values.developerPreserveQuery ?? true)), setting == "immediate" || (setting == "90" && hiddenAt.map { Date().timeIntervalSince($0) >= 90 } == true) { search.stringValue = ""; browserCommand = nil; pageItem = nil; selectedFilter = "" }
        if let commandInput { browserCommand = nil; pageItem = nil; selectedFilter = ""; search.stringValue = commandInput }
        let screen = prefs.values.screen == "main" ? NSScreen.screens.first : (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)
        updateQuery()
        if let screen {
            let frame = LauncherPlacement.restore(positions.anchor(for: screenKey(screen)), size: panel.frame.size, in: screen.visibleFrame)
            panel.setFrameOrigin(frame.origin)
        }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); focusSearch()
        DispatchQueue.main.async { [weak self] in
            self?.activateInputSourceIfReady()
        }
        recordVisibility("show")
    }
    func hide() { dismiss(); previousApplication?.activate(options: .activateIgnoringOtherApps) }
    private func dismiss() {
        actionMenu?.close()
        inputSource.restore()
        dragGuides.hide()
        pendingSearchFocus?.cancel(); pendingSearchFocus = nil
        pendingQuery.cancel(); runtime.cancel(); implicitQueries.cancel()
        if panel.isVisible { hiddenAt = Date(); panel.orderOut(nil) }
        recordVisibility("hide")
    }
    private func recordVisibility(_ reason: String) {
        let searchFocused = search.currentEditor().map { panel.firstResponder === $0 } ?? false
        func rect(_ frame: NSRect) -> [String: CGFloat] { ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height] }
        let value: [String: Any] = ["event": reason, "visible": panel.isVisible, "key": panel.isKeyWindow, "active": NSApp.isActive, "searchFocused": searchFocused, "frame": rect(panel.frame), "screenVisibleFrame": rect(panel.screen?.visibleFrame ?? .zero), "time": Date().timeIntervalSince1970]
        try? Data(jsonString(value).utf8).write(to: store.root.appendingPathComponent("window-state.json"), options: .atomic)
    }
    func dismissForSettings() { dismiss() }
    func restoreInputSource() { inputSource.restore() }
    func activateInputSourceIfReady() {
        guard panel.isVisible, panel.isKeyWindow, NSApp.isActive else { return }
        if !inputSource.activate(prefs.values.inputSource) { footer.stringValue = "指定输入法不可用，保留当前输入法" }
    }
    private var confirmingHistoryAction = false
    func dismissOnBlur() {
        inputSource.restore()
        if !capturing && !confirmingHistoryAction && !installingPlugin && !(developmentMode && (prefs.values.developerKeepVisible ?? true)) && prefs.values.hideOnBlur && panel.isVisible { dismiss() }
    }
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isKeyWindow, !self.menuIsOpen else { return }
            self.dismissOnBlur()
        }
    }
    func applyPreferences() {
        panel.appearance = prefs.appearance; panel.hidesOnDeactivate = false
        search.font = .systemFont(ofSize: prefs.values.textSize == "large" ? 22 : 20)
        (panel.contentView as? LauncherSurface)?.viewDidChangeEffectiveAppearance()
        table.rowHeight = prefs.values.textSize == "large" ? 50 : 46
        if panel.isVisible { updateQuery() }
    }
    private func screenKey(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return screen.localizedName
    }
    private func drag(with event: NSEvent) {
        guard !isDragging else { return }
        isDragging = true
        defer { isDragging = false; dragGuides.hide(); focusSearch() }
        let startMouse = panel.convertPoint(toScreen: event.locationInWindow)
        let startFrame = panel.frame
        let empty = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var moved = false
        var snap = LauncherPlacement.Snap()
        var lastScreen: NSScreen?
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            guard panel.isVisible else { break }
            let mouse = panel.convertPoint(toScreen: next.locationInWindow)
            let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
            if !moved && hypot(dx, dy) < 3 { continue }
            moved = true
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? panel.screen else { continue }
            if lastScreen !== screen { snap = LauncherPlacement.Snap() }
            lastScreen = screen
            let (frame, state) = LauncherPlacement.snap(startFrame.offsetBy(dx: dx, dy: dy), in: screen.visibleFrame, enabled: empty, previous: snap)
            snap = state
            panel.setFrameOrigin(frame.origin)
            if empty { dragGuides.show(screen: screen, frame: frame, snap: snap) }
        }
        if moved, panel.isVisible, let screen = lastScreen {
            positions.save(LauncherPlacement.anchor(for: panel.frame, in: screen.visibleFrame), for: screenKey(screen))
            recordVisibility("drag-end")
        }
    }
    private func layoutPanel() {
        let compact = prefs.values.compact
        let empty = !isDetail && search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let height: CGFloat = empty ? 100 : (!isDetail && compact ? min(474, 148 + CGFloat(results.count) * (table.rowHeight + 2)) : 474)
        // Search results appear immediately; keep the top edge anchored without a resize animation.
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if frame != panel.frame { panel.setFrame(frame, display: true, animate: false) }
        panel.contentView?.setFrameSize(NSSize(width: 774, height: height))
        sectionLabel.isHidden = empty || isDetail; scroll.isHidden = empty || pageItem != nil
        pageView.isHidden = pageItem == nil; pageView.frame = NSRect(x: 0, y: 60, width: 774, height: height - 100)
        search.isHidden = pageItem != nil
        settingsButton.isHidden = empty || isDetail
        backButton.isHidden = !isDetail; typeFilter.isHidden = pageItem != nil || !isDetail || (browserCommand?.1.filters?.isEmpty ?? true)
        detailView.isHidden = !isDetail || isList; detailDivider.isHidden = !isDetail || isList
        let searchHeight = ceil(search.cell?.cellSize.height ?? 26)
        backButton.frame = NSRect(x: 20, y: 17, width: 26, height: 26)
        typeFilter.frame = NSRect(x: 560, y: 13, width: 194, height: 34)
        search.frame.origin.y = (60 - searchHeight) / 2
        search.frame.size.height = searchHeight
        search.frame.origin.x = isDetail ? 52 : 16
        search.frame.size.width = isDetail ? (typeFilter.isHidden ? 695 : 488) : (empty ? 742 : 700)
        search.placeholderString = isDetail ? (browserCommand?.1.searchPlaceholder ?? "搜索插件内容…") : "搜索应用与命令…"
        search.setAccessibilityLabel(isDetail ? "筛选插件内容" : "搜索应用和扩展")
        scroll.frame = NSRect(x: 8, y: 100, width: 758, height: max(0, height - 148))
        if isDetail && !isList {
            scroll.frame = NSRect(x: 8, y: 68, width: 282, height: max(0, height - 116))
            detailDivider.frame = NSRect(x: 296, y: 60, width: 1, height: height - 100)
            detailView.frame = NSRect(x: 297, y: 60, width: 477, height: height - 100)
        }
        if isList { scroll.frame = NSRect(x: 8, y: 68, width: 758, height: max(0, height - 116)) }
        table.tableColumns[0].width = scroll.contentSize.width - 4
        bottomBackground.frame = NSRect(x: 0, y: height - 40, width: 774, height: 40)
        bottomLine.frame = NSRect(x: 0, y: height - 40, width: 774, height: 1)
        logo.frame.origin.y = height - 29; footer.frame.origin.y = height - 29
        primaryActionButton.frame.origin.y = height - 35; actionsButton.frame.origin.y = height - 35
        actionDivider.frame = NSRect(x: 642, y: height - 27, width: 1, height: 14)
        recordVisibility("layout")
    }
    func toggle() { panel.isVisible && panel.isKeyWindow && NSApp.isActive ? hide() : show() }
    @objc private func exitDetail() {
        if pageItem != nil { pageItem = nil; layoutPanel(); updatePrimaryAction(); focusSearch(); return }
        browserCommand = nil; pageItem = nil; selectedFilter = ""; search.stringValue = ""; updateQuery(); focusSearch()
    }
    @objc private func filterChanged() { selectedFilter = typeFilter.selectedItem?.representedObject as? String ?? ""; updateQuery(); focusSearch() }
    private func enterDetail(_ info: InstalledExtension, _ command: ExtensionManifest.Command, query: String) {
        pageItem = nil; browserCommand = (info, command); selectedFilter = ""; typeFilter.removeAllItems()
        for filter in command.filters ?? [] { typeFilter.addItem(withTitle: filter.title); typeFilter.lastItem?.representedObject = filter.id }
        selectedFilter = command.filters?.first?.id ?? ""
        setResults([], section: info.manifest.name)
        search.stringValue = query; updateQuery(immediate: true); focusSearch()
    }
    private func escape() {
        if pageItem != nil { exitDetail(); return }
        if isDetail && search.stringValue.isEmpty { exitDetail(); return }
        if prefs.values.escape == "close" { hide() }
        else if !search.stringValue.isEmpty { search.stringValue = ""; updateQuery(); panel.makeFirstResponder(search) }
        else { hide() }
    }
    func controlTextDidChange(_ obj: Notification) {
        if (search.currentEditor() as? NSTextView)?.hasMarkedText() == true {
            pendingQuery.cancel(); runtime.cancel(); implicitQueries.cancel(); queryGeneration = UUID()
            beginWaiting()
            return
        }
        updateQuery()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.moveDown(_:)) { selectRow(min(results.count - 1, table.selectedRow + 1)); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { selectRow(max(0, table.selectedRow - 1)); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { executeSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            escape()
            return true
        }
        if selector == #selector(NSResponder.insertTab(_:)), let item = selected, let keyword = item.actions.first(where: { $0.type == "input.set" })?.text {
            search.stringValue = keyword; updateQuery(); return true
        }
        return false
    }
    private var selected: ResultItem? { resultsPending ? nil : (pageItem ?? (results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil)) }
    private func selectRow(_ index: Int) {
        guard results.indices.contains(index) else { return }
        var index = index
        if results[index].groupHeading == true {
            let direction = index > 0 && index < table.selectedRow ? -1 : 1
            while results.indices.contains(index) && results[index].groupHeading == true { index += direction }
            guard results.indices.contains(index) else { return }
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
    }
    private func beginWaiting() {
        // Keep row geometry stable while typing, but never execute stale results.
        if !isDetail && (results.isEmpty || results.first?.id == "welcome") {
            setResults([.message("等待输入…", "停止输入后自动查询", icon: "ellipsis")], section: "结果")
        }
        resultsPending = true
        if isDetail {
            queryProgress.isHidden = false; queryProgress.startAnimation(nil)
            loadingLabel.isHidden = !results.isEmpty
            loadingLabel.stringValue = browserCommand?.0.manifest.permissions.catalog?.contains("read") == true ? "正在连接插件商店，首次加载可能需要片刻…" : "正在加载插件内容…"
        }
        table.alphaValue = isDetail ? 1 : 0.5
        footer.stringValue = "等待输入 · 停顿后自动查询"
        updatePrimaryAction()
        actionsButton.isEnabled = false
        layoutPanel()
    }
    private func setResults(_ items: [ResultItem], section: String) {
        queryProgress.stopAnimation(nil); queryProgress.isHidden = true; loadingLabel.isHidden = true
        let id = results.indices.contains(table.selectedRow) ? results[table.selectedRow].id : nil
        resultsPending = true; table.alphaValue = 1; actionsButton.isEnabled = true
        var displayed: [ResultItem] = []; var previousGroup: String?
        for item in items {
            if isDetail, let group = item.group, group != previousGroup {
                var heading = ResultItem.message(group, ""); heading.id = "heading-" + String(displayed.count); heading.groupHeading = true
                displayed.append(heading); previousGroup = group
            }
            displayed.append(item)
        }
        if let current = pageItem { pageItem = displayed.first(where: { $0.id == current.id }).map { var item = $0; item.actions.removeAll { $0.type == "view.detail" }; return item }; if let pageItem { pageView.display(pageItem) } }
        results = displayed; sectionLabel.stringValue = section
        table.reloadData(); layoutPanel()
        resultsPending = false
        selectRow(results.firstIndex(where: { $0.id == id }) ?? 0)
        updatePrimaryAction()
    }
    func refresh() { revision = ""; updateQuery() }
    func updateQuery(immediate: Bool = false, explicitCommand: (InstalledExtension, ExtensionManifest.Command)? = nil) {
        pendingQuery.cancel(); runtime.cancel(); implicitQueries.cancel(); currentExtension = nil
        queryGeneration = UUID(); let generation = queryGeneration
        let raw = search.stringValue
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !isDetail {
            footer.stringValue = "Vectracast 已就绪 · 输入关键词开始搜索"
            setResults([ResultItem(id: "welcome", title: "Vectracast 已就绪", subtitle: nil, icon: "arrow.up.forward.square.fill", actions: [ResultAction(id: "settings", title: "打开设置", type: "settings.open", text: nil)])], section: "")
            return
        }
        let extensions = store.list().filter(\.enabled)
        if let current = browserCommand, !extensions.contains(where: { $0.manifest.id == current.0.manifest.id }) { exitDetail(); return }
        let active = browserCommand.flatMap { current in extensions.first(where: { $0.manifest.id == current.0.manifest.id }).flatMap { info in info.manifest.commands.first(where: { $0.id == current.1.id }).map { (info, $0) } } }
        let commands = extensions.flatMap { info in info.manifest.commands.map { (info, $0) } }
        let entry = CommandEntryMatcher.match(raw, candidates: commands.map { info, command in
            CommandEntryMatcher.Candidate(key: info.manifest.id + "/" + command.id, commandID: command.id, title: command.title, aliases: prefs.keywords(info, command), extensionName: info.manifest.commands.count == 1 ? info.manifest.name : nil)
        })
        let resolved = entry.flatMap { entry in commands.first { $0.0.manifest.id + "/" + $0.1.id == entry.key } }
        if let matched = active ?? explicitCommand ?? resolved {
            let (info, command) = matched
            currentExtension = info.manifest.id
            let query = isDetail ? raw : (explicitCommand != nil ? "" : entry?.query ?? "")
            if !isDetail && command.presentation != nil { enterDetail(info, command, query: query); return }
            let preferencesAction = ResultAction(id: "settings", title: "配置扩展", type: "settings.open", text: info.manifest.id)
            if query.isEmpty && command.acceptsEmptyQuery != true {
                setResults([.message("输入要查询的内容", "直接在命令后继续输入，无需按回车进入扩展。", icon: info.manifest.icon, actions: [preferencesAction])], section: info.manifest.name)
                return
            }
            guard query.count <= 6000 else { setResults([.message("输入内容过长", "请缩短到 6000 个字符以内。")], section: info.manifest.name); return }
            beginWaiting()
            footer.stringValue = info.manifest.permissions.catalog?.contains("read") == true ? "正在刷新插件目录…" : (info.manifest.permissions.network?.isEmpty == false ? "通过已授权的扩展服务查询" : "本地扩展 · 实时结果")
            pendingQuery.schedule(requestedDelayMs: command.debounceMs, immediate: immediate || (isDetail && trimmed.isEmpty)) { [weak self] in
                guard let self, self.queryGeneration == generation, self.search.stringValue == raw else { return }
                self.runtime.query(info, command: command.id, query: query, rawInput: raw, filter: self.selectedFilter) { [weak self] result in
                    guard let self, self.queryGeneration == generation, self.search.stringValue == raw else { return }
                    switch result {
                    case .success(let items): self.setResults(items.isEmpty ? [.message("没有匹配结果", "尝试修改查询内容。", actions: [preferencesAction])] : items, section: info.manifest.name + "  ·  \(items.count) 条结果")
                    case .failure(let error): self.setResults([.message("暂时无法查询", error.localizedDescription, icon: "exclamationmark.circle", actions: [preferencesAction])], section: info.manifest.name)
                    }
                    self.footer.stringValue = self.isDetail ? info.manifest.name : "↑↓ 选择结果 · ↵ 执行动作"
                }
            }
            return
        }
        var items: [ResultItem] = []
        for info in extensions {
            for command in info.manifest.commands where trimmed.isEmpty || ([command.id, command.title, info.manifest.name] + prefs.keywords(info, command)).contains(where: { $0.localizedCaseInsensitiveContains(trimmed) }) {
                let keywords = prefs.keywords(info, command)
                var actions = [ResultAction(id: "open", title: "打开命令", type: "command.open", text: command.id), ResultAction(id: "settings", title: "扩展设置", type: "settings.open", text: info.manifest.id)]
                if let keyword = keywords.first { actions.append(ResultAction(id: "query", title: "输入内容", type: "input.set", text: keyword + " ")) }
                items.append(ResultItem(id: info.manifest.id + "." + command.id, title: command.title, subtitle: info.manifest.name + " · " + (keywords.isEmpty ? "直接输入" : keywords.joined(separator: ", ")), icon: info.manifest.icon, actions: actions, extensionID: info.manifest.id))
            }
        }
        if trimmed.isEmpty || ["extensions", "store", "扩展", "设置", "管理"].contains(where: { $0.contains(trimmed.lowercased()) }) {
            items.append(ResultItem(id: "extensions", title: "设置", subtitle: "Vectracast", icon: "gearshape.fill", actions: [ResultAction(id: "manage", title: "打开", type: "settings.open", text: nil)]))
        }
        footer.stringValue = "Vectracast"
        let baseItems = items
        let placeholder = ResultItem.message("没有匹配结果", "尝试其他输入，或在扩展管理中启用相关功能。", icon: "magnifyingglass")
        beginWaiting()
        implicitQueries.query(extensions, input: raw) { [weak self] extensionItems, finished in
            guard let self, self.queryGeneration == generation, self.search.stringValue == raw else { return }
            guard finished || !extensionItems.isEmpty else { return }
            let combined = extensionItems + baseItems
            self.setResults(combined.isEmpty ? [placeholder] : combined, section: "结果")
            self.footer.stringValue = extensionItems.isEmpty ? "Vectracast" : "扩展结果 · ↑↓ 选择 · ↵ 执行动作"
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let item = results[row]
        if item.groupHeading == true {
            let label = NSTextField(labelWithString: item.title); label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabelColor
            let view = NSView(); label.frame = NSRect(x: 9, y: 5, width: 250, height: 18); view.addSubview(label); return view
        }
        let view = NSTableCellView()
        let image = NSImageView()
        image.image = item.applicationPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSImage(systemSymbolName: item.icon ?? "text.bubble", accessibilityDescription: nil)
        if isDetail, let id = item.preview?.historyImageID, let extensionID = item.extensionID {
            ClipboardHistory.shared.loadImage(extensionID, entryID: id, maxPixels: 80) { [weak image] loaded in image?.image = loaded }
        }
        image.contentTintColor = (item.applicationPath != nil || item.preview?.historyImageID != nil) ? nil : (item.extensionID == "local.youdao" ? .systemRed : .secondaryLabelColor)
        image.translatesAutoresizingMaskIntoConstraints = false
        let fontSize: CGFloat = prefs.values.textSize == "large" ? 17 : 15
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: fontSize, weight: .regular); title.lineBreakMode = .byTruncatingTail
        if isList {
            let subtitle = NSTextField(labelWithString: item.subtitle ?? ""); subtitle.font = .systemFont(ofSize: fontSize - 1); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
            image.frame = NSRect(x: 10, y: 18, width: 26, height: 26); image.translatesAutoresizingMaskIntoConstraints = true
            title.frame = NSRect(x: 48, y: 31, width: tableView.bounds.width - 72, height: 22)
            subtitle.frame = NSRect(x: 48, y: 8, width: tableView.bounds.width - 72, height: 21)
            view.addSubview(image); view.addSubview(title); view.addSubview(subtitle)
            view.setAccessibilityElement(true); view.setAccessibilityLabel(item.title + ". " + (item.subtitle ?? "")); return view
        }
        if isDetail {
            title.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(image); view.addSubview(title)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10), image.centerYAnchor.constraint(equalTo: view.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 22), image.heightAnchor.constraint(equalToConstant: 28),
                title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: view.centerYAnchor), title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
            ])
            view.setAccessibilityElement(true); view.setAccessibilityLabel(item.title); return view
        }
        let subtitle = NSTextField(labelWithString: item.applicationPath != nil ? "" : (item.subtitle ?? ""))
        subtitle.font = .systemFont(ofSize: fontSize - 1); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        let kind = NSTextField(labelWithString: item.applicationPath != nil ? "应用程序" : item.actions.first?.type == "clipboard.copy" ? "结果" : "命令")
        kind.font = .systemFont(ofSize: 13); kind.textColor = .secondaryLabelColor; kind.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false; subtitle.translatesAutoresizingMaskIntoConstraints = false; kind.translatesAutoresizingMaskIntoConstraints = false
        let measured = (item.title as NSString).size(withAttributes: [.font: title.font!]).width + 3
        let width = min(measured, item.subtitle?.isEmpty == false ? 390 : 555)
        view.addSubview(image); view.addSubview(title); view.addSubview(subtitle); view.addSubview(kind)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9), image.centerYAnchor.constraint(equalTo: view.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 21), image.heightAnchor.constraint(equalToConstant: 21),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: view.centerYAnchor), title.widthAnchor.constraint(equalToConstant: width),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 9), subtitle.centerYAnchor.constraint(equalTo: view.centerYAnchor), subtitle.trailingAnchor.constraint(lessThanOrEqualTo: kind.leadingAnchor, constant: -12),
            kind.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10), kind.centerYAnchor.constraint(equalTo: view.centerYAnchor), kind.widthAnchor.constraint(equalToConstant: 65),
        ])
        view.setAccessibilityElement(true); view.setAccessibilityLabel(item.title + ". " + (item.subtitle ?? ""))
        return view
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { results.indices.contains(row) && results[row].groupHeading == true ? 30 : (isList ? 62 : table.rowHeight) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { results.indices.contains(row) && results[row].groupHeading != true }
    private func updatePrimaryAction() {
        if isDetail { if !resultsPending && !isList { detailView.display(selected) }; footer.stringValue = browserCommand?.0.manifest.name ?? "扩展" }

        actionLabel.stringValue = selected?.actions.first?.title ?? ""
        if let selected, selected.actions.first?.type == "clipboard.history.paste", let target = previousApplication { actionLabel.stringValue = "粘贴到 " + (target.localizedName ?? "上一应用") }
        primaryActionButton?.setAccessibilityLabel(actionLabel.stringValue + " ↵")
        primaryActionButton?.isHidden = selected?.actions.first == nil
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePrimaryAction() }
    @objc func executeSelected() { if let item = selected, let action = item.actions.first { execute(action, item: item) } }
    private func execute(_ action: ResultAction, item: ResultItem) {
        switch action.type {
        case "view.detail":
            guard item.extensionID != nil else { return }
            var detail = item; detail.actions.removeAll { $0.type == "view.detail" }; pageItem = detail
            pageView.display(detail); layoutPanel(); updatePrimaryAction(); focusSearch()
        case "url.open":
            guard let id = item.extensionID, store.list().contains(where: { $0.enabled && $0.manifest.id == id && $0.manifest.permissions.browser?.contains("open") == true }), let url = safeBrowserURL(action.text) else { return }
            NSWorkspace.shared.open(url)
        case "catalog.refresh":
            guard let id = item.extensionID, store.list().contains(where: { $0.enabled && $0.manifest.id == id && $0.manifest.permissions.catalog?.contains("read") == true }) else { return }
            Task { @MainActor in await PluginCatalogService.shared.invalidate(); self.updateQuery(immediate: true) }
        case "catalog.install": installCatalogItem(action, item: item)
        case "clipboard.copy":
            if let extensionID = item.extensionID, !store.list().contains(where: { $0.enabled && $0.manifest.id == extensionID && $0.manifest.permissions.clipboard?.contains("write") == true }) { footer.stringValue = "扩展已禁用或没有复制权限"; return }
            guard let text = action.text else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            footer.stringValue = "已复制 · " + String(text.prefix(35))
            if prefs.values.closeAfterCopy { hide() }
        case "clipboard.history.copy", "clipboard.history.paste":
            guard let extensionID = item.extensionID, let entryID = action.text else { return }
            do {
                try ClipboardHistory.shared.copy(extensionID, entryID: entryID)
                if action.type == "clipboard.history.paste" {
                    guard store.list().contains(where: { $0.enabled && $0.manifest.id == extensionID && $0.manifest.permissions.clipboard?.contains("paste") == true }) else { footer.stringValue = "没有粘贴权限，内容已复制"; return }
                    pasteToPreviousApplication()
                } else { footer.stringValue = "已复制"; if prefs.values.closeAfterCopy { hide() } }
            } catch { footer.stringValue = error.localizedDescription }
        case "clipboard.history.remove", "clipboard.history.clear":
            guard let extensionID = item.extensionID,
                  store.list().contains(where: { $0.enabled && $0.manifest.id == extensionID && $0.manifest.permissions.clipboard?.contains("history") == true }) else { footer.stringValue = "扩展已停用或没有历史记录权限"; return }
            if action.type == "clipboard.history.clear" {
                let alert = NSAlert(); alert.messageText = "清空全部剪贴板历史？"
                alert.informativeText = "将删除此插件保存的全部记录，当前系统剪贴板内容不受影响。此操作无法撤销。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空历史")
                confirmingHistoryAction = true
                let response = alert.runModal()
                confirmingHistoryAction = false; panel.makeKeyAndOrderFront(nil)
                guard response == .alertSecondButtonReturn else { focusSearch(); return }
            }
            do {
                if action.type == "clipboard.history.clear" { try ClipboardHistory.shared.clear(extensionID) }
                else if let entry = action.text { try ClipboardHistory.shared.remove(extensionID, entry: entry) }
                updateQuery(); focusSearch()
            } catch { footer.stringValue = "修改历史记录失败" }
        case "command.open":
            guard let info = store.list().first(where: { $0.enabled && $0.manifest.id == item.extensionID }),
                  let command = info.manifest.commands.first(where: { $0.id == action.text }) else { return }
            if command.presentation != nil { enterDetail(info, command, query: "") }
            else {
                search.stringValue = (prefs.keywords(info, command).first ?? command.id) + " "
                updateQuery(immediate: true, explicitCommand: (info, command)); focusSearch()
            }
        case "input.set": search.stringValue = action.text ?? ""; panel.makeFirstResponder(search); updateQuery(); (search.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: search.stringValue.utf16.count, length: 0))
        case "settings.open": onSettings?(action.text)
        case "storage.toggle":
            guard let extensionID = item.extensionID, let key = action.text,
                  store.list().contains(where: { $0.enabled && $0.manifest.id == extensionID }) else { return }
            do {
                try ExtensionActionState.shared.toggle(extensionID, key: key)
                updateQuery(immediate: true); focusSearch()
            } catch { footer.stringValue = error.localizedDescription }
        case "application.open", "application.reveal", "application.info", "application.contents":
            guard let extensionID = item.extensionID, let path = item.applicationPath,
                  action.text == item.applicationId,
                  store.list().contains(where: { $0.enabled && $0.manifest.id == extensionID && $0.manifest.permissions.applications?.contains("open") == true }) else { footer.stringValue = "扩展已禁用或没有应用操作权限"; return }
            ApplicationActions.perform(action.type, url: URL(fileURLWithPath: path)) { [weak self] error in
                if let error { self?.footer.stringValue = error; self?.panel.makeKeyAndOrderFront(nil); self?.focusSearch() }
                else { self?.dismiss() }
            }
        default: break
        }
    }
    private func pasteToPreviousApplication() {
        guard let target = previousApplication, !target.isTerminated else { footer.stringValue = "已复制，请在目标应用中粘贴"; return }
        guard AXIsProcessTrusted() else { footer.stringValue = "已复制 · 自动粘贴需在系统设置中授权 Vectracast 辅助功能"; return }
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
    @objc func openSettings() { onSettings?(currentExtension) }
    @objc func captureWindow() {
        guard panel.isVisible, !capturing, let view = panel.contentView else { return }
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { footer.stringValue = "请先完成输入，再截取窗口"; return }
        defer { focusSearch() }
        do {
            let data = try WindowCapture.png(view)
            let copy = prefs.values.captureCopy ?? true, reveal = prefs.values.captureReveal ?? false
            if copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png) }
            if reveal {
                let directory = store.root.appendingPathComponent("Captures")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("Vectracast-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")
                try data.write(to: file, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else if !copy {
                capturing = true
                let save = NSSavePanel(); save.nameFieldStringValue = "Vectracast.png"
                save.begin { [weak self] response in
                    defer { self?.capturing = false; self?.focusSearch() }
                    guard response == .OK, let url = save.url else { return }
                    do { try data.write(to: url, options: .atomic); self?.footer.stringValue = "窗口截图已保存" }
                    catch { self?.footer.stringValue = "截图保存失败：\(error.localizedDescription)" }
                }
                return
            }
            footer.stringValue = reveal ? "窗口截图已保存" : "窗口截图已复制"
        } catch { footer.stringValue = "截图失败：\(error.localizedDescription)" }
    }
    private func installCatalogItem(_ action: ResultAction, item: ResultItem) {
        guard !installingPlugin, let id = item.extensionID, let handle = action.text, handle == item.catalogID,
              store.list().contains(where: { $0.enabled && $0.manifest.id == id && $0.manifest.permissions.catalog?.contains("install") == true }) else { return }
        installingPlugin = true; footer.stringValue = "正在下载并校验插件…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.installingPlugin = false }
            do {
                let (data, package, source) = try await PluginCatalogService.shared.download(handle)
                guard self.panel.isVisible, self.store.list().contains(where: { $0.enabled && $0.manifest.id == id && $0.manifest.permissions.catalog?.contains("install") == true }) else { return }
                let alert = NSAlert(); alert.messageText = "安装 \(package.manifest.name) v\(package.manifest.version)？"
                alert.informativeText = "来源：\(source)\n\n" + (package.manifest.permissionSummary.isEmpty ? "无外部能力" : package.manifest.permissionSummary)
                alert.addButton(withTitle: "安装并授权"); alert.addButton(withTitle: "取消")
                let response = alert.runModal(); self.panel.makeKeyAndOrderFront(nil)
                guard response == .alertFirstButtonReturn else { self.footer.stringValue = "已取消安装"; self.focusSearch(); return }
                guard self.store.list().contains(where: { $0.enabled && $0.manifest.id == id && $0.manifest.permissions.catalog?.contains("install") == true }) else { return }
                _ = try self.store.install(data, acceptPermissions: true); self.onPluginsChanged?()
                self.updateQuery(immediate: true); self.focusSearch()
            } catch { self.footer.stringValue = "安装失败：" + error.localizedDescription }
        }
    }
    @objc func showActions() {
        if let actionMenu { actionMenu.close(); return }
        guard let item = selected else { return }
        var entries = item.actions.map { action in
            ActionMenu.Entry(action: action, perform: { [weak self] in self?.execute(action, item: item) })
        }
        if let id = item.extensionID ?? currentExtension {
            entries.append(.init(action: ResultAction(id: "settings", title: "扩展设置", type: "settings.open", text: id, icon: "gearshape", shortcut: .init(key: ",", modifiers: ["shift", "command"]), section: "settings"), perform: { [weak self] in self?.onSettings?(id) }))
        }
        entries.append(.init(action: ResultAction(id: "capture", title: "窗口截图", type: "capture", text: nil, icon: "camera", shortcut: .init(key: "s", modifiers: ["shift", "command"]), section: "settings"), perform: { [weak self] in self?.captureWindow() }))
        menuIsOpen = true
        actionMenu = ActionMenu(title: item.title, entries: entries, parent: panel) { [weak self] in
            guard let self else { return }
            self.actionMenu = nil; self.menuIsOpen = false
            if NSApp.isActive, self.panel.isVisible { self.panel.makeKeyAndOrderFront(nil); self.focusSearch() }
        }
    }
}
