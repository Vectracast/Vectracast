import Foundation

final class NetworkRequest: NSObject, URLSessionDataDelegate {
    var session: URLSession!
    var data = Data()
    var response: HTTPURLResponse?
    var completion: ((String) -> Void)?
    init(request: URLRequest, completion: @escaping (String) -> Void) {
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }
    func cancel() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(response.expectedContentLength > 2_000_000 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.data.append(data)
        if self.data.count > 2_000_000 { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { completion = nil; session.finishTasksAndInvalidate() }
        if error != nil { completion?(jsonString(["error": "网络请求失败、超时或已取消。"])); return }
        guard let response else { completion?(jsonString(["error": "服务未返回响应。"])); return }
        completion?(jsonString(["value": ["status": response.statusCode, "body": String(data: data, encoding: .utf8) ?? ""]]))
    }
}

// Mutable request and issued-handle state is protected by lock.
final class CapabilityBroker: NSObject, BrokerProtocol, @unchecked Sendable {
    let extensionInfo: InstalledExtension
    private let lock = NSLock()
    private var requests: [NetworkRequest] = []
    private var cancelled = false
    private var historyIDs = Set<String>()
    private var catalogIDs = Set<String>()
    private var catalogRequestCount = 0
    func issuedCatalogID(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !cancelled && catalogIDs.contains(id) }
    func issuedHistoryID(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !cancelled && historyIDs.contains(id) }
    private var fileSearch: FileSearch?
    private var fileURLs: [String: URL] = [:]
    private var fileSearchCount = 0
    func fileURL(_ id: String) -> URL? { lock.lock(); defer { lock.unlock() }; return cancelled ? nil : fileURLs[id] }
    private var applicationURLs: [String: URL] = [:]
    init(_ info: InstalledExtension) { self.extensionInfo = info }

