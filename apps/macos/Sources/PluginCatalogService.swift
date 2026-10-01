import Foundation
import CryptoKit

/// Transport, integrity and opaque installation targets. Search and presentation belong to plugins.
actor PluginCatalogService {
    static let shared = PluginCatalogService()
    typealias DownloadProgress = @Sendable (Int64, Int64) -> Void
    typealias PackageFetcher = @Sendable (URL, @escaping DownloadProgress) async throws -> Data
    struct Snapshot {
        let repository: PublicRepository
        let entries: [(String, PluginIndex.Entry)]
        let loaded: Date
        func update(for info: InstalledExtension) -> (String, PluginIndex.Entry)? {
            guard !info.development, let installed = try? ReleaseVersion(info.manifest.version) else { return nil }
            return entries.first { _, entry in
                entry.manifest.id == info.manifest.id && (try? ReleaseVersion(entry.manifest.version)).map { $0 > installed } == true
            }
        }
    }
    private var snapshots: [String: Snapshot] = [:]
    private var pending: Task<Snapshot, Error>?
    private var cached: CatalogCache?
    private var forceRefresh = false
    private var lastAttempt = Date.distantPast
    private let cacheURL: URL
    private let fetch: @Sendable (PublicRepository) async throws -> CatalogCache
    private let fetchPackage: PackageFetcher
    private let fetchUpdates: @Sendable (Data) async throws -> Data
    init(cacheURL: URL? = nil, fetchUpdates: @escaping @Sendable (Data) async throws -> Data = { try await PublicDownload.post(to: DistributionSource.apiBaseURL.appendingPathComponent("v2/plugins/updates"), body: $0, limit: 2_000_000) }, fetchPackage: @escaping PackageFetcher = { try await PublicDownload.data(from: $0, limit: 3_000_000, progress: $1) }, fetch: @escaping @Sendable (PublicRepository) async throws -> CatalogCache = { try await PluginCatalogService.fetchRemote($0) }) {
        self.fetch = fetch; self.fetchPackage = fetchPackage; self.fetchUpdates = fetchUpdates
        let base = ProcessInfo.processInfo.environment["LAUNCHER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Vectracast")
        self.cacheURL = cacheURL ?? base.appendingPathComponent("catalog/official-v2.json")
    }
    func invalidate() { forceRefresh = true }
    private func snapshot(_ cache: CatalogCache, repository: PublicRepository) throws -> Snapshot {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = SHA256.hash(data: try encoder.encode(cache.index)).map { String(format: "%02x", $0) }.joined()
        if let existing = snapshots[identity], Date().timeIntervalSince(existing.loaded) < 300 { return existing }
        let result = Snapshot(repository: repository, entries: cache.index.plugins.map { (UUID().uuidString, $0) }, loaded: Date())
        // Preserve recently issued handles when a background refresh completes.
        snapshots = snapshots.filter { Date().timeIntervalSince($0.value.loaded) < 600 }
        if snapshots.count >= 8, let oldest = snapshots.min(by: { $0.value.loaded < $1.value.loaded })?.key { snapshots[oldest] = nil }
        snapshots[identity] = result
        return result
    }
    private func refresh(_ repository: PublicRepository) -> Task<Snapshot, Error> {
        if let pending { return pending }
        lastAttempt = Date()
        let task = Task<Snapshot, Error> {
            do {
                let value = try await self.fetch(repository)
                try value.validate(for: repository)
                try? value.write(self.cacheURL)
                self.cached = value; self.pending = nil
                return try self.snapshot(value, repository: repository)
            } catch { self.pending = nil; throw error }
        }
        pending = task
        return task
    }
    private static func fetchRemote(_ repository: PublicRepository) async throws -> CatalogCache {
        let data = try await PublicDownload.data(from: DistributionSource.apiBaseURL.appendingPathComponent("v2/plugins"), limit: 2_000_000)
        struct Response: Decodable { let plugins: [PluginIndex.Entry] }
        let entries = try JSONDecoder().decode(Response.self, from: data).plugins
        return CatalogCache(repository: repository.name, fetchedAt: Date(), index: PluginIndex(schemaVersion: 1, plugins: entries))
    }
    /// A fresh server decision for the exact installed versions; never persists a partial catalog.
    func updates(for installed: [InstalledExtension], appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0") async throws -> Snapshot {
        let current = try ReleaseVersion(appVersion)
        let versions = installed.filter { !$0.development }
        guard versions.count <= 1000, Set(versions.map { $0.manifest.id }).count == versions.count else { throw LauncherError("已安装插件列表无效。") }
        let repository = try PublicRepository(DistributionSource.pluginRepository)
        if versions.isEmpty { return Snapshot(repository: repository, entries: [], loaded: Date()) }
        let body = try JSONSerialization.data(withJSONObject: ["appVersion": appVersion, "plugins": versions.map { ["id": $0.manifest.id, "version": $0.manifest.version] }])
        struct Response: Decodable { let updates: [PluginIndex.Entry] }
        let entries = try JSONDecoder().decode(Response.self, from: await fetchUpdates(body)).updates
        let cache = CatalogCache(repository: repository.name, fetchedAt: Date(), index: PluginIndex(schemaVersion: 1, plugins: entries))
        try cache.validate(for: repository)
        for entry in entries {
            guard let old = versions.first(where: { $0.manifest.id == entry.manifest.id }),
                  try ReleaseVersion(entry.manifest.version) > ReleaseVersion(old.manifest.version),
                  try ReleaseVersion(entry.minimumAppVersion) <= current else { throw LauncherError("服务端返回了不适用的插件更新。") }
        }
        return try snapshot(cache, repository: repository)
    }
    struct Version: Decodable {
        let version: String
        let sha256: String
        let minimumAppVersion: String?
    }
    func versions(for handle: String) async throws -> [Version] {
        let entry = try target(handle).1
        let url = DistributionSource.apiBaseURL.appendingPathComponent("v2/plugins/\(entry.manifest.id)/versions")
        let data = try await PublicDownload.data(from: url, limit: 2_000_000)
        struct Response: Decodable { let versions: [Version] }
        let versions = try JSONDecoder().decode(Response.self, from: data).versions
        guard versions.count <= 1000, Set(versions.map { $0.version }).count == versions.count else { throw LauncherError("插件历史版本无效。") }
        for version in versions {
            _ = try ReleaseVersion(version.version)
            if let required = version.minimumAppVersion { _ = try ReleaseVersion(required) }
            guard version.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw LauncherError("插件历史版本摘要无效。") }
        }
        return versions
    }
    func load() async throws -> Snapshot {
        let repository = try PublicRepository(DistributionSource.pluginRepository)
        if cached == nil { cached = CatalogCache.read(cacheURL, repository: repository) }
        if !forceRefresh, let cached, (try? cached.validate(for: repository)) != nil {
            let value = try snapshot(cached, repository: repository)
            if Date().timeIntervalSince(cached.fetchedAt) >= 300, Date().timeIntervalSince(lastAttempt) >= 60, pending == nil {
                let task = refresh(repository)
                Task { if (try? await task.value) != nil {
                    await MainActor.run { NotificationCenter.default.post(name: .init("VectracastCatalogUpdated"), object: nil) }
                } }
            }
            return value
        }
        forceRefresh = false
        return try await refresh(repository).value
    }
    private func target(_ handle: String) throws -> (Snapshot, PluginIndex.Entry) {
        guard let snapshot = snapshots.values.first(where: { $0.entries.contains { $0.0 == handle } }),
              let entry = snapshot.entries.first(where: { $0.0 == handle })?.1,
              Date().timeIntervalSince(snapshot.loaded) < 600 else { throw LauncherError("目录已过期，请刷新后重试。") }
        return (snapshot, entry)
    }
    func download(_ handle: String, progress: @escaping DownloadProgress = { _, _ in }) async throws -> (Data, ExtensionPackage, String) {
        let (snapshot, entry) = try target(handle)
        let current = try ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0")
        guard current >= (try ReleaseVersion(entry.minimumAppVersion)) else { throw LauncherError("请先更新 Vectracast。") }
        let url = try entry.registryDownloadURL()
        let data = try await fetchPackage(url, progress)
        return (data, try entry.verify(data), snapshot.repository.name)
    }
}

func safeBrowserURL(_ text: String?) -> URL? {
    guard let text, text.count <= 2048, let url = URL(string: text), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil, url.port == nil else { return nil }
    return url
}
