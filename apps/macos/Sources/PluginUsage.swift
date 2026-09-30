import Foundation

/// Local entry/use counts only. Search text and plugin results are never stored here.
final class PluginUsage {
    struct Entry: Codable { var count: Int; var lastUsed: Date }
    private let file: URL
    private var entries: [String: Entry]
    init(root: URL) {
        file = root.appendingPathComponent("plugin-usage.json")
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
    }
    func record(_ id: String, now: Date = Date()) {
        let count = max(0, min(entries[id]?.count ?? 0, 9999)) + 1
        entries[id] = Entry(count: count, lastUsed: now)
        if entries.count > 2000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(2000).map { ($0.key, $0.value) })
        }
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
    func ranked(_ extensions: [InstalledExtension], now: Date = Date()) -> [InstalledExtension] {
        func score(_ id: String) -> Double {
            guard let entry = entries[id], entry.count > 0 else { return 0 }
            let days = max(0, now.timeIntervalSince(entry.lastUsed) / 86400)
            return (1 + log2(Double(min(entry.count, 10000)))) / (1 + days / 7)
        }
        return extensions.filter(\.enabled).sorted {
            let a = score($0.manifest.id), b = score($1.manifest.id)
            if a != b { return a > b }
            let dateA = entries[$0.manifest.id]?.lastUsed ?? .distantPast
            let dateB = entries[$1.manifest.id]?.lastUsed ?? .distantPast
            if dateA != dateB { return dateA > dateB }
            let order = $0.manifest.name.localizedStandardCompare($1.manifest.name)
            return order == .orderedSame ? $0.manifest.id < $1.manifest.id : order == .orderedAscending
        }
    }
    func items(for extensions: [InstalledExtension], keywords: (InstalledExtension, ExtensionManifest.Command) -> [String]) -> [ResultItem] {
        ranked(extensions).flatMap { info in
            info.manifest.commands.map { command in
                let aliases = keywords(info, command)
                return ResultItem(id: "browse/\(info.manifest.id)/\(command.id)", title: command.title,
                                  subtitle: info.manifest.name + (aliases.isEmpty ? "" : " · " + aliases.joined(separator: "、")),
                                  icon: command.icon ?? info.manifest.icon,
                                  actions: [ResultAction(id: "open", title: "打开命令", type: "command.open", text: command.id),
                                            ResultAction(id: "settings", title: "扩展设置", type: "settings.open", text: info.manifest.id)],
                                  extensionID: info.manifest.id)
            }
        }
    }
}
