import Foundation
import CryptoKit

struct LauncherError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct ExtensionManifest: Codable {
    struct Filter: Codable { let id: String; let title: String }
    struct Command: Codable { let id: String; let title: String; let keywords: [String]; let debounceMs: Int?; let inputMode: String?; let acceptsEmptyQuery: Bool?; let presentation: String?; let filters: [Filter]?; var searchPlaceholder: String? = nil
        var isImplicit: Bool { inputMode == "query" }
    }
    struct Permissions: Codable {
        let network: [String]?; let clipboard: [String]?; let applications: [String]?; let catalog: [String]?; let browser: [String]?; let files: [String]?
        private struct Key: CodingKey {
            let stringValue: String; let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard container.allKeys.allSatisfy({ ["network", "clipboard", "applications", "catalog", "browser", "files"].contains($0.stringValue) }) else {
                throw LauncherError("扩展声明了不支持的权限。")
            }
            network = try container.decodeIfPresent([String].self, forKey: Key(stringValue: "network")!)
            clipboard = try container.decodeIfPresent([String].self, forKey: Key(stringValue: "clipboard")!)
            applications = try container.decodeIfPresent([String].self, forKey: Key(stringValue: "applications")!)
            catalog = try container.decodeIfPresent([String].self, forKey: Key(stringValue: "catalog")!)
            files = try container.decodeIfPresent([String].self, forKey: Key(stringValue: "files")!)
            browser = try container.decodeIfPresent([String].self, forKey: Key(stringValue: "browser")!)
        }
    }
    struct Preference: Codable {
        let name: String; let title: String; let type: String; let required: Bool?; let defaultValue: String?
        let options: [String]?
    }
    let manifestVersion: Int
    let id: String
    let name: String
    let version: String
    let description: String
    let runtime: String
    let sdk: String
    let icon: String
    let entry: String
    let commands: [Command]
    let permissions: Permissions
    let preferences: [Preference]

