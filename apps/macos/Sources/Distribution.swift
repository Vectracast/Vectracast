import Foundation
import CryptoKit

struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]
    init(_ value: String) throws {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard text.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil else { throw LauncherError("发行版本必须为 x.y.z。") }
        let values = text.split(separator: ".").compactMap { Int($0) }
        guard values.count == 3 else { throw LauncherError("版本号超出范围。") }
        components = values
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
    var description: String { components.map(String.init).joined(separator: ".") }
}

struct PublicRepository: Equatable {
    let name: String
    init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://github.com/") { value = String(value.dropFirst(19)) }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        if value.hasSuffix("/") { value.removeLast() }
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$", options: .regularExpression) != nil else { throw LauncherError("请输入 GitHub 公开仓库：用户名/仓库名。") }
        name = value
    }
    var latestURL: URL { URL(string: "https://api.github.com/repos/\(name)/releases/latest")! }
    func assetURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/\(name)/releases/download/"), !url.path.contains("/../") else { throw LauncherError("下载地址不属于当前仓库的公开 Release。") }
        return url
    }
}

struct PublicRelease: Codable {
    struct Asset: Codable { let name: String; let browser_download_url: String; let size: Int }
    let tag_name: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    func asset(_ name: String, repository: PublicRepository, limit: Int) throws -> URL {
        let matches = assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first, asset.size > 0, asset.size <= limit else { throw LauncherError("发行版缺少有效附件：\(name)") }
        return try repository.assetURL(asset.browser_download_url)
    }
}

struct PluginIndex: Codable {
    struct Entry: Codable {
        let manifest: ExtensionManifest
        let asset: String
        let sha256: String
        let minimumAppVersion: String
        var sourceDirectory: String? = nil
        var categories: [String]? = nil
        var searchText: String { ([manifest.name, manifest.id, manifest.description] + manifest.commands.flatMap { [$0.id, $0.title] + $0.keywords }).joined(separator: " ") }
        func validate() throws {
            try manifest.validate(); _ = try ReleaseVersion(minimumAppVersion)
            guard sourceDirectory == nil || sourceDirectory!.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
                  (categories?.count ?? 0) <= 8, (categories ?? []).allSatisfy({ ["productivity", "developer", "language"].contains($0) }) else { throw LauncherError("插件目录元数据无效。") }
            guard asset == "\(manifest.id)-\(manifest.version).launcher-extension", sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw LauncherError("插件索引中的包名或校验值无效。") }
        }
        func verify(_ data: Data) throws -> ExtensionPackage {
            guard data.count < 3_000_000, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw LauncherError("下载包的 SHA-256 校验失败。") }
            let package = try JSONDecoder().decode(ExtensionPackage.self, from: data)
            try package.validate()
            let a = try JSONSerialization.jsonObject(with: JSONEncoder().encode(package.manifest)) as? NSDictionary
            let b = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? NSDictionary
            guard a == b else { throw LauncherError("安装包与插件索引的声明不一致。") }
            return package
        }
    }
    let schemaVersion: Int
    let plugins: [Entry]
    func validate() throws {
        guard schemaVersion == 1, plugins.count <= 1000, Set(plugins.map { $0.manifest.id }).count == plugins.count else { throw LauncherError("插件索引格式无效或包含重复 ID。") }
        for entry in plugins { try entry.validate() }
    }
}

// Public GitHub endpoints only. The session neither sends cookies nor accepts arbitrary redirects.
final class PublicDownload: NSObject, URLSessionDataDelegate {
    private var data = Data()
    private let limit: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private init(limit: Int) { self.limit = limit }
    static func data(from url: URL, limit: Int) async throws -> Data {
        let download = PublicDownload(limit: limit)
        return try await download.start(url)
    }
    private func start(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil); self.session = session
            var request = URLRequest(url: url); request.setValue("Vectracast", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            task = session.dataTask(with: request); task?.resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil,
              host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com") else {
            failure = LauncherError("已拒绝非 GitHub 下载重定向。"); completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = LauncherError(status == 404 ? "仓库尚未发布正式 Release，或仓库不是公开的。" : status == 403 || status == 429 ? "GitHub 请求达到频率限制，请稍后重试。" : "下载失败（HTTP \(status)）或文件超过大小限制。")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= limit else { failure = LauncherError("下载超过大小限制。"); dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: data) }
        continuation = nil; self.task = nil; self.session = nil; session.finishTasksAndInvalidate()
    }
}

enum DistributionSource {
    static let appRepository = "Vectracast/Vectracast"
    static let pluginRepository = "Vectracast/Vectracast-Plugins"
    static func validateCatalogRequest(_ input: [String: Any]) throws {
        guard input["repository"] == nil else { throw LauncherError("插件商店固定使用 Vectracast/Vectracast-Plugins，不支持更换仓库。") }
    }
    static func repository(_ key: String) -> String {
        if key == "appRepository" { return appRepository }
        if key == "pluginRepository" { return pluginRepository }
        if let value = UserDefaults.standard.string(forKey: "distribution." + key) { return value }
        guard let url = Bundle.main.url(forResource: "distribution", withExtension: "json"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return values[key] ?? ""
    }
    static func latest(_ repository: PublicRepository) async throws -> PublicRelease {
        let data = try await PublicDownload.data(from: repository.latestURL, limit: 2_000_000)
        let release = try JSONDecoder().decode(PublicRelease.self, from: data)
        guard !release.draft, !release.prerelease else { throw LauncherError("没有可用的正式发行版。") }
        return release
    }
}


/// Only validated catalog metadata is persisted; installation handles remain session-local.
struct CatalogCache: Codable {
    let repository: String
    let fetchedAt: Date
    let release: PublicRelease
    let index: PluginIndex
    func validate(for repository: PublicRepository, now: Date = Date()) throws {
        let age = now.timeIntervalSince(fetchedAt)
        guard self.repository == repository.name, age >= -60, age < 7 * 86400,
              !release.draft, !release.prerelease else { throw LauncherError("目录缓存已过期。") }
        try index.validate()
        _ = try release.asset("index.json", repository: repository, limit: 2_000_000)
        for entry in index.plugins { _ = try release.asset(entry.asset, repository: repository, limit: 3_000_000) }
    }
    static func read(_ url: URL, repository: PublicRepository) -> Self? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
              (try? value.validate(for: repository)) != nil else { return nil }
        return value
    }
    func write(_ url: URL) throws {
        try validate(for: PublicRepository(repository))
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4_000_000 else { throw LauncherError("目录缓存过大。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
