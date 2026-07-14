import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads small playlist-cover thumbnails and persists user-selected overrides.
///
/// Built-in artist covers live in the app bundle. Custom images are normalized
/// once to a bounded JPEG in Application Support, then every UI request is
/// downsampled before it reaches the in-memory cache.
actor PlaylistArtworkStore {
  static let shared = PlaylistArtworkStore()

  enum ArtworkError: LocalizedError {
    case unreadableImage
    case encodingFailed
    case storageUnavailable

    var errorDescription: String? {
      switch self {
      case .unreadableImage:
        return "无法读取这张图片"
      case .encodingFailed:
        return "无法处理这张图片"
      case .storageUnavailable:
        return "无法访问歌单封面存储目录"
      }
    }
  }

  private let fileManager: FileManager
  private let customDirectoryOverride: URL?
  private let bundledDirectoryOverride: URL?
  private let imageCache = NSCache<NSString, CGImage>()

  init(
    fileManager: FileManager = .default,
    customDirectoryOverride: URL? = nil,
    bundledDirectoryOverride: URL? = nil
  ) {
    self.fileManager = fileManager
    self.customDirectoryOverride = customDirectoryOverride
    self.bundledDirectoryOverride = bundledDirectoryOverride
    imageCache.countLimit = 16
    imageCache.totalCostLimit = 8 * 1_024 * 1_024
  }

  func image(for playlist: UserPlaylist, targetPixelSize: Int) -> CGImage? {
    let pixelSize = min(max(targetPixelSize, 48), 512)
    guard let sourceURL = sourceURL(for: playlist) else { return nil }

    let cacheKey = cacheKey(for: sourceURL, pixelSize: pixelSize)
    if let cached = imageCache.object(forKey: cacheKey as NSString) {
      return cached
    }

    guard let cgImage = Self.downsampleImage(at: sourceURL, maxPixelSize: pixelSize) else {
      return nil
    }

    imageCache.setObject(
      cgImage,
      forKey: cacheKey as NSString,
      cost: cgImage.bytesPerRow * cgImage.height
    )
    return cgImage
  }

  func hasCustomArtwork(for playlistID: UserPlaylist.ID) -> Bool {
    guard let url = customArtworkURL(for: playlistID, createDirectory: false) else { return false }
    return fileManager.fileExists(atPath: url.path)
  }

  func importArtwork(from sourceURL: URL, for playlistID: UserPlaylist.ID) throws {
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed { sourceURL.stopAccessingSecurityScopedResource() }
    }

    guard let cgImage = Self.downsampleImage(at: sourceURL, maxPixelSize: 1_024) else {
      throw ArtworkError.unreadableImage
    }
    guard let jpegData = Self.jpegData(from: cgImage, quality: 0.86) else {
      throw ArtworkError.encodingFailed
    }
    guard let destinationURL = customArtworkURL(for: playlistID, createDirectory: true) else {
      throw ArtworkError.storageUnavailable
    }

    try jpegData.write(to: destinationURL, options: .atomic)
    imageCache.removeAllObjects()
  }

  func removeCustomArtwork(for playlistID: UserPlaylist.ID) throws {
    guard let url = customArtworkURL(for: playlistID, createDirectory: false) else {
      throw ArtworkError.storageUnavailable
    }
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    imageCache.removeAllObjects()
  }

  static func bundledFilename(forPlaylistName name: String) -> String? {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized {
    case "杨坤", "楊坤":
      return "yang-kun.png"
    case "费玉清", "費玉清":
      return "fei-yu-ching.png"
    case "孙燕姿", "孫燕姿":
      return "stefanie-sun.png"
    case "王菲":
      return "faye-wong.png"
    default:
      return nil
    }
  }

  private func sourceURL(for playlist: UserPlaylist) -> URL? {
    if let customURL = customArtworkURL(for: playlist.id, createDirectory: false),
      fileManager.fileExists(atPath: customURL.path)
    {
      return customURL
    }

    guard let filename = Self.bundledFilename(forPlaylistName: playlist.name) else { return nil }
    let directory = bundledDirectoryOverride
      ?? Bundle.main.resourceURL?.appendingPathComponent("PlaylistCovers", isDirectory: true)
    guard let url = directory?.appendingPathComponent(filename, isDirectory: false),
      fileManager.fileExists(atPath: url.path)
    else {
      return nil
    }
    return url
  }

  private func customArtworkURL(
    for playlistID: UserPlaylist.ID,
    createDirectory: Bool
  ) -> URL? {
    let directory: URL
    if let customDirectoryOverride {
      directory = customDirectoryOverride
    } else {
      guard let base = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first else { return nil }
      directory = base
        .appendingPathComponent("MusicPlayer", isDirectory: true)
        .appendingPathComponent("PlaylistArtwork", isDirectory: true)
    }

    if createDirectory, !fileManager.fileExists(atPath: directory.path) {
      do {
        try fileManager.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
      } catch {
        return nil
      }
    }
    return directory.appendingPathComponent("\(playlistID.uuidString).jpg", isDirectory: false)
  }

  private func cacheKey(for url: URL, pixelSize: Int) -> String {
    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
    let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    return "\(url.path)|\(pixelSize)|\(modifiedAt)|\(fileSize)"
  }

  private nonisolated static func downsampleImage(
    at url: URL,
    maxPixelSize: Int
  ) -> CGImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
      return nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  private nonisolated static func jpegData(
    from image: CGImage,
    quality: CGFloat
  ) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else { return nil }

    let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
