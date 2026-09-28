import AppKit

let args = CommandLine.arguments
func option(_ name: String) -> String? { guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }; return args[index + 1] }

if CommandLine.arguments.contains("--probe") {
    let path = NSTemporaryDirectory() + "launcher-sandbox-probe-" + UUID().uuidString
    try Data("sentinel".utf8).write(to: URL(fileURLWithPath: path))
    let connection = NSXPCConnection(serviceName: "local.launcher.ExtensionHost")
    connection.remoteObjectInterface = NSXPCInterface(with: RuntimeProtocol.self)
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in print("XPC ERROR: \(error)"); exit(1) } as! RuntimeProtocol
    proxy.probe(path) { result in
        print(result)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".write")
        exit(0)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { print("probe timed out"); exit(1) }
    RunLoop.main.run()
}

do {
    let store = try ExtensionStore()
    if let path = option("--backup-export") {
        try ConfigurationBackup.make(store: store, preferences: AppPreferences.shared.values).data().write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Exported configuration without secrets"); exit(0)
    }
    if let path = option("--backup-import") {
        guard args.contains("--apply") else { throw LauncherError("恢复配置需要 --apply。") }
        let backup = try ConfigurationBackup.read(URL(fileURLWithPath: path))
        let skipped = backup.skipped(in: store)
        let recovery = try backup.restore(store: store, current: AppPreferences.shared.values) { values in
            guard AppPreferences.shared.change({ $0 = values }) else { throw LauncherError("保存设置失败。") }
        }
        print(jsonString(["recovery": recovery.path, "skipped": skipped])); exit(0)
    }
    if let path = option("--install") {
        let manifest = try store.install(Data(contentsOf: URL(fileURLWithPath: path)), acceptPermissions: args.contains("--accept-permissions"), development: args.contains("--development"))
        print("Installed \(manifest.id) v\(manifest.version)"); exit(0)
    }
    if args.contains("--preferences") { print(String(data: try JSONEncoder().encode(AppPreferences.shared.values), encoding: .utf8)!); exit(0) }
    if args.contains("--list") {
        print(jsonString(store.list().map { ["id": $0.manifest.id, "version": $0.manifest.version, "enabled": $0.enabled, "development": $0.development] as [String: Any] })); exit(0)
    }
    if let id = option("--rollback") { try store.rollback(id); print("Rolled back \(id)"); exit(0) }
    if let input = option("--implicit-query") {
        let runner = ImplicitQueryRunner()
        runner.query(store.list(), input: input) { items, finished in
            if finished { print(String(data: try! JSONEncoder().encode(QueryResult(items: items)), encoding: .utf8)!); exit(0) }
        }
        withExtendedLifetime(runner) { RunLoop.main.run() }
    }
    if let id = option("--verify-cancellation") {
        guard let info = store.list().first(where: { $0.manifest.id == id && $0.enabled }), let command = info.manifest.commands.first?.id else { throw LauncherError("测试扩展不存在。") }
        let runtime = RuntimeClient()
        let implicit = ImplicitQueryRunner()
        let execute: (String, @escaping ([ResultItem]) -> Void) -> Void = { input, completion in
            if args.contains("--implicit") {
                implicit.query([info], input: input) { rows, finished in if finished { completion(rows) } }
            } else {
                runtime.query(info, command: command, query: input, rawInput: input) { result in completion((try? result.get()) ?? []) }
            }
        }
        var oldDeliveries = 0, newDeliveries = 0
        execute("slow") { _ in oldDeliveries += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            execute("latest") { rows in
                if rows.first?.title == "latest" { newDeliveries += 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print(jsonString(["oldDeliveries": oldDeliveries, "newDeliveries": newDeliveries]))
            exit(oldDeliveries == 0 && newDeliveries == 1 ? 0 : 1)
        }
        withExtendedLifetime((runtime, implicit)) { RunLoop.main.run() }
    }
    if let id = option("--query"), let index = args.firstIndex(of: "--query"), index + 3 < args.count {
        guard let info = store.list().first(where: { $0.manifest.id == id && $0.enabled }) else { throw LauncherError("扩展未安装或已停用。") }
        let runtime = RuntimeClient()
        runtime.query(info, command: args[index + 2], query: args[index + 3], rawInput: args[index + 3]) { result in
            switch result {
            case .success(let items): print(String(data: try! JSONEncoder().encode(QueryResult(items: items)), encoding: .utf8)!); exit(0)
            case .failure(let error): print(jsonString(["error": error.localizedDescription])); exit(1)
            }
        }
        withExtendedLifetime(runtime) { RunLoop.main.run() }
    }
    if args.count > 1 { throw LauncherError("未知命令或参数不完整。") }
    let app = NSApplication.shared
    let delegate = AppDelegate(store: store)
    app.delegate = delegate
    app.run()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