    func validate() throws {
        func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        guard manifestVersion == 1, runtime == "standard-js", sdk == "0.1" else { throw LauncherError("扩展需要不受支持的运行时或 SDK 版本。") }
        guard matches(id, "^[a-z][a-z0-9-]{0,40}\\.[a-z][a-z0-9-]{0,50}$"),
              matches(version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"),
              !name.isEmpty, name.count <= 80, commands.count > 0, commands.count <= 20 else { throw LauncherError("扩展标识、版本或命令列表无效。") }
        var ids = Set<String>(); var aliases = Set<String>()
        for command in commands {
            guard matches(command.id, "^[a-z][a-z0-9-]{0,50}$"), ids.insert(command.id).inserted,
                  (command.isImplicit || !command.keywords.isEmpty), [nil, "keyword", "query"].contains(command.inputMode), (0...5000).contains(command.debounceMs ?? 0) else { throw LauncherError("命令声明无效。") }
            guard [nil, "detail", "list"].contains(command.presentation), (command.searchPlaceholder?.count ?? 0) <= 80, (command.filters?.count ?? 0) <= 10,
                  Set((command.filters ?? []).map(\.id)).count == (command.filters?.count ?? 0),
                  (command.filters ?? []).allSatisfy({ $0.id.count <= 30 && !$0.title.isEmpty && $0.title.count <= 30 }) else { throw LauncherError("展示配置无效。") }
            for keyword in command.keywords {
                guard matches(keyword, "^[a-z][a-z0-9-]{0,20}$"), aliases.insert(keyword).inserted else { throw LauncherError("扩展中存在无效或重复关键词。") }
            }
        }
        for origin in permissions.network ?? [] {
            guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.port == nil, url.path.isEmpty || url.path == "/",
                  !["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") else { throw LauncherError("网络权限只接受 HTTPS 公网域名。") }
        }
        guard Set(permissions.clipboard ?? []).isSubset(of: ["write", "history", "history-images", "paste"]) else { throw LauncherError("剪贴板权限仅支持 write/history/history-images/paste。") }
        guard permissions.clipboard?.contains("history-images") != true || permissions.clipboard?.contains("history") == true,
              permissions.clipboard?.contains("paste") != true || permissions.clipboard?.contains("write") == true else { throw LauncherError("图片历史需要 history，粘贴需要 write。") }
        guard Set(permissions.files ?? []).isSubset(of: ["search", "open"]), permissions.files?.contains("open") != true || permissions.files?.contains("search") == true else { throw LauncherError("文件能力仅支持 search/open，open 需要 search。") }
        guard Set(permissions.applications ?? []).isSubset(of: ["read", "open"]), permissions.applications?.contains("open") != true || permissions.applications?.contains("read") == true else { throw LauncherError("应用能力仅支持 read/open，open 需要 read。") }
        guard Set(permissions.catalog ?? []).isSubset(of: ["read", "install"]), permissions.catalog?.contains("install") != true || permissions.catalog?.contains("read") == true,
              Set(permissions.browser ?? []).isSubset(of: ["open"]) else { throw LauncherError("目录能力仅支持 read/install，浏览器能力仅支持 open。") }
        var fields = Set<String>()
        for pref in preferences {
            guard matches(pref.name, "^[a-zA-Z][a-zA-Z0-9]{0,40}$"), fields.insert(pref.name).inserted,
                  ["text", "secret", "dropdown"].contains(pref.type), pref.type != "dropdown" || !(pref.options ?? []).isEmpty else { throw LauncherError("偏好字段无效。") }
        }
    }
    var permissionSummary: String {
        var lines: [String] = []
        if permissions.files?.contains("search") == true { lines.append("搜索用户目录内 Spotlight 已索引文件的名称、路径和元数据（不读取内容）") }
        if permissions.files?.contains("open") == true { lines.append("打开文件或在 Finder 定位（用户选择后）") }
        if permissions.catalog?.contains("read") == true { lines.append("读取公开插件目录与已安装插件版本") }
        if permissions.catalog?.contains("install") == true { lines.append("请求安装目录中的插件（每次需用户确认权限）") }
        if permissions.browser?.contains("open") == true { lines.append("在浏览器打开 HTTPS 链接（用户选择后）") }
        if permissions.clipboard?.contains("paste") == true { lines.append("粘贴到上一应用（用户选择后，需要系统辅助功能授权）") }
        if permissions.clipboard?.contains("history-images") == true { lines.append("后台保存图片剪贴板（本地图片缓存，最多 100MB）") }
        if permissions.clipboard?.contains("history") == true { lines.append("后台记录文本剪贴板（本地保存 7 天，最多 200 条；可读取、删除和清空记录）") }
        if commands.contains(where: \.isImplicit) { lines.append("读取主搜索输入（无需关键词执行）") }
        if permissions.clipboard?.contains("write") == true { lines.append("写入剪贴板（用户选择后）") }
        lines += (permissions.applications ?? []).map { $0 == "read" ? "读取已安装应用列表" : "打开应用（用户选择后）" }
        lines += (permissions.network ?? []).map { "联网：\($0)" }
        return lines.joined(separator: "\n")
    }
}

struct ExtensionPackage: Codable {
    let format: Int
    let manifest: ExtensionManifest
    let source: String
    let sha256: String
    func validate() throws {
        try manifest.validate()
        guard format == 1, source.utf8.count < 2_000_000,
              SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw LauncherError("安装包损坏或超过大小限制。") }
    }
}

struct InstalledExtension {
    let manifest: ExtensionManifest
    let source: String
    let enabled: Bool
    let previous: String?
    let preferences: [String: String]
    let development: Bool
}

struct ResultAction: Codable {
    let id: String
    let title: String
    let type: String
    let text: String?
    var icon: String? = nil
    var shortcut: ActionShortcut? = nil
    var section: String? = nil
}

struct ActionShortcut: Codable {
    let key: String
    let modifiers: [String]
    static func isValid(_ value: ActionShortcut) -> Bool {
        (value.key == "return" || (value.key.count == 1 && value.key.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value < 127 })) &&
        Set(value.modifiers).isSubset(of: ["command", "option", "shift", "control"]) && Set(value.modifiers).count == value.modifiers.count &&
        (value.key == "return" || value.modifiers.contains("command") || value.modifiers.contains("control"))
    }
}

struct ResultPreview: Codable {
    let text: String?
    let historyImageID: String?
}
struct ResultMetadata: Codable { let label: String; let value: String }
struct ResultItem: Codable {
    var id: String
    let title: String
    var subtitle: String?
    var icon: String?
    var actions: [ResultAction]
    var detail: String?
    var applicationPath: String?
    var applicationId: String?
    var extensionID: String?
    var preview: ResultPreview?
    var metadata: [ResultMetadata]?
    var group: String?
    var catalogID: String?
    var groupHeading: Bool?
    var fileID: String? = nil
    var filePath: String? = nil

    static func message(_ title: String, _ subtitle: String, icon: String = "info.circle", actions: [ResultAction] = []) -> ResultItem {
        ResultItem(id: "message", title: title, subtitle: subtitle, icon: icon, actions: actions)
    }
}

struct QueryResult: Codable { let items: [ResultItem] }
