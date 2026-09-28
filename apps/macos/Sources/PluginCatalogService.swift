import Foundation

/// Transport, integrity and opaque installation targets. Search and presentation belong to plugins.
actor PluginCatalogService {
    static let shared = PluginCatalogService()
    struct Snapshot {
        let repository: PublicRepository
        let release: PublicRelease
        let entries: [(String, PluginIndex.Entry)]
        let loaded: Date
    }
    private var snapshots: [String: Snapshot] = [:]
    private var pending: Task<Snapshot, Error>?
    private var cached: CatalogCache?
    private var forceRefresh = false
    private var lastAttempt = Date.distantPast
    private let cacheURL: URL
    private let fetch: @Sendable (PublicRepository) async throws -> CatalogCache
    init(cacheURL: URL? = nil, fetch: @escaping @Sendable (PublicRepository) async throws -> CatalogCache = { try await PluginCatalogService.fetchRemote($0) }) {
        self.fetch = fetch
        let base = ProcessInfo.processInfo.environment["LAUNCHER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Vectracast")
        self.cacheURL = cacheURL ?? base.appendingPathComponent("catalog/official-v1.json")
    }
    func invalidate() { forceRefresh = true }
    private func snapshot(_ cache: CatalogCache, repository: PublicRepository) -> Snapshot {
        if let existing = snapshots.values.first(where: { $0.release.tag_name == cache.release.tag_name && Date().timeIntervalSince($0.loaded) < 300 }) { return existing }
        let result = Snapshot(repository: repository, release: cache.release, entries: cache.index.plugins.map { (UUID().uuidString, $0) }, loaded: Date())
        // Preserve recently issued handles when a background refresh completes.
        snapshots = snapshots.filter { Date().timeIntervalSince($0.value.loaded) < 600 }
        if snapshots.count >= 8, let oldest = snapshots.min(by: { $0.value.loaded < $1.value.loaded })?.key { snapshots[oldest] = nil }
        snapshots[UUID().uuidString] = result
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
                return self.snapshot(value, repository: repository)
            } catch { self.pending = nil; throw error }
        }
        pending = task
        return task
    }
    private static func fetchRemote(_ repository: PublicRepository) async throws -> CatalogCache {
        let release = try await DistributionSource.latest(repository)
        let url = try release.asset("index.json", repository: repository, limit: 2_000_000)
        let data = try await PublicDownload.data(from: url, limit: 2_000_000)
        return CatalogCache(repository: repository.name, fetchedAt: Date(), release: release, index: try JSONDecoder().decode(PluginIndex.self, from: data))
    }
    func load() async throws -> Snapshot {
        let repository = try PublicRepository(DistributionSource.pluginRepository)
        if cached == nil { cached = CatalogCache.read(cacheURL, repository: repository) }
        if !forceRefresh, let cached, (try? cached.validate(for: repository)) != nil {
            let value = snapshot(cached, repository: repository)
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
    func download(_ handle: String) async throws -> (Data, ExtensionPackage, String) {
        guard let snapshot = snapshots.values.first(where: { $0.entries.contains { $0.0 == handle } }),
              let entry = snapshot.entries.first(where: { $0.0 == handle })?.1,
              Date().timeIntervalSince(snapshot.loaded) < 600 else { throw LauncherError("目录已过期，请刷新后重试。") }
        let current = try ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0")
        guard current >= (try ReleaseVersion(entry.minimumAppVersion)) else { throw LauncherError("请先更新 Vectracast。") }
        let url = try snapshot.release.asset(entry.asset, repository: snapshot.repository, limit: 3_000_000)
        let data = try await PublicDownload.data(from: url, limit: 3_000_000)
        return (data, try entry.verify(data), snapshot.repository.name)
    }
}

func safeBrowserURL(_ text: String?) -> URL? {
    guard let text, text.count <= 2048, let url = URL(string: text), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil, url.port == nil else { return nil }
    return url
}
