import Foundation
import SQLite3
import Security

final class ExtensionStore {
    let root: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL? = nil) throws {
        self.root = root ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHER_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Launcher")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        guard sqlite3_open(self.root.appendingPathComponent("launcher.sqlite").path, &db) == SQLITE_OK else { throw LauncherError("无法打开扩展数据库。") }
        sqlite3_busy_timeout(db, 5000)
        try run("PRAGMA journal_mode=WAL")
        try run("CREATE TABLE IF NOT EXISTS extensions (id TEXT PRIMARY KEY, current TEXT NOT NULL, previous TEXT, enabled TEXT NOT NULL DEFAULT '1', preferences TEXT NOT NULL DEFAULT '{}', development TEXT NOT NULL DEFAULT '0')")
        try run("CREATE TABLE IF NOT EXISTS versions (id TEXT, version TEXT, package TEXT NOT NULL, PRIMARY KEY(id, version))")
    }
    deinit { sqlite3_close(db) }

    @discardableResult func run(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw LauncherError("数据库操作失败。") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        var rows: [[String: String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, i) { row[String(cString: sqlite3_column_name(statement, i))] = String(cString: text) }
            }
            rows.append(row); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw LauncherError("数据库写入失败。") }
        return rows
    }

    func list() -> [InstalledExtension] {
        guard let rows = try? run("SELECT e.*, v.package FROM extensions e JOIN versions v ON e.id=v.id AND e.current=v.version ORDER BY e.id") else { return [] }
        return rows.compactMap { row in
            guard let raw = row["package"], let package = try? JSONDecoder().decode(ExtensionPackage.self, from: Data(raw.utf8)) else { return nil }
            return InstalledExtension(manifest: package.manifest, source: package.source, enabled: row["enabled"] == "1", previous: row["previous"],
                                      preferences: (try? JSONDecoder().decode([String: String].self, from: Data((row["preferences"] ?? "{}").utf8))) ?? [:], development: row["development"] == "1")
        }
    }

    func install(_ data: Data, acceptPermissions: Bool, development: Bool = false) throws -> ExtensionManifest {
        guard data.count < 3_000_000 else { throw LauncherError("扩展包超过 3MB 限制。") }
        let package = try JSONDecoder().decode(ExtensionPackage.self, from: data)
        try package.validate()
        let existing = list().first { $0.manifest.id == package.manifest.id }
        let newPermissions = jsonString(try JSONSerialization.jsonObject(with: JSONEncoder().encode(package.manifest.permissions)))
        let oldPermissions = existing.flatMap { try? JSONEncoder().encode($0.manifest.permissions) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }.map(jsonString)
        if !acceptPermissions && (newPermissions != oldPermissions || (package.manifest.commands.contains(where: \.isImplicit) && existing?.manifest.commands.contains(where: \.isImplicit) != true)) { throw LauncherError("需要确认扩展权限。CLI 安装请明确传入 --accept-permissions。") }
        let keywords = Set(package.manifest.commands.flatMap { AppPreferences.shared.keywords(package.manifest.id, $0) })
        for other in list() where other.manifest.id != package.manifest.id && other.enabled {
            guard keywords.isDisjoint(with: other.manifest.commands.flatMap { AppPreferences.shared.keywords(other, $0) }) else { throw LauncherError("关键词与 \(other.manifest.name) 冲突，请修改 manifest 后再安装。") }
        }
        if let old = try run("SELECT package FROM versions WHERE id=? AND version=?", [package.manifest.id, package.manifest.version]).first?["package"],
           let oldPackage = try? JSONDecoder().decode(ExtensionPackage.self, from: Data(old.utf8)) {
            let oldManifest = jsonString(try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldPackage.manifest)))
            let newManifest = jsonString(try JSONSerialization.jsonObject(with: JSONEncoder().encode(package.manifest)))
            if oldPackage.sha256 != package.sha256 || oldManifest != newManifest {
                guard development && existing?.development == true else { throw LauncherError("已存在不同内容的相同版本，请增加版本号。") }
            }
        }
        let serialized = String(data: try JSONEncoder().encode(package), encoding: .utf8)!
        try run("BEGIN IMMEDIATE")
        do {
            try run("INSERT OR REPLACE INTO versions (id,version,package) VALUES (?,?,?)", [package.manifest.id, package.manifest.version, serialized])
            let previous = existing?.manifest.version == package.manifest.version ? existing?.previous : existing?.manifest.version
            try run("INSERT INTO extensions (id,current,previous,development) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET current=excluded.current, previous=excluded.previous, development=excluded.development", [package.manifest.id, package.manifest.version, previous, development ? "1" : "0"])
            try run("COMMIT")
        } catch { _ = try? run("ROLLBACK"); throw error }
        return package.manifest
    }

    func rollback(_ id: String) throws {
        guard let item = list().first(where: { $0.manifest.id == id }), let previous = item.previous else { throw LauncherError("没有可回滚的版本。") }
        guard let raw = try run("SELECT package FROM versions WHERE id=? AND version=?", [id, previous]).first?["package"] else { throw LauncherError("回滚版本不存在。") }
        let package = try JSONDecoder().decode(ExtensionPackage.self, from: Data(raw.utf8))
        if item.enabled {
            let keys = Set(package.manifest.commands.flatMap { AppPreferences.shared.keywords(package.manifest.id, $0) })
            guard list().filter({ $0.enabled && $0.manifest.id != id }).allSatisfy({ other in keys.isDisjoint(with: other.manifest.commands.flatMap { AppPreferences.shared.keywords(other, $0) }) }) else { throw LauncherError("回滚版本的关键词与已启用扩展冲突。") }
        }
        try run("UPDATE extensions SET current=?, previous=? WHERE id=?", [previous, item.manifest.version, id])
    }
    func setEnabled(_ id: String, _ enabled: Bool) throws {
        if enabled, let item = list().first(where: { $0.manifest.id == id }) {
            let keys = Set(item.manifest.commands.flatMap { AppPreferences.shared.keywords(item, $0) })
            guard list().filter({ $0.enabled && $0.manifest.id != id }).allSatisfy({ other in keys.isDisjoint(with: other.manifest.commands.flatMap { AppPreferences.shared.keywords(other, $0) }) }) else { throw LauncherError("关键词与已启用扩展冲突。") }
        }
        try run("UPDATE extensions SET enabled=? WHERE id=?", [enabled ? "1" : "0", id])
    }
    func savePreferences(_ id: String, _ values: [String: String]) throws { try run("UPDATE extensions SET preferences=? WHERE id=?", [jsonString(values), id]) }
    func uninstall(_ id: String) throws {
        guard list().contains(where: { $0.manifest.id == id }) else { throw LauncherError("扩展不存在。") }
        try run("BEGIN IMMEDIATE")
        do { try run("DELETE FROM extensions WHERE id=?", [id]); try run("DELETE FROM versions WHERE id=?", [id]); try run("COMMIT") }
        catch { _ = try? run("ROLLBACK"); throw error }
        let history = ClipboardHistory.archiveURL(root: root, extensionID: id)
        if FileManager.default.fileExists(atPath: history.path) { try FileManager.default.removeItem(at: history) }
        let assets = history.deletingPathExtension().appendingPathExtension("assets")
        if FileManager.default.fileExists(atPath: assets.path) { try FileManager.default.removeItem(at: assets) }
        Keychain.removeAll(id)
    }
}

enum Keychain {
    static func get(_ extensionID: String, _ name: String) -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.launcher." + extensionID,
                                   kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ extensionID: String, _ name: String, _ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.launcher." + extensionID, kSecAttrAccount as String: name]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LauncherError("无法保存密钥到钥匙串。") }
        } else if status != errSecSuccess { throw LauncherError("无法更新钥匙串。") }
    }
    static func removeAll(_ id: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "local.launcher." + id] as CFDictionary) }
}
