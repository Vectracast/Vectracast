import AppKit

extension ActionShortcut {
    var flags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { flags, name in
            switch name { case "command": flags.insert(.command); case "shift": flags.insert(.shift); case "option": flags.insert(.option); case "control": flags.insert(.control); default: break }
        }
    }
    var keycaps: [String] {
        [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")].compactMap { modifiers.contains($0.0) ? $0.1 : nil } + [key == "return" ? "↵" : key.uppercased()]
    }
    func matches(_ event: NSEvent) -> Bool {
        guard Self.isValid(self), event.modifierFlags.intersection([.command, .shift, .option, .control]) == flags else { return false }
        return key == "return" ? [36, 76].contains(event.keyCode) : (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?.lowercased() == key.lowercased()
    }
}

/// A shared action palette; plugins own the actions, titles, ordering and shortcuts.
final class ActionMenu: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    struct Entry { let action: ResultAction; let perform: () -> Void }
    private let panel: LauncherPanel
    private let search = NSTextField()
    private let table = ResultTable()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "没有匹配的操作")
    private let entries: [Entry]
    private var filtered: [Entry] = []
    private var outsideMonitor: Any?
    private var onClose: (() -> Void)?
    private var closed = false

    init(title: String, entries: [Entry], parent: NSWindow, onClose: @escaping () -> Void) {
        self.entries = entries; self.filtered = entries; self.onClose = onClose
        let height = min(300, CGFloat(entries.count) * 40 + 82)
        panel = LauncherPanel(contentRect: NSRect(x: parent.frame.maxX - 376, y: parent.frame.minY + 48, width: 368, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "操作面板"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = parent.level; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.appearance = parent.appearance
        // Keep the whole palette visible even for the compact empty launcher.
        if let screen = parent.screen {
            var frame = panel.frame; frame.origin.y = min(frame.minY, screen.visibleFrame.maxY - frame.height - 8); panel.setFrame(frame, display: false)
        }
        let root = LauncherSurface(frame: NSRect(x: 0, y: 0, width: 368, height: height), cornerRadius: 16)
        root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
        root.layer?.borderWidth = 0.5
        panel.contentView = root; root.viewDidChangeEffectiveAppearance()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.textColor = .secondaryLabelColor; heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 16, y: 14, width: 336, height: 19); root.addSubview(heading)
        scroll.frame = NSRect(x: 8, y: 40, width: 352, height: height - 86)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.hasHorizontalScroller = false
        table.frame = NSRect(origin: .zero, size: scroll.contentSize)
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("action"))
        column.minWidth = 0; column.resizingMask = .autoresizingMask; column.width = scroll.contentSize.width
        table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 40; table.intercellSpacing = .zero; table.style = .plain; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(activate)
        table.onReturn = { [weak self] in self?.activate() }; table.setAccessibilityLabel("可用操作")
        scroll.documentView = table; root.addSubview(scroll)
        empty.font = .systemFont(ofSize: 14); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        empty.frame = NSRect(x: 16, y: 66, width: 336, height: 24); empty.isHidden = true; root.addSubview(empty)
        let line = NSBox(frame: NSRect(x: 0, y: height - 44, width: 368, height: 1)); line.boxType = .separator; root.addSubview(line)
        search.font = .systemFont(ofSize: 16); search.placeholderString = "搜索操作…"; search.isBordered = false; search.drawsBackground = false; search.focusRingType = .none
        search.frame = NSRect(x: 16, y: height - 32, width: 336, height: 24); search.delegate = self; search.setAccessibilityLabel("搜索操作"); root.addSubview(search)
        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.close() }
            return event
        }
        reload()
        parent.addChildWindow(panel, ordered: .above); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
    }
    deinit { if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) } }
    func close() {
        guard !closed else { return }; closed = true
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
        let callback = onClose; onClose = nil; callback?()
    }
    func windowDidResignKey(_ notification: Notification) { close() }
    private func handle(_ event: NSEvent) -> Bool {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "k") { close(); return true }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if event.keyCode == 125 { move(1); return true }
            if event.keyCode == 126 { move(-1); return true }
            if [36, 76].contains(event.keyCode) { activate(); return true }
        }
        if let entry = entries.first(where: { $0.action.shortcut?.matches(event) == true }) { close(); entry.perform(); return true }
        return false
    }
    private func move(_ step: Int) {
        guard !filtered.isEmpty else { return }
        let row = max(0, min(filtered.count - 1, table.selectedRow + step))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc private func activate() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let entry = filtered[table.selectedRow]; close(); entry.perform()
    }
    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = entries.filter { query.isEmpty || $0.action.title.localizedCaseInsensitiveContains(query) || $0.action.id.localizedCaseInsensitiveContains(query) }
        reload()
    }
    private func reload() {
        table.reloadData(); empty.isHidden = !filtered.isEmpty
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = filtered[row].action
        let width = tableColumn?.width ?? tableView.bounds.width
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        let icon = NSImageView(frame: NSRect(x: 11, y: 10, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: action.icon ?? "bolt", accessibilityDescription: nil); icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown; view.addSubview(icon)
        let caps = action.shortcut?.keycaps ?? []
        let title = NSTextField(labelWithString: action.title); title.font = .systemFont(ofSize: 15); title.lineBreakMode = .byTruncatingTail
        // Keep an explicit gutter even while the overlay scroller is visible.
        let trailing: CGFloat = 20
        let capsWidth = max(0, CGFloat(caps.count) * 27 - 3)
        title.frame = NSRect(x: 43, y: 10, width: max(0, width - trailing - capsWidth - 8 - 43), height: 22)
        title.autoresizingMask = [.width]; view.addSubview(title)
        for (index, cap) in caps.enumerated() {
            let label = NSTextField(labelWithString: cap); label.font = .systemFont(ofSize: 14, weight: .medium); label.textColor = .secondaryLabelColor; label.alignment = .center
            let box = NSView(frame: NSRect(x: width - trailing - capsWidth + CGFloat(index) * 27, y: 8, width: 24, height: 24))
            box.autoresizingMask = [.minXMargin]
            box.wantsLayer = true; box.layer?.cornerRadius = 6; box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            label.frame = NSRect(x: 0, y: 2, width: 24, height: 20); box.addSubview(label); view.addSubview(box)
        }
        if row > 0, action.section != filtered[row - 1].action.section {
            let line = NSBox(frame: NSRect(x: 8, y: 39, width: width - trailing - 8, height: 1))
            line.autoresizingMask = [.width]; line.boxType = .separator; view.addSubview(line)
        }
        view.setAccessibilityElement(true); view.setAccessibilityLabel(action.title + " " + caps.joined())
        return view
    }
}
