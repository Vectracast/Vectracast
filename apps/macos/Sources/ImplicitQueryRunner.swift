import Foundation

/// Runs opted-in extension commands against unclaimed nonempty launcher input.
/// Each command owns a cancellable XPC client; completion order never changes ranking.
final class ImplicitQueryRunner {
    private var clients: [RuntimeClient] = []
    private var pending: [QueryDebouncer] = []
    private var generation = UUID()
    var onLog: ((String) -> Void)?
    func cancel() {
        generation = UUID()
        pending.forEach { $0.cancel() }; pending.removeAll()
        clients.forEach { $0.cancel() }; clients.removeAll()
    }
    func query(_ extensions: [InstalledExtension], input: String, update: @escaping ([ResultItem], Bool) -> Void) {
        cancel(); let token = generation
        let entries = extensions.filter(\.enabled).flatMap { info in info.manifest.commands.filter(\.isImplicit).map { (info, $0) } }
        guard !entries.isEmpty, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { update([], true); return }
        var batches = Array(repeating: [ResultItem](), count: entries.count)
        var remaining = entries.count
        for (index, entry) in entries.enumerated() {
            let (info, command) = entry
            let client = RuntimeClient(); client.onLog = onLog; clients.append(client)
            let debouncer = QueryDebouncer()
            pending.append(debouncer)
            debouncer.schedule(requestedDelayMs: command.debounceMs) { [weak self] in
                guard let self, self.generation == token else { return }
                client.query(info, command: command.id, query: input, rawInput: input) { [weak self] result in
                    guard let self, self.generation == token else { return }
                    if let items = try? result.get() {
                        batches[index] = items.map { item in
                            ResultItem(id: "implicit/\(info.manifest.id)/\(command.id)/\(item.id)", title: item.title, subtitle: item.subtitle, icon: item.icon, actions: item.actions, detail: item.detail, applicationPath: item.applicationPath, applicationId: item.applicationId, extensionID: item.extensionID, fileID: item.fileID, filePath: item.filePath)
                        }
                    }
                    remaining -= 1; update(batches.flatMap { $0 }, remaining == 0)
                }
            }
        }
    }
    deinit { pending.forEach { $0.cancel() }; clients.forEach { $0.cancel() } }
}
