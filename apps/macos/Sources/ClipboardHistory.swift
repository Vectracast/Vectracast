import AppKit
import ImageIO

/// The host supplies permission-gated collection/storage; plugins own search, presentation and actions.
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    private var store: ExtensionStore?
    private var timer: Timer?
    private var gate = ClipboardCaptureGate()
    private var ticks = 0
    private let imageLoader = HistoryImageLoader()
    private let encodingQueue = DispatchQueue(label: "launcher.clipboard.encoding", qos: .utility)
    private var epochs: [String: UUID] = [:]
    private var enabledPreviously = Set<String>()
    private var registryRevision = ""
    private var registry: [InstalledExtension] = []
    private struct Snapshot { let archive: ClipboardHistoryArchive; let modified: Date?; let loaded: Date }
    private var snapshots: [String: Snapshot] = [:]
    private var errors: [String: String] = [:]
    static func archiveURL(root: URL, extensionID: String) -> URL {
        root.appendingPathComponent("ClipboardHistory", isDirectory: true).appendingPathComponent(extensionID + ".json")
    }
    func start(store: ExtensionStore) {
        self.store = store
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func extensions() -> [InstalledExtension] {
        guard let store, let external = try? store.run("PRAGMA data_version"), let local = try? store.run("SELECT total_changes() AS revision") else { return [] }
        let revision = external.description + local.description
        if revision != registryRevision { registryRevision = revision; registry = store.list() }
        return registry
    }
    private func authorized(_ id: String) throws -> ExtensionStore {
        if store == nil { store = try ExtensionStore() }
        guard let store, extensions().contains(where: { $0.enabled && $0.manifest.id == id && $0.manifest.permissions.clipboard?.contains("history") == true }) else {
            throw LauncherError("扩展已停用或没有剪贴板历史权限。")
        }
        return store
    }
    private func archive(_ id: String) throws -> ClipboardHistoryArchive {
        let store = try authorized(id)
        let url = Self.archiveURL(root: store.root, extensionID: id)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let snapshot = snapshots[id], snapshot.modified == modified, Date().timeIntervalSince(snapshot.loaded) < 60 { return snapshot.archive }
        let archive = try ClipboardHistoryArchive(url: url)
        snapshots[id] = Snapshot(archive: archive, modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, loaded: Date())
        return archive
    }
    func list(_ id: String) throws -> [ClipboardHistoryArchive.Entry] {
        let entries = try archive(id).entries
        if let error = errors[id] { throw LauncherError(error) }
        let imagesAllowed = extensions().first { $0.manifest.id == id }?.manifest.permissions.clipboard?.contains("history-images") == true
        let cutoff = (Date().timeIntervalSince1970 - ClipboardHistoryArchive.lifetime) * 1000
        return entries.filter { $0.timestamp >= cutoff && ($0.contentType != "image" || imagesAllowed) }
    }
    func loadImage(_ id: String, entryID: String, maxPixels: Int = 1000, completion: @escaping (NSImage?) -> Void) {
        guard let entry = try? list(id).first(where: { $0.id == entryID }),
              let archive = try? archive(id), let url = archive.imageURL(for: entry) else { completion(nil); return }
        imageLoader.load(url: url, maxPixels: maxPixels) { [weak self] image in
            // Revalidate after background work: deletion, expiry and permission revocation win.
            guard let self, FileManager.default.fileExists(atPath: url.path), (try? self.list(id).contains(where: { $0.id == entryID })) == true else { completion(nil); return }
            completion(image)
        }
    }
    func copy(_ id: String, entryID: String) throws {
        _ = try authorized(id)
        guard extensions().first(where: { $0.manifest.id == id })?.manifest.permissions.clipboard?.contains("write") == true,
              let entry = try list(id).first(where: { $0.id == entryID }) else { throw LauncherError("记录已过期或没有复制权限。") }
        let board = NSPasteboard.general
        if entry.contentType == "image" {
            guard let url = try archive(id).imageURL(for: entry) else { throw LauncherError("图片已失效。") }
            let data = try Data(contentsOf: url)
            board.clearContents(); board.setData(data, forType: .png)
        } else { board.clearContents(); board.setString(entry.text, forType: .string) }
    }
    func remove(_ id: String, entry: String) throws { epochs[id] = UUID(); try archive(id).remove(entry); snapshots[id] = nil }
    func clear(_ id: String) throws { epochs[id] = UUID(); try archive(id).clear(); snapshots[id] = nil; errors[id] = nil }
    private func tick() {
        guard let store else { return }
        let enabled = Set(extensions().filter { $0.enabled && $0.manifest.permissions.clipboard?.contains("history") == true }.map { $0.manifest.id })
        for id in enabled.symmetricDifference(enabledPreviously) { epochs[id] = UUID(); snapshots[id] = nil }
        enabledPreviously = enabled
        let pasteboard = NSPasteboard.general
        let recipients = gate.recipients(changeCount: pasteboard.changeCount, enabled: enabled)
        ticks += 1
        // Purge expired entries even while the history command is not open.
        if ticks % 120 == 0 {
            for info in extensions() where info.manifest.permissions.clipboard?.contains("history") == true {
                _ = try? ClipboardHistoryArchive(url: Self.archiveURL(root: store.root, extensionID: info.manifest.id))
            }
        }
        guard !recipients.isEmpty else { return }
        let application = NSWorkspace.shared.frontmostApplication
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard ClipboardCaptureGate.accepts(types: types, sourceID: application?.bundleIdentifier ?? "") else { return }
        let imageRecipients = Set(extensions().filter { recipients.contains($0.manifest.id) && $0.manifest.permissions.clipboard?.contains("history-images") == true }.map { $0.manifest.id })
        let rawImage = !imageRecipients.isEmpty ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)) : nil
        let text = pasteboard.string(forType: .string)
        let sourceName = application?.localizedName ?? "未知应用", sourceID = application?.bundleIdentifier
        let capturedEpochs = epochs
        let capturedAt = Date()
        // Pasteboard access stays on main; expensive bitmap conversion happens on a serial worker.
        // Text captures use the same queue to preserve clipboard order.
        encodingQueue.async { [weak self] in
            var imageData: (Data, Int, Int)?
            if let rawImage, rawImage.count <= 20_000_000, let source = CGImageSourceCreateWithData(rawImage as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
               width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 24_000_000,
               let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]), png.count <= 10_000_000 { imageData = (png, width, height) }
            let encodedImage = imageData
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for id in recipients where self.epochs[id] == capturedEpochs[id] {
                    guard let info = self.extensions().first(where: { $0.manifest.id == id && $0.enabled }), info.manifest.permissions.clipboard?.contains("history") == true else { continue }
                    do {
                        let archive = try self.archive(id)
                        if let (png, width, height) = encodedImage, imageRecipients.contains(id), info.manifest.permissions.clipboard?.contains("history-images") == true {
                            try archive.appendImage(png: png, width: width, height: height, source: sourceName, sourceBundleID: sourceID, now: capturedAt)
                        } else if let text { try archive.append(text: text, source: sourceName, sourceBundleID: sourceID, now: capturedAt) }
                        self.snapshots[id] = nil
                        self.errors[id] = nil
                    }
                    catch { self.errors[id] = "剪贴板历史保存失败，请检查本地数据目录。" }
                }
            }
        }
    }
}
