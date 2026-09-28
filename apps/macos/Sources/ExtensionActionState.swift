import Foundation

/// Plugin-owned boolean state. Queries may read it; only explicit user actions may change it.
final class ExtensionActionState {
    static let shared = ExtensionActionState()
    private let root: URL
    private let lock = NSLock()
    init(root: URL? = nil) {
        self.root = (root ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHER_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Launcher")).appendingPathComponent("ActionState")
    }
    static func validKey(_ key: String) -> Bool { !key.isEmpty && key.utf8.count <= 256 && !key.contains("\0") }
    private func file(_ id: String) throws -> URL {
        guard id.range(of: "^[a-z][a-z0-9-]{0,40}\\.[a-z][a-z0-9-]{0,50}$", options: .regularExpression) != nil else { throw LauncherError("扩展标识无效") }
        return root.appendingPathComponent(id + ".json")
    }
    private func read(_ file: URL) throws -> [String: Bool] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: file))
    }
    func flags(_ id: String) throws -> [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        return try read(file(id))
    }
    @discardableResult func toggle(_ id: String, key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.validKey(key) else { throw LauncherError("存储键无效") }
        let url = try file(id)
        var flags = try read(url)
        let next = flags[key] != true
        if next { guard flags.count < 10000 else { throw LauncherError("扩展存储已满") }; flags[key] = true } else { flags.removeValue(forKey: key) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(flags).write(to: url, options: .atomic)
        return next
    }
}
