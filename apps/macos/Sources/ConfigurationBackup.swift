import Foundation

struct ConfigurationBackup: Codable {
    struct Plugin: Codable {
        let id: String
        let version: String
        let enabled: Bool
        let preferences: [String: String]
    }
    let format: Int
    let createdAt: Date
    let preferences: PreferenceValues
    let plugins: [Plugin]

    static func make(store: ExtensionStore, preferences: PreferenceValues) -> Self {
        Self(format: 1, createdAt: Date(), preferences: preferences, plugins: store.list().map { info in
            let names = Set(info.manifest.preferences.filter { $0.type != "secret" }.map(\.name))
            return Plugin(id: info.manifest.id, version: info.manifest.version, enabled: info.enabled,
                          preferences: info.preferences.filter { names.contains($0.key) })
        })
    }
    func data() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
    static func read(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw LauncherError("备份超过 2MB 限制。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == 1, value.plugins.count <= 500, Set(value.plugins.map(\.id)).count == value.plugins.count else { throw LauncherError("不支持的备份格式或重复插件。") }
        try value.validatePreferences()
        return value
    }
    private func validatePreferences() throws {
        let p = preferences
        guard ["system", "light", "dark"].contains(p.appearance), ["standard", "large"].contains(p.textSize),
              ["mouse", "main"].contains(p.screen), ["90", "immediate", "never"].contains(p.resetSearch),
              ["clear", "close"].contains(p.escape), ["low", "medium", "high"].contains(p.searchSensitivity ?? "medium"),
              p.aliases.values.allSatisfy({ $0.isEmpty || $0.range(of: "^[a-z][a-z0-9-]{0,20}$", options: .regularExpression) != nil }) else { throw LauncherError("备份包含无效设置。") }
        let shortcuts = [p.shortcut] + Array(p.commandShortcuts.values)
        guard p.commandShortcuts.keys.allSatisfy({ $0.range(of: "^[a-z][a-z0-9-]{0,40}\\.[a-z][a-z0-9-]{0,50}/[a-z][a-z0-9-]{0,50}$", options: .regularExpression) != nil }),
              shortcuts.allSatisfy({ $0.keyCode <= 127 && ($0.modifiers & 0x1900) != 0 && ($0.modifiers & ~UInt32(0x1b00)) == 0 }),
              Set(shortcuts.map { "\($0.keyCode):\($0.modifiers)" }).count == shortcuts.count else { throw LauncherError("备份包含无效或重复快捷键。") }
    }
    func skipped(in store: ExtensionStore) -> [String] {
        plugins.filter { plugin in !store.list().contains { $0.manifest.id == plugin.id && $0.manifest.version == plugin.version } }.map { "\($0.id) v\($0.version)" }
    }
    func restore(store: ExtensionStore, current: PreferenceValues, apply: (PreferenceValues) throws -> Void) throws -> URL {
        try validatePreferences()
        let installed = store.list()
        let matching = plugins.filter { plugin in installed.contains { $0.manifest.id == plugin.id && $0.manifest.version == plugin.version } }
        var keywords = Set<String>()
        for item in installed {
            let enabled = matching.first { $0.id == item.manifest.id }?.enabled ?? item.enabled
            guard enabled else { continue }
            for command in item.manifest.commands {
                let alias = preferences.aliases[item.manifest.id + "/" + command.id]
                for key in alias.flatMap({ $0.isEmpty ? nil : [$0] }) ?? command.keywords {
                    guard keywords.insert(key).inserted else { throw LauncherError("恢复后关键词 \(key) 冲突，请先修改备份。") }
                }
            }
        }
        for plugin in matching {
            let manifest = installed.first { $0.manifest.id == plugin.id }!.manifest
            for (key, value) in plugin.preferences {
                guard let field = manifest.preferences.first(where: { $0.name == key && $0.type != "secret" }),
                      value.count <= 10000, field.type != "dropdown" || (field.options ?? []).contains(value) else { throw LauncherError("插件 \(plugin.id) 的配置无效或包含密钥字段。") }
            }
        }
        let recovery = store.root.appendingPathComponent("backup-before-import-\(UUID().uuidString).json")
        try Self.make(store: store, preferences: current).data().write(to: recovery, options: .atomic)
        try store.run("BEGIN IMMEDIATE")
        var applied = false
        do {
            for plugin in matching {
                try store.savePreferences(plugin.id, plugin.preferences)
                try store.run("UPDATE extensions SET enabled=? WHERE id=?", [plugin.enabled ? "1" : "0", plugin.id])
            }
            try apply(preferences); applied = true
            try store.run("COMMIT")
            return recovery
        } catch {
            _ = try? store.run("ROLLBACK")
            if applied { try? apply(current) }
            throw error
        }
    }
}
