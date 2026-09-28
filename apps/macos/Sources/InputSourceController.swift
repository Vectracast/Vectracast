import AppKit
import Carbon

final class InputSourceController {
    struct Source { let id: String; let name: String; let value: TISInputSource }
    private let session = InputSourceSession()
    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    static func available() -> [Source] {
        let filter = [kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!,
                      kTISPropertyInputSourceIsSelectCapable!: true] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        return sources.compactMap { source in
            guard let id = string(source, kTISPropertyInputSourceID), let name = string(source, kTISPropertyLocalizedName) else { return nil }
            return Source(id: id, name: name, value: source)
        }
    }
    func activate(_ id: String?) -> Bool {
        session.activate(id, current: current, select: select)
    }
    func restore() {
        session.restore(current: current, select: select)
    }
    private func current() -> String? {
        Self.string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    }
    private func select(_ id: String) -> Bool {
        guard let source = Self.available().first(where: { $0.id == id }) else { return false }
        return TISSelectInputSource(source.value) == noErr
    }
}
