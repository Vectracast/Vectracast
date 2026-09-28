import AppKit
import ImageIO

/// Main-thread bookkeeping; bounded background decoding shared by thumbnails and previews.
final class HistoryImageLoader {
    private let cache = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    init() {
        cache.totalCostLimit = 48 * 1024 * 1024
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }
    func load(url: URL, maxPixels: Int, completion: @escaping (NSImage?) -> Void) {
        precondition(Thread.isMainThread)
        let key = url.path + ":" + String(maxPixels)
        if let image = cache.object(forKey: key as NSString) { completion(image); return }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        queue.addOperation { [weak self] in
            let cg: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let image = cg.map { NSImage(cgImage: $0, size: .zero) }
                if let cg, let image { self.cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height) }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }
}
