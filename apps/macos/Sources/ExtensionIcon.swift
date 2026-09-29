import AppKit
import CryptoKit

enum ExtensionIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ reference: String?, extensionID: String?, resources: [String: String]?, fallback: String) -> NSImage? {
        if let reference, reference.hasPrefix("assets/"),
           ExtensionManifest.validIconReference(reference),
           let extensionID, let encoded = resources?[reference],
           let data = Data(base64Encoded: encoded), data.count <= 512_000 {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let key = "\(extensionID)/\(reference)/\(digest)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            if let decoded = NSImage(data: data) {
                cache.setObject(decoded, forKey: key)
                return decoded
            }
        }
        return NSImage(systemSymbolName: reference?.hasPrefix("assets/") == true ? fallback : (reference ?? fallback), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
    }
}