    func cancel() {
        lock.lock(); cancelled = true; let pending = requests; requests = []; lock.unlock()
        pending.forEach { $0.cancel() }
        DispatchQueue.main.async { self.fileSearch?.cancel(); self.fileSearch = nil }
    }
    func applicationURL(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return cancelled ? nil : applicationURLs[id]
    }
    func perform(_ method: String, payload: String, withReply reply: @escaping (String) -> Void) {
        lock.lock(); let inactive = cancelled; lock.unlock()
        guard !inactive else { reply(jsonString(["error": "查询已取消。"])); return }
        let input = jsonObject(payload)
        if method == "catalog.list" {
            guard extensionInfo.manifest.permissions.catalog?.contains("read") == true else { reply(jsonString(["error": "扩展没有读取插件目录的权限。"])); return }
            lock.lock(); catalogRequestCount += 1; let allowed = catalogRequestCount <= 2; lock.unlock()
            guard allowed else { reply(jsonString(["error": "目录请求次数超出限制。"])); return }
            do { try DistributionSource.validateCatalogRequest(input) } catch { reply(jsonString(["error": error.localizedDescription])); return }
            Task {
                do {
                    let snapshot = try await PluginCatalogService.shared.load()
                    DispatchQueue.main.async {
                        self.lock.lock()
                        guard !self.cancelled else { self.lock.unlock(); reply(jsonString(["error": "查询已取消。"])); return }
                        self.catalogIDs = Set(snapshot.entries.map { $0.0 }); self.lock.unlock()
                        do {
                            let installed = try ExtensionStore().list()
                            let current = try ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0")
                            let tag = snapshot.release.tag_name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? ""
                            let rows: [[String: Any]] = try snapshot.entries.map { handle, entry in
                                let source = "https://github.com/" + snapshot.repository.name + "/tree/" + tag + (entry.sourceDirectory.map { "/" + $0 } ?? "")
                                var value: [String: Any] = ["handle": handle, "manifest": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry.manifest)), "permissions": entry.manifest.permissionSummary, "minimumAppVersion": entry.minimumAppVersion, "compatible": current >= (try ReleaseVersion(entry.minimumAppVersion)), "sourceURL": source, "readmeURL": source + "#readme", "releaseNotes": snapshot.release.body ?? "", "categories": entry.categories ?? []]
                                if let version = installed.first(where: { $0.manifest.id == entry.manifest.id })?.manifest.version { value["installedVersion"] = version }
                                return value
                            }
                            reply(jsonString(["value": ["repository": snapshot.repository.name, "plugins": rows]]))
                        } catch { reply(jsonString(["error": error.localizedDescription])) }
                    }
                } catch { reply(jsonString(["error": error.localizedDescription])) }
            }
            return
        }
        if method == "clipboard.history" {
            guard extensionInfo.manifest.permissions.clipboard?.contains("history") == true else { reply(jsonString(["error": "扩展没有剪贴板历史权限。"])); return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let inactive = self.cancelled; self.lock.unlock()
                guard !inactive else { reply(jsonString(["error": "查询已取消。"])); return }
                do {
                    let entries = try ClipboardHistory.shared.list(self.extensionInfo.manifest.id)
                    self.lock.lock(); self.historyIDs = Set(entries.map(\.id)); self.lock.unlock()
                    reply(jsonString(["value": entries.map(\.metadata)]))
                } catch { reply(jsonString(["error": "无法读取剪贴板历史：" + error.localizedDescription])) }
            }
            return
        }
        if method == "storage.flags" {
            do { reply(jsonString(["value": try ExtensionActionState.shared.flags(extensionInfo.manifest.id)])) }
            catch { reply(jsonString(["error": "无法读取扩展状态"])) }
            return
        }
        if method == "files.search" {
            guard extensionInfo.manifest.permissions.files?.contains("search") == true else { reply(jsonString(["error": "扩展没有文件搜索权限。"])); return }
            guard let text = input["query"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200,
                  let kind = input["kind"] as? String, FileSearch.kinds.contains(kind), Set(input.keys).isSubset(of: ["query", "kind"]) else { reply(jsonString(["error": "请输入 1–200 字的文件名和有效类型。"])); return }
            lock.lock(); fileSearchCount += 1; let allowed = fileSearchCount == 1; lock.unlock()
            guard allowed else { reply(jsonString(["error": "每次查询仅允许一次文件搜索。"])); return }
            DispatchQueue.main.async {
                self.lock.lock(); let inactive = self.cancelled; self.lock.unlock()
                guard !inactive else { reply(jsonString(["error": "查询已取消。"])); return }
                let search = FileSearch(); self.fileSearch = search
                search.start(text: text, filter: kind) { entries, limited, timedOut in
                    self.lock.lock()
                    guard !self.cancelled else { self.lock.unlock(); reply(jsonString(["error": "查询已取消。"])); return }
                    self.fileURLs = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.url) })
                    self.lock.unlock()
                    reply(jsonString(["value": ["files": entries.map(\.metadata), "limited": limited, "timedOut": timedOut]]))
                    self.fileSearch = nil
                }
            }
            return
        }
        if method == "applications.list" {
            guard extensionInfo.manifest.permissions.applications?.contains("read") == true else { reply(jsonString(["error": "扩展没有读取应用列表的权限。"])); return }
            ApplicationCatalog.shared.list { [weak self] entries in
                guard let self else { return }
                self.lock.lock()
                guard !self.cancelled else { self.lock.unlock(); reply(jsonString(["error": "查询已取消。"])); return }
                self.applicationURLs = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.url) })
                self.lock.unlock(); reply(jsonString(["value": entries.map(\.metadata)]))
            }
            return
        }
        if method == "secrets.get" {
            guard let name = input["name"] as? String,
                  extensionInfo.manifest.preferences.contains(where: { $0.name == name && $0.type == "secret" }) else {
                reply(jsonString(["error": "扩展没有访问此密钥的权限。"])); return
            }
            reply(jsonString(["value": Keychain.get(extensionInfo.manifest.id, name) ?? ""]))
            return
        }
        guard method == "network.fetch" else { reply(jsonString(["error": "查询阶段不支持此能力：\(method)"])); return }
        guard let raw = input["url"] as? String, let url = URL(string: raw), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil,
              (extensionInfo.manifest.permissions.network ?? []).contains("https://" + host),
              !host.hasSuffix(".local"), host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else {
            reply(jsonString(["error": "扩展没有访问此网络地址的权限。"])); return
        }
        let verb = input["method"] as? String ?? "GET"
        guard ["GET", "POST"].contains(verb) else { reply(jsonString(["error": "不支持此请求方法。"])); return }
        var request = URLRequest(url: url)
        request.httpMethod = verb
        if let body = input["body"] as? String {
            guard body.utf8.count < 100_000 else { reply(jsonString(["error": "请求内容过大。"])); return }
            request.httpBody = Data(body.utf8)
        }
        for (key, value) in input["headers"] as? [String: String] ?? [:] {
            guard ["content-type", "accept", "authorization"].contains(key.lowercased()) else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        lock.lock()
        guard !cancelled, requests.count < 6 else { lock.unlock(); reply(jsonString(["error": "查询已取消或请求数量超过限制。"])); return }
        let operation = NetworkRequest(request: request, completion: reply)
        requests.append(operation)
        lock.unlock()
    }
}

final class RuntimeClient {
    private var connection: NSXPCConnection?
    private var broker: CapabilityBroker?
    private var generation = UUID()
    var onLog: ((String) -> Void)?

