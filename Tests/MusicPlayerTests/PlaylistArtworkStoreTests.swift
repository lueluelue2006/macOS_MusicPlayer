import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistArtworkStoreTests: XCTestCase {
    func testBundledArtistCoverMappingsSupportSimplifiedAndTraditionalNames() {
        XCTAssertEqual(
            PlaylistArtworkStore.bundledFilename(forPlaylistName: " 杨坤 "),
            "yang-kun.png"
        )
        XCTAssertEqual(
            PlaylistArtworkStore.bundledFilename(forPlaylistName: "費玉清"),
            "fei-yu-ching.png"
        )
        XCTAssertEqual(
            PlaylistArtworkStore.bundledFilename(forPlaylistName: "孫燕姿"),
            "stefanie-sun.png"
        )
        XCTAssertEqual(
            PlaylistArtworkStore.bundledFilename(forPlaylistName: "王菲"),
            "faye-wong.png"
        )
        XCTAssertNil(PlaylistArtworkStore.bundledFilename(forPlaylistName: "旅行歌单"))
    }

    func testCustomArtworkIsNormalizedLoadedAndRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlist-artwork-\(UUID().uuidString)",
            isDirectory: true
        )
        let customDirectory = directory.appendingPathComponent("custom", isDirectory: true)
        let bundledDirectory = directory.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        try Self.writeFixturePNG(to: sourceURL, width: 1_600, height: 800)

        let playlist = UserPlaylist(name: "旅行歌单", tracks: [])
        let store = PlaylistArtworkStore(
            customDirectoryOverride: customDirectory,
            bundledDirectoryOverride: bundledDirectory
        )

        try await store.importArtwork(from: sourceURL, for: playlist.id)
        let hasImportedArtwork = await store.hasCustomArtwork(for: playlist.id)
        XCTAssertTrue(hasImportedArtwork)

        let persistedURL = customDirectory.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let persistedSource = try XCTUnwrap(CGImageSourceCreateWithURL(persistedURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(persistedSource, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), 1_024)

        let thumbnail = await store.image(for: playlist, targetPixelSize: 128)
        XCTAssertNotNil(thumbnail)
        XCTAssertLessThanOrEqual(max(thumbnail?.width ?? 0, thumbnail?.height ?? 0), 128)

        try await store.removeCustomArtwork(for: playlist.id)
        let hasRemovedArtwork = await store.hasCustomArtwork(for: playlist.id)
        let removedImage = await store.image(for: playlist, targetPixelSize: 128)
        XCTAssertFalse(hasRemovedArtwork)
        XCTAssertNil(removedImage)
    }

    private static func writeFixturePNG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )
        context.setFillColor(CGColor(red: 0.84, green: 0.16, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
    }
}
