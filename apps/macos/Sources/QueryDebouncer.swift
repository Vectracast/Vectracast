import Foundation

/// Shared trailing-edge input policy for all extension entry modes.
final class QueryDebouncer {
    static let minimumDelayMs = 200
    private var pending: DispatchWorkItem?
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        pending?.cancel()
        pending = nil
    }

    func schedule(requestedDelayMs: Int?, immediate: Bool = false, action: @escaping () -> Void) {
        cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = nil
            action()
        }
        pending = work
        if immediate { work.perform(); return }
        let delay = max(Self.minimumDelayMs, requestedDelayMs ?? Self.minimumDelayMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }

    deinit { pending?.cancel() }
}