    func cancel() {
        generation = UUID()
        broker?.cancel(); connection?.invalidate()
        broker = nil; connection = nil
    }
    func query(_ info: InstalledExtension, command: String, query: String, rawInput: String, filter: String = "", completion: @escaping (Result<[ResultItem], Error>) -> Void) {
        cancel()
        let token = generation
        let start = Date()
        let connection = NSXPCConnection(serviceName: "local.launcher.ExtensionHost")
        let broker = CapabilityBroker(info)
        self.connection = connection; self.broker = broker
        connection.remoteObjectInterface = NSXPCInterface(with: RuntimeProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: BrokerProtocol.self)
        connection.exportedObject = broker
        connection.resume()
        var delivered = false
        let finish: (Result<[ResultItem], Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == token, !delivered else { return }
                delivered = true
                self.onLog?(jsonString(["extension": info.manifest.id, "command": command, "elapsedMs": Int(Date().timeIntervalSince(start) * 1000), "status": (try? result.get()) == nil ? "error" : "ok"]))
                completion(result)
            }
        }
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in finish(.failure(LauncherError("扩展执行服务已中断，可重试。"))) } as! RuntimeProtocol
        var preferences = Dictionary(uniqueKeysWithValues: info.manifest.preferences.filter { $0.type != "secret" }.map { ($0.name, $0.defaultValue ?? "") })
        preferences.merge(info.preferences) { _, current in current }
        remote.evaluate(info.source, input: jsonString(["command": command, "query": query, "rawInput": rawInput, "filter": filter, "preferences": preferences, "search": ["sensitivity": AppPreferences.shared.values.searchSensitivity ?? "medium"]]), debug: info.development) { output in
            let envelope = jsonObject(output)
            if let error = envelope["error"] as? String { finish(.failure(LauncherError(String(error.prefix(500))))); return }
            guard let result = envelope["result"], let data = try? JSONSerialization.data(withJSONObject: result), data.count < 2_000_000,
                  let batch = try? JSONDecoder().decode(QueryResult.self, from: data) else { finish(.failure(LauncherError("扩展返回的数据格式无效。"))); return }
            var ids = Set<String>()
            let items = batch.items.prefix(50).compactMap { item -> ResultItem? in
                guard !item.title.isEmpty, item.title.count <= 12000, !item.id.isEmpty, ids.insert(item.id).inserted else { return nil }
                var safe = item
                safe.groupHeading = nil
                if let preview = item.preview {
                    safe.preview = ResultPreview(text: preview.text.map { String($0.prefix(20000)) }, historyImageID: info.manifest.permissions.clipboard?.contains("history-images") == true && broker.issuedHistoryID(preview.historyImageID ?? "") ? preview.historyImageID : nil)
                }
                safe.metadata = item.metadata.map { Array($0.prefix(10)).map { ResultMetadata(label: String($0.label.prefix(60)), value: String($0.value.prefix(200))) } }
                safe.group = item.group.map { String($0.prefix(60)) }
                safe.catalogID = item.catalogID.flatMap { broker.issuedCatalogID($0) ? $0 : nil }
                safe.extensionID = info.manifest.id; safe.applicationPath = nil
                let fileURL = item.fileID.flatMap { broker.fileURL($0) }
                safe.fileID = fileURL == nil ? nil : item.fileID
                safe.filePath = fileURL?.path
                let applicationURL = item.applicationId.flatMap { broker.applicationURL($0) }
                safe.applicationId = applicationURL == nil ? nil : item.applicationId
                safe.applicationPath = applicationURL?.path
                safe.actions = item.actions.prefix(10).filter { action in
                    guard !action.title.isEmpty, action.title.count <= 120, action.id.count <= 80 else { return false }
                    switch action.type {
                    case "file.open", "file.reveal": return info.manifest.permissions.files?.contains("open") == true && fileURL != nil && action.text == safe.fileID
                    case "view.detail": return item.preview?.text != nil || item.detail != nil
                    case "catalog.install": return info.manifest.permissions.catalog?.contains("install") == true && safe.catalogID != nil && action.text == safe.catalogID
                    case "catalog.refresh": return info.manifest.permissions.catalog?.contains("read") == true
                    case "url.open": return info.manifest.permissions.browser?.contains("open") == true && safeBrowserURL(action.text) != nil
                    case "clipboard.copy": return info.manifest.permissions.clipboard?.contains("write") == true && (action.text?.count ?? 0) <= 20000
                    case "clipboard.history.copy", "clipboard.history.paste": return info.manifest.permissions.clipboard?.contains("history") == true && info.manifest.permissions.clipboard?.contains("write") == true && (action.type != "clipboard.history.paste" || info.manifest.permissions.clipboard?.contains("paste") == true) && broker.issuedHistoryID(action.text ?? "")
                    case "clipboard.history.remove": return info.manifest.permissions.clipboard?.contains("history") == true && broker.issuedHistoryID(action.text ?? "")
                    case "clipboard.history.clear": return info.manifest.permissions.clipboard?.contains("history") == true
                    case "application.open", "application.reveal", "application.info", "application.contents": return info.manifest.permissions.applications?.contains("open") == true && applicationURL != nil && action.text == safe.applicationId
                    case "storage.toggle": return action.text.map(ExtensionActionState.validKey) == true
                    default: return false
                    }
                }.map { action in
                    var action = action
                    action.icon = action.icon.map { String($0.prefix(80)) }
                    action.section = action.section.map { String($0.prefix(40)) }
                    if let shortcut = action.shortcut, !ActionShortcut.isValid(shortcut) { action.shortcut = nil }
                    return action
                }
                return safe
            }
            finish(.success(items))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { finish(.failure(LauncherError("扩展响应超时，请重试。"))) }
    }
}
