import AppKit
import CryptoKit

/// OS capability only: returns application metadata, without query matching or ranking.
final class ApplicationCatalog {
    struct Entry {
        let id: String; let name: String; let bundleIdentifier: String
        let searchTerms: [String]; let url: URL; let urlSchemes: [String]; let documentTypes: [String]
        var metadata: [String: Any] { ["id": id, "name": name, "bundleIdentifier": bundleIdentifier, "searchTerms": searchTerms, "urlSchemes": urlSchemes, "documentTypes": documentTypes] }
    }
    static let shared = ApplicationCatalog()
    private let queue = DispatchQueue(label: "launcher.application-catalog", qos: .utility)
    private var entries: [Entry] = []
    private var refreshedAt = Date.distantPast
    private let roots: [URL]
    private let registeredApplications: () -> [URL]
    init(roots: [URL]? = nil, registeredApplications: (() -> [URL])? = nil) {
        self.roots = roots ?? ["/Applications", "/System/Applications", "/System/Library/CoreServices/Finder.app", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        self.registeredApplications = registeredApplications ?? {
            // Launch Services knows relocated system browsers and user-registered installations.
            ["http", "https"].flatMap { scheme in NSWorkspace.shared.urlsForApplications(toOpen: URL(string: scheme + "://example.invalid")!) }
        }
    }
    func list(_ completion: @escaping ([Entry]) -> Void) {
        queue.async { [self] in
            if Date().timeIntervalSince(refreshedAt) >= 60 {
                var collected: [Entry] = []; var seen = Set<String>(); var seenBundleIDs = Set<String>()
                func add(_ candidate: URL) {
                    let url = candidate.resolvingSymlinksInPath().standardizedFileURL
                    guard collected.count < 2000, url.pathExtension == "app", seen.insert(url.path).inserted, let bundle = Bundle(url: url) else { return }
                    if let id = bundle.bundleIdentifier, !id.isEmpty, !seenBundleIDs.insert(id).inserted { return }
                    let names = ApplicationName.resolve(bundle)
                    let id = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
                    let urlTypes = (bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]) ?? []
                    let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() }
                    let documents = (bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
                    let types = documents.flatMap { (($0["LSItemContentTypes"] as? [String]) ?? []) + (($0["CFBundleTypeExtensions"] as? [String]) ?? []) }.map { $0.lowercased() }
                    collected.append(Entry(id: id, name: names.name, bundleIdentifier: bundle.bundleIdentifier ?? "", searchTerms: names.searchTerms, url: url,
                                           urlSchemes: Array(Set(schemes)).sorted(), documentTypes: Array(Set(types)).sorted()))
                }
                for url in roots {
                    if url.pathExtension == "app" { add(url); continue }
                    // Safari's /Applications link is hidden. Resolve top-level app links before
                    // the ordinary walk, which should still skip hidden folders and helper bundles.
                    for candidate in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] where candidate.pathExtension == "app" {
                        if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { add(candidate) }
                    }
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        for case let app as URL in enumerator where app.pathExtension == "app" { add(app) }
                    }
                }
                for url in registeredApplications() { add(url) }
                entries = collected; refreshedAt = Date()
            }
            completion(entries)
        }
    }
}
