import Foundation
import CoreGraphics

struct LauncherAnchor: Codable {
    var centerX: CGFloat
    var topInset: CGFloat
}

enum LauncherPlacement {
    static func defaultTop(_ area: CGRect) -> CGFloat {
        min(area.height * 0.28, max(16, area.height - 474 - 16))
    }
    static func constrain(_ frame: CGRect, in area: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(frame.minX, area.minX + 16), max(area.minX + 16, area.maxX - frame.width - 16))
        let top = min(area.maxY - 16, max(frame.maxY, area.minY + min(474, area.height - 32) + 16))
        result.origin.y = top - frame.height
        return result
    }
    static func restore(_ anchor: LauncherAnchor?, size: CGSize, in area: CGRect) -> CGRect {
        let x = anchor.map { area.minX + $0.centerX * area.width } ?? area.midX
        let inset = anchor.map { $0.topInset * area.height } ?? defaultTop(area)
        return constrain(CGRect(x: x - size.width / 2, y: area.maxY - inset - size.height, width: size.width, height: size.height), in: area)
    }
    static func anchor(for frame: CGRect, in area: CGRect) -> LauncherAnchor {
        LauncherAnchor(centerX: (frame.midX - area.minX) / max(1, area.width), topInset: (area.maxY - frame.maxY) / max(1, area.height))
    }
    struct Snap {
        var horizontal = false
        var vertical = false
    }
    static func snap(_ proposed: CGRect, in area: CGRect, enabled: Bool, previous: Snap) -> (CGRect, Snap) {
        var frame = constrain(proposed, in: area)
        guard enabled else { return (frame, Snap()) }
        let top = area.maxY - defaultTop(area)
        let state = Snap(horizontal: abs(frame.midX - area.midX) <= (previous.horizontal ? 24 : 12),
                         vertical: abs(frame.maxY - top) <= (previous.vertical ? 24 : 12))
        if state.horizontal { frame.origin.x = area.midX - frame.width / 2 }
        if state.vertical { frame.origin.y = top - frame.height }
        return (frame, state)
    }
}

final class LauncherPositionStore {
    private let url: URL
    private var anchors: [String: LauncherAnchor]
    init(root: URL) {
        url = root.appendingPathComponent("launcher-position.json")
        anchors = (try? JSONDecoder().decode([String: LauncherAnchor].self, from: Data(contentsOf: url))) ?? [:]
    }
    func anchor(for screen: String) -> LauncherAnchor? { anchors[screen] }
    func save(_ anchor: LauncherAnchor, for screen: String) {
        anchors[screen] = anchor
        if let data = try? JSONEncoder().encode(anchors) { try? data.write(to: url, options: .atomic) }
    }
}
