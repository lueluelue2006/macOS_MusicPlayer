import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 轻量级封面缓存，避免在 SwiftUI 刷新时重复解码/模糊处理
final class ArtworkCache {
    static let shared = ArtworkCache()
    private init() {
        // 合理的默认上限，避免无限增长（可根据需要调整）
        // 说明：App 会按 targetSize 缩放后再缓存，因此 cost 近似等于像素内存占用
        rawCache.countLimit = 300
        blurredCache.countLimit = 200
        rawCache.totalCostLimit = 32 * 1024 * 1024      // ~32MB
        blurredCache.totalCostLimit = 48 * 1024 * 1024   // ~48MB
    }

    private let rawCache = NSCache<NSString, NSImage>()
    private let blurredCache = NSCache<NSString, NSImage>()

    /// 清空所有封面缓存（用于“完全刷新”场景）
    func clear() {
        rawCache.removeAllObjects()
        blurredCache.removeAllObjects()
    }

    /// 获取解码&缩放后的封面图
    func image(for key: String, data: Data, targetSize: CGSize) -> NSImage? {
        let cacheKey = NSString(string: key + "|raw|" + "\(Int(targetSize.width))x\(Int(targetSize.height))")
        if let cached = rawCache.object(forKey: cacheKey) { return cached }
        guard let src = NSImage(data: data) else { return nil }
        let scaled = Self.resize(image: src, to: targetSize)
        if let scaled = scaled {
            let cost = Int(targetSize.width * targetSize.height * 4)
            rawCache.setObject(scaled, forKey: cacheKey, cost: cost)
        }
        return scaled
    }

    /// 获取预模糊的封面图
    func blurredImage(for key: String, data: Data, targetSize: CGSize, radius: Double = 20) -> NSImage? {
        let cacheKey = NSString(string: key + "|blur|r=\(Int(radius))|" + "\(Int(targetSize.width))x\(Int(targetSize.height))")
        if let cached = blurredCache.object(forKey: cacheKey) { return cached }
        guard let src = NSImage(data: data) else { return nil }
        guard let scaled = Self.resize(image: src, to: targetSize) else { return nil }
        guard let blurred = Self.blur(nsImage: scaled, radius: radius) else { return scaled }
        let cost = Int(targetSize.width * targetSize.height * 4)
        blurredCache.setObject(blurred, forKey: cacheKey, cost: cost)
        return blurred
    }

    // MARK: - Helpers

    private static func resize(image: NSImage, to targetSize: CGSize) -> NSImage? {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        return newImage
    }

    private static func blur(nsImage: NSImage, radius: Double) -> NSImage? {
        guard let tiff = nsImage.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.radius = Float(radius)
        filter.inputImage = ciImage
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        let rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cgImage = context.createCGImage(output, from: rect) else { return nil }
        let result = NSImage(size: nsImage.size)
        result.lockFocus()
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: rect)
        result.unlockFocus()
        return result
    }
}
