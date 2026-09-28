import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    var label: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + " " + key
    }
    static let initial = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Space")
}
struct PreferenceValues: Codable {
    // Optional additions preserve decoding of existing 0.2 preference files.
    var inputSource: String?
    var searchSensitivity: String?
    var developerMode: Bool?
    var developerKeepVisible: Bool?
    var developerPreserveQuery: Bool?
    var developerAutoReload: Bool?
    var captureCopy: Bool?
    var captureReveal: Bool?
    var appearance = "system"
    var textSize = "standard"
    var compact = false
    var showMenuBar = true
    var hideOnBlur = true
    var closeAfterCopy = false
    var screen = "mouse"
    var resetSearch = "90"
    var escape = "clear"
    var shortcut = Shortcut.initial
    var aliases: [String: String] = [:]
    var commandShortcuts: [String: Shortcut] = [:]
}
final class AppPreferences {
    static let changed = Notification.Name("LauncherPreferencesChanged")
    static let shared = AppPreferences()
    private(set) var values: PreferenceValues
    let url: URL
    init(root: URL? = nil) {
        let root = root ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHER_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Launcher")
        url = root.appendingPathComponent("preferences.json")
        values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PreferenceValues.self, from: $0) } ?? PreferenceValues()
    }
    @discardableResult func change(_ body: (inout PreferenceValues) -> Void) -> Bool {
        var next = values; body(&next)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            values = next; NotificationCenter.default.post(name: Self.changed, object: self); return true
        } catch { return false }
    }
    func keywords(_ info: InstalledExtension, _ command: ExtensionManifest.Command) -> [String] {
        return keywords(info.manifest.id, command)
    }
    func keywords(_ id: String, _ command: ExtensionManifest.Command) -> [String] {
        if let alias = values.aliases[id + "/" + command.id], !alias.isEmpty { return [alias] }
        return command.keywords
    }
    var appearance: NSAppearance? {
        values.appearance == "system" ? nil : NSAppearance(named: values.appearance == "light" ? .aqua : .darkAqua)
    }
}

final class ShortcutRecordingView: NSViewController {
    var onCancel: (() -> Void)?
    private(set) var hasError = false
    private let keys = NSStackView()
    private let status = NSTextField(labelWithString: "正在录制…")
    private let hint = NSTextField(labelWithString: "按下组合键 · Esc 取消")
    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 112))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: self, action: #selector(cancel))
        close.isBordered = false; close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: 234, y: 7, width: 18, height: 18); close.setAccessibilityLabel("取消录制"); view.addSubview(close)
        keys.orientation = .horizontal; keys.alignment = .centerY; keys.spacing = 5
        keys.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(keys)
        NSLayoutConstraint.activate([keys.centerXAnchor.constraint(equalTo: view.centerXAnchor), keys.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), keys.heightAnchor.constraint(equalToConstant: 32)])
        status.font = .systemFont(ofSize: 14, weight: .medium); status.alignment = .center
        status.frame = NSRect(x: 12, y: 65, width: 236, height: 20); view.addSubview(status)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; hint.alignment = .center
        hint.frame = NSRect(x: 8, y: 88, width: 244, height: 16); view.addSubview(hint)
        update(symbols: [])
    }
    func update(symbols: [String], error: String? = nil) {
        _ = view
        hasError = error != nil
        keys.arrangedSubviews.forEach { keys.removeArrangedSubview($0); $0.removeFromSuperview() }
        for symbol in symbols.isEmpty ? ["…"] : symbols {
            let cap = NSView(); cap.wantsLayer = true; cap.layer?.cornerRadius = 7
            cap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            let label = NSTextField(labelWithString: symbol); label.font = .systemFont(ofSize: 19, weight: .medium); label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false; cap.addSubview(label); keys.addArrangedSubview(cap)
            NSLayoutConstraint.activate([cap.widthAnchor.constraint(equalToConstant: symbol.count > 2 ? 58 : 32), cap.heightAnchor.constraint(equalToConstant: 32), label.centerXAnchor.constraint(equalTo: cap.centerXAnchor), label.centerYAnchor.constraint(equalTo: cap.centerYAnchor)])
        }
        status.stringValue = error ?? "正在录制…"; status.textColor = error == nil ? .labelColor : .systemOrange
        hint.stringValue = error == nil ? "按下组合键 · Esc 取消" : "请重试其他组合 · Esc 取消"
    }
    @objc private func cancel() { onCancel?() }
}

final class ShortcutRecorder: NSButton, NSPopoverDelegate {
    static weak var activeRecorder: ShortcutRecorder?
    var shortcut: Shortcut? { didSet { title = shortcut?.label ?? "录制快捷键" } }
    var onRecord: ((Shortcut) -> Bool)?
    private var recording = false
    private var keyMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private let popover = NSPopover()
    private let recordingView = ShortcutRecordingView()
    override var acceptsFirstResponder: Bool { true }
    init(_ shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut?.label ?? "录制快捷键"; bezelStyle = .rounded
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel("录制快捷键")
        popover.behavior = .transient; popover.animates = true; popover.delegate = self
        popover.contentViewController = recordingView; popover.contentSize = NSSize(width: 260, height: 112)
        recordingView.onCancel = { [weak self] in self?.stopRecording() }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func beginRecording() {
        guard let window else { return }
        Self.activeRecorder?.stopRecording()
        recording = true; Self.activeRecorder = self
        window.makeFirstResponder(self)
        recordingView.update(symbols: Self.symbols(NSEvent.modifierFlags))
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording,
                  event.window === self.window || event.window === self.recordingView.view.window else { return event }
            if event.type == .flagsChanged {
                let symbols = Self.symbols(event.modifierFlags)
                if !symbols.isEmpty || !self.recordingView.hasError { self.recordingView.update(symbols: symbols) }
                return event
            }
            self.keyDown(with: event); return nil
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.stopRecording() }
    }
    private func stopRecording() {
        recording = false
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
        if popover.isShown { popover.close() }
        title = shortcut?.label ?? "录制快捷键"
    }
    func popoverDidClose(_ notification: Notification) { stopRecording() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }; super.viewWillMove(toWindow: newWindow)
    }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
    private static func symbols(_ flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("⌃") }; if flags.contains(.option) { result.append("⌥") }
        if flags.contains(.shift) { result.append("⇧") }; if flags.contains(.command) { result.append("⌘") }
        return result
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopRecording(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            recordingView.update(symbols: Self.symbols(flags), error: "请同时按 ⌘、⌃ 或 ⌥"); return
        }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }; if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }; if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let names: [UInt16: String] = [49:"Space",36:"Return",48:"Tab",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"↖",119:"↘",116:"⇞",121:"⇟"]
        let key = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { recordingView.update(symbols: Self.symbols(flags), error: "暂不支持这个按键"); return }
        accept(Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, key: key))
    }
    func accept(_ recorded: Shortcut) {
        guard recording else { return }
        if onRecord?(recorded) == true { shortcut = recorded; stopRecording() }
        else {
            let parts = recorded.label.split(separator: " ", maxSplits: 1)
            let symbols = (parts.first.map { $0.map(String.init) } ?? []) + [recorded.key]
            recordingView.update(symbols: symbols, error: "快捷键不可用，请重试")
        }
    }
}
