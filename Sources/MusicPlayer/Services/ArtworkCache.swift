import AppKit
import Foundation

/// Small AppKit image cache retained for the load benchmark. Production cover
/// loading uses bounded ImageIO downsampling elsewhere.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let rawCache = NSCache<NSString, NSImage>()

    private init() {
        rawCache.countLimit = 32
        rawCache.totalCostLimit = 8 * 1_024 * 1_024
    }

    func clear() {
        rawCache.removeAllObjects()
    }

    func image(for key: String, data: Data, targetSize: CGSize) -> NSImage? {
        guard targetSize.width.isFinite,
              targetSize.height.isFinite,
              targetSize.width > 0,
              targetSize.height > 0 else { return nil }

        let cacheKey = NSString(
            string: key + "|raw|\(Int(targetSize.width))x\(Int(targetSize.height))"
        )
        if let cached = rawCache.object(forKey: cacheKey) {
            return cached
        }
        guard let source = NSImage(data: data),
              let scaled = Self.resize(image: source, to: targetSize) else { return nil }

        let cost = max(1, Int(targetSize.width * targetSize.height * 4))
        rawCache.setObject(scaled, forKey: cacheKey, cost: cost)
        return scaled
    }

    private static func resize(image: NSImage, to targetSize: CGSize) -> NSImage? {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        return newImage
    }
}
