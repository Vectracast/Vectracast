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
    private var pending: [String: Task<Snapshot, Error>] = [:]
    func invalidate() { snapshots.removeAll() }
    func load() async throws -> Snapshot {
        let repository = try PublicRepository(DistributionSource.pluginRepository)
        if let snapshot = snapshots[repository.name], Date().timeIntervalSince(snapshot.loaded) < 300 { return snapshot }
        if let task = pending[repository.name] { return try await task.value }
        let task = Task<Snapshot, Error> {
            let release = try await DistributionSource.latest(repository)
            let url = try release.asset("index.json", repository: repository, limit: 2_000_000)
            let data = try await PublicDownload.data(from: url, limit: 2_000_000)
            let index = try JSONDecoder().decode(PluginIndex.self, from: data); try index.validate()
            for entry in index.plugins { _ = try release.asset(entry.asset, repository: repository, limit: 3_000_000) }
            return Snapshot(repository: repository, release: release, entries: index.plugins.map { (UUID().uuidString, $0) }, loaded: Date())
        }
        pending[repository.name] = task
        do {
            let value = try await task.value; pending[repository.name] = nil
            if snapshots.count >= 4, let key = snapshots.min(by: { $0.value.loaded < $1.value.loaded })?.key { snapshots[key] = nil }
            snapshots[repository.name] = value; return value
        } catch { pending[repository.name] = nil; throw error }
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
