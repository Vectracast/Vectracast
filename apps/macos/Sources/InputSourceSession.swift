import Foundation

/// Keeps restoration policy independent from the system input-source API.
final class InputSourceSession {
    private var previous: String?
    private var selected: String?
    func activate(_ target: String?, current: () -> String?, select: (String) -> Bool) -> Bool {
        guard previous == nil, let target, !target.isEmpty else { return true }
        guard let before = current() else { return false }
        guard before != target else { return true }
        guard select(target) else { return false }
        previous = before; selected = target; return true
    }
    func restore(current: () -> String?, select: (String) -> Bool) {
        defer { previous = nil; selected = nil }
        if let previous, current() == selected { _ = select(previous) }
    }
}
