import Foundation

/// A bounded Spotlight query. Only filename metadata is exposed; plugins never read file contents.
final class FileSearch {
    struct Entry {
        let id: String
        let url: URL
        let name: String
        let kind: String
        let modified: Double
        let size: Int
        var metadata: [String: Any] {
            ["id": id, "name": name, "path": url.path, "kind": kind, "modified": modified, "size": size]
        }
    }
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var timeout: DispatchWorkItem?
    private var completion: (([Entry], Bool, Bool) -> Void)?
    private var text = ""
    private var filter = ""
    static let kinds = ["all", "folder", "document", "image", "audio", "video", "other"]
    static let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL

    // Recheck at action time too: no hidden files, Library, application bundles or symlink escapes.
    static func allowedURL(_ url: URL, root: URL = home) -> URL? {
        let path = url.standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base + "/"), url.resolvingSymlinksInPath().standardizedFileURL.path == path else { return nil }
        let components = String(path.dropFirst(base.count + 1)).split(separator: "/")
        guard components.first != "Library", !components.contains(where: { $0.hasPrefix(".") || $0.lowercased().hasSuffix(".app") }),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey]),
              values.isSymbolicLink != true, values.isHidden != true, values.isPackage != true,
              values.isRegularFile == true || values.isDirectory == true else { return nil }
        return url
    }
    static let extensions: [String: [String]] = [
        "image": ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg", "avif", "bmp"],
        "audio": ["mp3", "m4a", "wav", "flac", "aac", "aiff", "ogg"],
        "video": ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
        "document": ["pdf", "txt", "md", "rtf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv", "json"]
    ]
    static func kind(_ url: URL, directory: Bool) -> String {
        if directory { return "folder" }
        return extensions.first(where: { $0.value.contains(url.pathExtension.lowercased()) })?.key ?? "other"
    }
    static func predicate(text: String, kind: String) -> NSPredicate {
        var clauses = [NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text),
                       NSCompoundPredicate(notPredicateWithSubpredicate: NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, home.appendingPathComponent("Library").path + "/"))]
        let folder = NSPredicate(format: "%K == %@", "kMDItemContentType", "public.folder")
        if kind == "folder" { clauses.append(folder) }
        else if kind != "all" {
            clauses.append(NSCompoundPredicate(notPredicateWithSubpredicate: folder))
            let suffixes = extensions[kind] ?? extensions.values.flatMap { $0 }
            let types = NSCompoundPredicate(orPredicateWithSubpredicates: suffixes.map { NSPredicate(format: "%K ENDSWITH[cd] %@", NSMetadataItemFSNameKey, "." + $0) })
            clauses.append(kind == "other" ? NSCompoundPredicate(notPredicateWithSubpredicate: types) : types)
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }
    func start(text: String, filter: String, completion: @escaping ([Entry], Bool, Bool) -> Void) {
        self.text = text; self.filter = filter; self.completion = completion
        query.searchScopes = [Self.home.path]
        // Substitution arguments keep quotes/operators in user input literal.
        query.predicate = Self.predicate(text: text, kind: filter)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in self?.finish(partial: false) }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(partial: true) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        if !query.start() { finish(partial: true) }
    }
    func cancel() {
        completion = nil; cleanup()
    }
    private func cleanup() {
        query.stop(); timeout?.cancel(); timeout = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
    }
    private func finish(partial: Bool) {
        guard let completion else { return }
        self.completion = nil
        query.disableUpdates()
        var entries: [Entry] = []
        var seen = Set<String>()
        // Bound metadata work even for broad inputs. Never traverse the filesystem.
        let examined = min(query.resultCount, 2000)
        for index in 0..<examined {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = Self.allowedURL(URL(fileURLWithPath: path)), seen.insert(path).inserted,
                  url.lastPathComponent.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            let kind = Self.kind(url, directory: values.isDirectory == true)
            guard filter == "all" || kind == filter else { continue }
            entries.append(Entry(id: UUID().uuidString, url: url, name: url.lastPathComponent, kind: kind,
                                 modified: (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000, size: values.fileSize ?? 0))
            if entries.count == 150 { break }
        }
        let limited = partial || query.resultCount > examined || entries.count == 150
        cleanup(); completion(entries, limited, partial)
    }
}
