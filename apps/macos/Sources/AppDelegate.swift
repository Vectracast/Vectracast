import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: ExtensionStore
    var launcher: LauncherWindow!
    var settings: ExtensionWindow!
    private var developerWindows: [DeveloperWindow.Kind: DeveloperWindow] = [:]
    private var distributionWindows: [String: DistributionWindow] = [:]
    var statusItem: NSStatusItem!
    private var hotKeys: [String: EventHotKeyRef] = [:]
    private var identifiers: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var observer: NSObjectProtocol?
    init(store: ExtensionStore) { self.store = store }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = BrandAssets.logo
        NSApp.setActivationPolicy(.accessory); createMenu()
        launcher = LauncherWindow(store: store); settings = ExtensionWindow(store: store)
        launcher.onPluginsChanged = { [weak self] in self?.settings.refreshInstalledExtensions() }
        launcher.onSettings = { [weak self] id in self?.openPreferences(id) }
        settings.onPresentationChange = { [weak self] presented in self?.setSettingsPresented(presented) }
        settings.onDeveloperWindow = { [weak self] kind in self?.openDeveloperWindow(kind) }
        settings.onDistribution = { [weak self] plugins in self?.openDistribution(plugins: plugins) }
        settings.onChange = { [weak self] in self?.launcher.refresh() }
        settings.onShortcut = { [weak self] key, shortcut in self?.setShortcut(key, shortcut) ?? false }
        settings.onImportPreferences = { [weak self] values in
            guard let self else { throw LauncherError("应用已关闭。") }
            let old = AppPreferences.shared.values
            func replaceBindings(_ values: PreferenceValues) -> Bool {
                self.hotKeys.values.forEach { UnregisterEventHotKey($0) }; self.hotKeys.removeAll(); self.identifiers.removeAll()
                guard self.register("launcher", values.shortcut) else { return false }
                for (key, shortcut) in values.commandShortcuts { if !self.register(key, shortcut) { return false } }
                return true
            }
            guard replaceBindings(values) else { _ = replaceBindings(old); throw LauncherError("备份中的快捷键已被占用，保留原配置。") }
            guard AppPreferences.shared.change({ $0 = values }) else { _ = replaceBindings(old); throw LauncherError("保存设置失败，已恢复原快捷键。") }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandAssets.menuBar
        statusItem.button?.toolTip = "Vectracast"
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示 Vectracast", action: #selector(toggle), keyEquivalent: ""); show.target = self; menu.addItem(show)
        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); prefs.target = self; menu.addItem(prefs)
        let catalog = NSMenuItem(title: "发现插件…", action: #selector(openPluginCatalog), keyEquivalent: ""); catalog.target = self; menu.addItem(catalog)
        let updates = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: ""); updates.target = self; menu.addItem(updates)
        menu.addItem(.separator()); menu.addItem(NSMenuItem(title: "退出 Vectracast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")); statusItem.menu = menu
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            let value = id.id
            DispatchQueue.main.async { delegate.trigger(value) }; return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), nil)
        _ = register("launcher", AppPreferences.shared.values.shortcut)
        for (key, shortcut) in AppPreferences.shared.values.commandShortcuts { _ = register(key, shortcut) }
        observer = NotificationCenter.default.addObserver(forName: AppPreferences.changed, object: nil, queue: .main) { [weak self] _ in self?.applyPreferences() }
        ClipboardHistory.shared.start(store: store)
        applyPreferences(); launcher.show()
    }
    private func register(_ key: String, _ shortcut: Shortcut) -> Bool {
        var reference: EventHotKeyRef?
        let id = nextID; nextID += 1
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4c4e4348, id: id), GetApplicationEventTarget(), 0, &reference) == noErr, let reference else { return false }
        if let old = hotKeys[key] { UnregisterEventHotKey(old) }
        identifiers = identifiers.filter { $0.value != key }; identifiers[id] = key; hotKeys[key] = reference; return true
    }
    @objc private func openPluginCatalog() { openDistribution(plugins: true) }
    @objc private func checkForUpdates() { openDistribution(plugins: false) }
    private func openDistribution(plugins: Bool) {
        if plugins { openStorePlugin(); return }
        if distributionWindows["updates"] == nil { distributionWindows["updates"] = DistributionWindow() }
        distributionWindows["updates"]?.show()
    }
    private func openStorePlugin() {
        do {
            if let installed = store.list().first(where: { $0.manifest.id == "local.plugin-store" }) {
                if !installed.enabled { settings.show(installed.manifest.id); return }
            } else {
                guard let url = Bundle.main.url(forResource: "PluginStore", withExtension: "launcher-extension") else { throw LauncherError("缺少随附商店包，请重新构建应用。") }
                let data = try Data(contentsOf: url), package = try JSONDecoder().decode(ExtensionPackage.self, from: data); try package.validate()
                _ = try store.install(data, acceptPermissions: true); settings.refreshInstalledExtensions()
            }
            // Keep Settings available behind the launcher. Closing it switches activation policy
            // to accessory asynchronously, which can deactivate and immediately hide the launcher.
            if settings.window.isVisible { settings.window.orderBack(nil) }
            launcher.show(commandInput: "插件商店")
        } catch { let alert = NSAlert(error: error); alert.runModal() }
    }
    private func setShortcut(_ key: String, _ shortcut: Shortcut?) -> Bool {
        let old = key == "launcher" ? AppPreferences.shared.values.shortcut : AppPreferences.shared.values.commandShortcuts[key]
        if old == shortcut { return true }
        if let shortcut {
            guard register(key, shortcut) else { return false }
        } else if let previous = hotKeys.removeValue(forKey: key) { UnregisterEventHotKey(previous); identifiers = identifiers.filter { $0.value != key } }
        return AppPreferences.shared.change { values in
            if key == "launcher", let shortcut { values.shortcut = shortcut }
            else { values.commandShortcuts[key] = shortcut }
        }
    }
    private func trigger(_ id: UInt32) {
        guard let key = identifiers[id] else { return }
        if let recorder = ShortcutRecorder.activeRecorder {
            if let shortcut = key == "launcher" ? AppPreferences.shared.values.shortcut : AppPreferences.shared.values.commandShortcuts[key] { recorder.accept(shortcut) }
            return
        }
        if key == "launcher" { launcher.toggle(); return }
        for info in store.list() where info.enabled {
            if let command = info.manifest.commands.first(where: { info.manifest.id + "/" + $0.id == key }) {
                launcher.show(commandInput: (AppPreferences.shared.keywords(info, command).first ?? "") + " "); return
            }
        }
    }
    private func applyPreferences() { statusItem?.isVisible = AppPreferences.shared.values.showMenuBar; launcher?.applyPreferences(); settings?.applyAppearance(); developerWindows.values.forEach { $0.applyAppearance() } }
    private func openPreferences(_ id: String?) { launcher.dismissForSettings(); settings.show(id) }
    private func openDeveloperWindow(_ kind: DeveloperWindow.Kind) {
        if developerWindows[kind] == nil {
            let controller = DeveloperWindow(kind, store: store)
            controller.onPresentationChange = { [weak self] in self?.updateDockPresentation() }
            developerWindows[kind] = controller
        }
        launcher.dismissForSettings(); developerWindows[kind]?.show()
    }
    private func setSettingsPresented(_ presented: Bool) { updateDockPresentation() }
    private func updateDockPresentation() {
        let presented = settings.isPresented || developerWindows.values.contains { $0.isPresented }
        if presented { NSApp.setActivationPolicy(.regular) }
        else {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.settings.isPresented, !self.developerWindows.values.contains(where: { $0.isPresented }) else { return }
                NSApp.setActivationPolicy(.accessory); self.recordDockState()
            }
        }
        recordDockState()
    }
    private func recordDockState() {
        let state: [String: Any] = ["settingsOpen": settings.isPresented, "developerWindowsOpen": developerWindows.values.filter { $0.isPresented }.count, "dockVisible": NSApp.activationPolicy() == .regular]
        try? Data(jsonString(state).utf8).write(to: store.root.appendingPathComponent("dock-state.json"), options: .atomic)
    }
    private func createMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); prefs.target = self; appMenu.addItem(prefs)
        let catalog = NSMenuItem(title: "发现插件…", action: #selector(openPluginCatalog), keyEquivalent: ""); catalog.target = self; appMenu.addItem(catalog)
        let updates = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: ""); updates.target = self; appMenu.addItem(updates)
        let capture = NSMenuItem(title: "窗口截图", action: #selector(captureWindow), keyEquivalent: "S"); capture.keyEquivalentModifierMask = [.command, .shift]; capture.target = self; appMenu.addItem(capture)
        appMenu.addItem(.separator()); appMenu.addItem(NSMenuItem(title: "退出 Vectracast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")); appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key)) }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }
    @objc func toggle() { launcher.toggle() }
    @objc func captureWindow() { launcher.captureWindow() }
    func applicationWillTerminate(_ notification: Notification) { launcher?.restoreInputSource() }
    @objc func openSettings() { openPreferences(nil) }
    func applicationDidBecomeActive(_ notification: Notification) { launcher?.focusSearch(); launcher?.activateInputSourceIfReady() }
    func applicationDidResignActive(_ notification: Notification) { launcher?.dismissOnBlur() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let developer = developerWindows.values.first(where: { $0.isPresented && $0.window.isMainWindow }) ?? developerWindows.values.first(where: { $0.isPresented }), !settings.window.isKeyWindow { developer.show() }
        else if settings.isPresented { settings.bringToFront() } else { launcher.show() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
