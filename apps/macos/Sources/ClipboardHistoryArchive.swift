import Foundation
import CryptoKit

/// Bounded, per-extension storage for the clipboard history capability. No system clipboard access.
final class ClipboardHistoryArchive {
    struct Entry: Codable {
        let id: String
        let text: String
        let source: String
        let timestamp: Double
        var kind: String? = nil
        var imageFile: String? = nil
        var width: Int? = nil
        var height: Int? = nil
        var byteCount: Int? = nil
        var sourceBundleID: String? = nil
        var contentType: String { kind ?? "text" }
        var metadata: [String: Any] {
            var result: [String: Any] = ["id": id, "text": text, "source": source, "timestamp": timestamp, "kind": contentType]
            result["width"] = width; result["height"] = height; result["byteCount"] = byteCount
            result["sourceBundleID"] = sourceBundleID
            return result
        }
    }
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    let url: URL
    private(set) var entries: [Entry]
    init(url: URL, now: Date = Date()) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw NSError(domain: "ClipboardHistory", code: 1) }
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } else { entries = [] }
        let oldCount = entries.count
        prune(now)
        if oldCount != entries.count { try save() }
    }
    var assetsURL: URL { url.deletingPathExtension().appendingPathExtension("assets") }
    func imageURL(for entry: Entry) -> URL? {
        guard entry.contentType == "image", let name = entry.imageFile,
              name.range(of: "^[a-f0-9]{64}\\.png$", options: .regularExpression) != nil else { return nil }
        return assetsURL.appendingPathComponent(name)
    }
    private func prune(_ now: Date) {
        let cutoff = now.timeIntervalSince1970 * 1000 - Self.lifetime * 1000
        entries = entries.filter { $0.timestamp >= cutoff && (($0.contentType == "image" && imageURL(for: $0).map { FileManager.default.fileExists(atPath: $0.path) } == true) || (!$0.text.isEmpty && $0.text.utf8.count <= 10_000)) }
            .sorted { $0.timestamp > $1.timestamp }
        var bytes = 0, imageBytes = 0
        entries = Array(entries.prefix(200).prefix { entry in
            bytes += (try? JSONEncoder().encode(entry).count) ?? 2_000_000
            imageBytes += entry.byteCount ?? 0
            return bytes <= 500_000 && imageBytes <= 100_000_000
        })
    }
    func append(text: String, source: String, sourceBundleID: String? = nil, now: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 10_000 else { return }
        entries.removeAll { $0.contentType != "image" && $0.text == text }
        entries.insert(Entry(id: UUID().uuidString, text: text, source: String(source.prefix(100)), timestamp: now.timeIntervalSince1970 * 1000, sourceBundleID: sourceBundleID), at: 0)
        prune(now); try save()
    }
    func appendImage(png: Data, width: Int, height: Int, source: String, sourceBundleID: String? = nil, now: Date = Date()) throws {
        guard png.count <= 10_000_000, width > 0, height > 0 else { return }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let name = hash + ".png"
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let asset = assetsURL.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: asset.path) {
            guard FileManager.default.createFile(atPath: asset.path, contents: png, attributes: [.posixPermissions: 0o600]) else { throw NSError(domain: "ClipboardHistory", code: 3) }
        }
        entries.removeAll { $0.imageFile == name }
        entries.insert(Entry(id: UUID().uuidString, text: "", source: String(source.prefix(100)), timestamp: now.timeIntervalSince1970 * 1000, kind: "image", imageFile: name, width: width, height: height, byteCount: png.count, sourceBundleID: sourceBundleID), at: 0)
        prune(now); try save()
    }
    func remove(_ id: String) throws { entries.removeAll { $0.id == id }; try save() }
    func clear() throws { entries = []; try save() }
    private func save() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Stage with restrictive permissions before atomic replacement, including the first write.
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(entries), attributes: [.posixPermissions: 0o600]) else { throw NSError(domain: "ClipboardHistory", code: 2) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
        // Only remove assets after the metadata transaction succeeds.
        let referenced = Set(entries.compactMap(\.imageFile))
        for asset in (try? FileManager.default.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil)) ?? [] where !referenced.contains(asset.lastPathComponent) {
            try FileManager.default.removeItem(at: asset)
        }
    }
}

/// Clipboard changes observed before enabling/re-enabling are deliberately not collected.
struct ClipboardCaptureGate {
    private var count: Int?
    private var active = Set<String>()
    mutating func recipients(changeCount: Int, enabled: Set<String>) -> Set<String> {
        defer { count = changeCount; active = enabled }
        guard let count, count != changeCount else { return [] }
        return active.intersection(enabled)
    }
    static func accepts(types: [String], sourceID: String) -> Bool {
        let excludedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        let excludedApps = ["com.agilebits.", "com.1password.", "com.bitwarden.", "com.lastpass.", "com.dashlane."]
        return sourceID != "com.apple.Passwords" && excludedTypes.isDisjoint(with: types) && !excludedApps.contains(where: { sourceID.hasPrefix($0) })
    }
}
