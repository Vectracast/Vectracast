import Foundation

enum QueryFallback {
    static func entries(for extensions: [InstalledExtension], input: String) -> [ResultItem] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let candidates = extensions.filter(\.enabled).flatMap { info in
            info.manifest.commands.filter(\.isImplicit).map { (info, $0) }
        }
        guard !candidates.isEmpty else { return [] }
        let heading = ResultItem(id: "fallback-heading", title: "使用“\(String(query.prefix(80)))”处理", subtitle: nil, icon: nil, actions: [], groupHeading: true)
        return [heading] + candidates.map { info, command in
            ResultItem(
                id: "fallback/\(info.manifest.id)/\(command.id)",
                title: command.title,
                subtitle: "\(info.manifest.name) · 使用当前输入",
                icon: command.icon ?? info.manifest.icon,
                actions: [ResultAction(id: "use-input", title: "使用当前输入", type: "command.input", text: command.id, shortcut: ActionShortcut(key: "return", modifiers: []))],
                extensionID: info.manifest.id
            )
        }
    }
}
