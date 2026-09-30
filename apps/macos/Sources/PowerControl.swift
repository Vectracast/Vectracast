import Foundation

/// The extension gets status and two fixed actions, never a shell or arbitrary pmset arguments.
final class PowerControl {
    static let shared = PowerControl()
    struct Snapshot: Codable {
        let version: Int
        let sleepDisabled: Bool
        let createdAt: Date
    }
    struct Status: Codable {
        let sleepDisabled: Bool
        let canRestore: Bool
        let powerSource: String
    }
    private let lock = NSLock()
    private let snapshotURL: URL
    private let read: ([String]) throws -> String
    private let write: (Bool) throws -> Void

    init(root: URL? = nil,
         read: @escaping ([String]) throws -> String = PowerControl.readSystem,
         write: @escaping (Bool) throws -> Void = PowerControl.writeSystem) {
        let home = root ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHER_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Launcher")
        snapshotURL = home.appendingPathComponent("power-control/snapshot.json")
        self.read = read; self.write = write
    }

    static func sleepDisabled(_ output: String) throws -> Bool {
        // pmset omits SleepDisabled when no explicit value exists. Do not treat failed/unknown output as false.
        guard output.contains("System-wide power settings:"), output.contains("Currently in use:") else {
            throw LauncherError("无法识别系统电源状态，未修改设置。")
        }
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "SleepDisabled" {
                guard fields.count == 2, ["0", "1"].contains(fields[1]) else { throw LauncherError("系统休眠状态无效。") }
                return fields[1] == "1"
            }
        }
        return false
    }

    private func snapshot() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        let data = try Data(contentsOf: snapshotURL)
        guard data.count < 4096, let value = try? JSONDecoder().decode(Snapshot.self, from: data), value.version == 1 else {
            throw LauncherError("电源恢复记录损坏，未修改系统设置。")
        }
        return value
    }

    func status() throws -> Status {
        guard lock.try() else { throw LauncherError("正在处理电源设置，请完成系统授权后刷新。") }
        defer { lock.unlock() }
        let disabled = try Self.sleepDisabled(read(["-g"]))
        let battery = try read(["-g", "batt"])
        let source = battery.contains("'AC Power'") ? "ac" : battery.contains("'Battery Power'") ? "battery" : "unknown"
        return Status(sleepDisabled: disabled, canRestore: try snapshot() != nil, powerSource: source)
    }

    func perform(_ action: String) throws {
        guard ["power.enable", "power.restore"].contains(action) else { throw LauncherError("不支持的电源操作。") }
        guard lock.try() else { throw LauncherError("已有电源操作正在进行。") }
        defer { lock.unlock() }
        let current = try Self.sleepDisabled(read(["-g"]))
        let saved = try snapshot()
        let target: Bool
        if action == "power.enable" {
            if current {
                guard saved != nil else { throw LauncherError("其他工具已禁用系统休眠；请先在原工具中恢复。") }
                return
            }
            if saved == nil {
                try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Snapshot(version: 1, sleepDisabled: current, createdAt: Date())).write(to: snapshotURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
            }
            target = true
        } else {
            guard let saved else { throw LauncherError("没有本插件保存的原设置，未修改系统配置。") }
            target = saved.sleepDisabled
        }
        // Save before authorization. Keep the recovery record on cancellation, timeout or verification failure.
        try write(target)
        guard try Self.sleepDisabled(read(["-g"])) == target else {
            throw LauncherError("系统未确认设置生效。恢复记录已保留，请重试或选择恢复原设置。")
        }
        if action == "power.restore" { try FileManager.default.removeItem(at: snapshotURL) }
    }

    private static func process(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"; task.environment = environment
        let output = Pipe(); let errors = Pipe(); task.standardOutput = output; task.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        try task.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if task.isRunning { task.terminate() }
            throw LauncherError("系统电源操作超时。若已提交授权，请刷新状态；恢复记录会保留。")
        }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            if message.contains("-128") { throw LauncherError("已取消系统授权，恢复记录已保留。") }
            throw LauncherError("系统电源操作失败：" + String(message.prefix(300)))
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    static func readSystem(_ arguments: [String]) throws -> String {
        try process("/usr/bin/pmset", arguments, timeout: 5)
    }
    static func writeSystem(_ disabled: Bool) throws {
        // Boolean interpolation only. No plugin data, paths, or credentials enter this command.
        let script = "with timeout of 120 seconds\ndo shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges\nend timeout"
        _ = try process("/usr/bin/osascript", ["-e", script], timeout: 130)
    }
}
