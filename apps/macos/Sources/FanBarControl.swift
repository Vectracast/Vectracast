import Foundation

/// The small, bounded surface that Vectracast shares with FanBar's privileged
/// helper. It deliberately mirrors FanBar's public XPC protocol instead of
/// reading SMC registers or accepting arbitrary commands.
@objc private protocol VectracastFanBarHelperProtocol {
    func getFanCount(reply: @escaping (Bool, Int, String?) -> Void)
    func getFan(_ index: Int, reply: @escaping (Bool, Float, Float, Float, Bool, String?) -> Void)
    func setAllFans(rpm: Float, reply: @escaping (Bool, String?) -> Void)
    func setCoolingPreset(_ rawValue: Int, reply: @escaping (Bool, String?) -> Void)
    func setAllFansToEightyPercent(reply: @escaping (Bool, String?) -> Void)
    func restoreAutomatic(reply: @escaping (Bool, String?) -> Void)
}

struct FanBarReading: Codable {
    let index: Int
    let currentRPM: Int
    let minimumRPM: Int
    let maximumRPM: Int
    let isManual: Bool
}

struct FanBarStatus: Codable {
    let available: Bool
    let fans: [FanBarReading]
    let error: String?
}

final class FanBarControl {
    static let shared = FanBarControl()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    func status() async throws -> FanBarStatus {
        let count = try await fanCount()
        guard (1...8).contains(count) else { throw LauncherError("FanBar 返回了无效的风扇数量。") }
        var fans: [FanBarReading] = []
        for index in 0..<count { fans.append(try await fan(index)) }
        return FanBarStatus(available: true, fans: fans, error: nil)
    }

    func perform(_ action: String, text: String) async throws {
        switch action {
        case "fanbar.restore": try await callVoid { proxy, reply in proxy.restoreAutomatic(reply: reply) }
        case "fanbar.eighty": try await callVoid { proxy, reply in proxy.setAllFansToEightyPercent(reply: reply) }
        case "fanbar.preset":
            guard let raw = Int(text), (0...3).contains(raw) else { throw LauncherError("FanBar 散热预设无效。") }
            try await callVoid { proxy, reply in proxy.setCoolingPreset(raw, reply: reply) }
        case "fanbar.rpm":
            guard let rpm = Int(text), (0...100_000).contains(rpm) else { throw LauncherError("FanBar 转速必须是 0–100000 的整数。") }
            try await callVoid { proxy, reply in proxy.setAllFans(rpm: Float(rpm), reply: reply) }
        default: throw LauncherError("不支持的 FanBar 操作。")
        }
    }

    private func fanCount() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            guard let proxy = proxy(onError: { continuation.resume(throwing: self.xpcFailure($0)) }) else { continuation.resume(throwing: unavailable()); return }
            proxy.getFanCount { success, count, message in
                if success { continuation.resume(returning: count) }
                else { continuation.resume(throwing: LauncherError(message ?? "无法读取 FanBar 风扇数量。")) }
            }
        }
    }

    private func fan(_ index: Int) async throws -> FanBarReading {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FanBarReading, Error>) in
            guard let proxy = proxy(onError: { continuation.resume(throwing: self.xpcFailure($0)) }) else { continuation.resume(throwing: unavailable()); return }
            proxy.getFan(index) { success, current, minimum, maximum, manual, message in
                if success {
                    continuation.resume(returning: FanBarReading(index: index, currentRPM: Int(current.rounded()), minimumRPM: Int(minimum.rounded()), maximumRPM: Int(maximum.rounded()), isManual: manual))
                } else { continuation.resume(throwing: LauncherError(message ?? "无法读取 FanBar 风扇 (index + 1)。")) }
            }
        }
    }

    private func callVoid(_ body: @escaping (VectracastFanBarHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = proxy(onError: { continuation.resume(throwing: self.xpcFailure($0)) }) else { continuation.resume(throwing: unavailable()); return }
            body(proxy) { success, message in
                if success { continuation.resume() }
                else { continuation.resume(throwing: LauncherError(message ?? "FanBar 控制操作失败。")) }
            }
        }
    }

    private func proxy(onError: @escaping (Error) -> Void) -> VectracastFanBarHelperProtocol? {
        lock.lock()
        if let connection { lock.unlock(); return connection.remoteObjectProxyWithErrorHandler(onError) as? VectracastFanBarHelperProtocol }
        let connection = NSXPCConnection(machServiceName: "local.fanbar.helper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VectracastFanBarHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in self?.clear(connection) }
        connection.interruptionHandler = { [weak self] in self?.clear(connection) }
        connection.resume(); self.connection = connection; lock.unlock()
        return connection.remoteObjectProxyWithErrorHandler(onError) as? VectracastFanBarHelperProtocol
    }

    private func clear(_ connection: NSXPCConnection) {
        lock.lock(); defer { lock.unlock() }
        if self.connection === connection { self.connection = nil }
    }

    private func unavailable() -> LauncherError {
        LauncherError("无法连接 FanBar 控制服务，请先启动 FanBar 并完成系统授权。")
    }

    private func xpcFailure(_ error: Error) -> LauncherError {
        LauncherError("无法连接 FanBar 控制服务：\(error.localizedDescription)")
    }
}
