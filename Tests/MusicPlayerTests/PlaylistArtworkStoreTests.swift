import AppKit
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistArtworkStoreTests: XCTestCase {
    func testUserSelectedArtworkAllowsReadableForeignOwnerButStoredArtworkDoesNot() {
        let currentUID = geteuid()
        let differentUID = currentUID == uid_t.max ? 0 : currentUID + 1

        XCTAssertTrue(
            PlaylistArtworkStore.ownerIsAllowed(
                differentUID,
                allowRootOwner: false,
                allowAnyReadableOwner: true
            )
        )
        XCTAssertFalse(
            PlaylistArtworkStore.ownerIsAllowed(
                differentUID,
                allowRootOwner: false,
                allowAnyReadableOwner: false
            )
        )
    }

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
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: customDirectory.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: persistedURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(filePermissions, 0o600)

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

    func testCorruptedCustomArtworkFallsBackWithoutDeletingUserAsset() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Self.writeFixturePNG(
            to: fixture.bundled.appendingPathComponent("yang-kun.png"),
            width: 512,
            height: 512
        )
        let playlist = UserPlaylist(name: "杨坤", tracks: [])
        let customURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let corruptedBytes = Data("not-an-image".utf8)
        try corruptedBytes.write(to: customURL)
        let store = PlaylistArtworkStore(
            customDirectoryOverride: fixture.custom,
            bundledDirectoryOverride: fixture.bundled
        )

        let image = await store.image(for: playlist, targetPixelSize: 128)
        let hasCustomArtwork = await store.hasCustomArtwork(for: playlist.id)

        XCTAssertNotNil(image)
        XCTAssertEqual(try Data(contentsOf: customURL), corruptedBytes)
        XCTAssertTrue(hasCustomArtwork)
    }

    func testImportRejectsSymlinkAndPreservesExistingArtwork() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let originalSource = fixture.root.appendingPathComponent("original.png")
        let linkedSource = fixture.root.appendingPathComponent("linked.png")
        let symlink = fixture.root.appendingPathComponent("source-link.png")
        try Self.writeFixturePNG(to: originalSource, width: 320, height: 320)
        try Self.writeFixturePNG(to: linkedSource, width: 640, height: 320)

        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await store.importArtwork(from: originalSource, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let originalBytes = try Data(contentsOf: persistedURL)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: linkedSource)

        do {
            try await store.importArtwork(from: symlink, for: playlist.id)
            XCTFail("Symlink input must be rejected")
        } catch {
            XCTAssertEqual(try Data(contentsOf: persistedURL), originalBytes)
        }
    }

    func testImportRejectsOversizedSparseInputWithoutReplacingArtwork() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let originalSource = fixture.root.appendingPathComponent("original.png")
        let oversizedSource = fixture.root.appendingPathComponent("oversized.png")
        try Self.writeFixturePNG(to: originalSource, width: 320, height: 320)
        FileManager.default.createFile(atPath: oversizedSource.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversizedSource)
        try handle.truncate(atOffset: 33 * 1_024 * 1_024)
        try handle.close()

        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await store.importArtwork(from: originalSource, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let originalBytes = try Data(contentsOf: persistedURL)

        do {
            try await store.importArtwork(from: oversizedSource, for: playlist.id)
            XCTFail("Oversized input must be rejected")
        } catch {
            XCTAssertEqual(try Data(contentsOf: persistedURL), originalBytes)
        }
    }

    func testImportRejectsExcessivePixelDimensionsBeforeDecode() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let extremeSource = fixture.root.appendingPathComponent("extreme.png")
        // A single scanline keeps the fixture tiny while exercising the metadata
        // boundary before ImageIO is allowed to decode the image.
        try Self.writeFixturePNG(to: extremeSource, width: 20_000, height: 1)
        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)

        do {
            try await store.importArtwork(from: extremeSource, for: playlist.id)
            XCTFail("Extreme image dimensions must be rejected before decode")
        } catch {
            let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
            XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        }
    }

    func testFailedReplacementRestoresPreviousArtworkBytes() async throws {
        enum InjectedFailure: Error { case afterReplacement }

        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let originalSource = fixture.root.appendingPathComponent("original.png")
        let replacementSource = fixture.root.appendingPathComponent("replacement.png")
        try Self.writeFixturePNG(to: originalSource, width: 320, height: 320)
        try Self.writeFixturePNG(to: replacementSource, width: 640, height: 320)

        let store = PlaylistArtworkStore(
            customDirectoryOverride: fixture.custom,
            replacementValidationHook: { throw InjectedFailure.afterReplacement }
        )
        try await store.importArtwork(from: originalSource, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let originalBytes = try Data(contentsOf: persistedURL)

        do {
            try await store.importArtwork(from: replacementSource, for: playlist.id)
            XCTFail("Injected replacement failure must surface")
        } catch {
            XCTAssertEqual(try Data(contentsOf: persistedURL), originalBytes)
        }
    }

    func testArtworkRemovalTicketCanRollbackWithoutChangingBytes() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let sourceURL = fixture.root.appendingPathComponent("source.png")
        try Self.writeFixturePNG(to: sourceURL, width: 300, height: 300)
        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await store.importArtwork(from: sourceURL, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let originalBytes = try Data(contentsOf: persistedURL)

        let ticket = try await store.stageCustomArtworkRemoval(for: playlist.id)
        XCTAssertNotNil(ticket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        try await store.rollbackCustomArtworkRemoval(try XCTUnwrap(ticket))

        XCTAssertEqual(try Data(contentsOf: persistedURL), originalBytes)
    }

    func testArtworkRemovalTicketCommitsOnlyAfterExplicitCommit() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let sourceURL = fixture.root.appendingPathComponent("source.png")
        try Self.writeFixturePNG(to: sourceURL, width: 300, height: 300)
        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await store.importArtwork(from: sourceURL, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")

        let stagedTicket = try await store.stageCustomArtworkRemoval(for: playlist.id)
        let ticket = try XCTUnwrap(stagedTicket)
        try await store.commitCustomArtworkRemoval(ticket)
        try await store.commitCustomArtworkRemoval(ticket)

        let hasCustomArtwork = await store.hasCustomArtwork(for: playlist.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        XCTAssertFalse(hasCustomArtwork)
    }

    func testInterruptedArtworkRemovalIsRecoveredByNewStore() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let sourceURL = fixture.root.appendingPathComponent("source.png")
        try Self.writeFixturePNG(to: sourceURL, width: 300, height: 300)
        let firstStore = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await firstStore.importArtwork(from: sourceURL, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let originalBytes = try Data(contentsOf: persistedURL)
        _ = try await firstStore.stageCustomArtworkRemoval(for: playlist.id)

        let relaunchedStore = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        let recoveredCount = try await relaunchedStore.recoverInterruptedRemovalTransactions()

        XCTAssertEqual(recoveredCount, 1)
        XCTAssertEqual(try Data(contentsOf: persistedURL), originalBytes)
    }

    func testInterruptedRemovalFailureIsRetriedInsteadOfMarkedRecovered() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let pending = fixture.custom.appendingPathComponent(".PendingDeletion", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let staged = pending.appendingPathComponent(
            "\(playlist.id.uuidString)--\(UUID().uuidString).jpg"
        )
        let symlinkTarget = fixture.root.appendingPathComponent("target.png")
        try Self.writeFixturePNG(to: symlinkTarget, width: 300, height: 300)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: symlinkTarget)

        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        let availableWhileRecoveryIsBlocked = await store.hasCustomArtwork(for: playlist.id)
        XCTAssertFalse(availableWhileRecoveryIsBlocked)

        try FileManager.default.removeItem(at: staged)
        try Self.writeFixturePNG(to: staged, width: 300, height: 300)

        let recoveredCount = try await store.recoverInterruptedRemovalTransactions()
        let availableAfterRetry = await store.hasCustomArtwork(for: playlist.id)
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertTrue(availableAfterRetry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testPendingRemovalDirectoryHasABoundedTicketCount() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let sourceURL = fixture.root.appendingPathComponent("source.png")
        try Self.writeFixturePNG(to: sourceURL, width: 300, height: 300)
        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await store.importArtwork(from: sourceURL, for: playlist.id)
        let persistedURL = fixture.custom.appendingPathComponent("\(playlist.id.uuidString).jpg")
        let pending = fixture.custom.appendingPathComponent(".PendingDeletion", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        for index in 0..<256 {
            FileManager.default.createFile(
                atPath: pending.appendingPathComponent("marker-\(index)").path,
                contents: Data()
            )
        }

        do {
            _ = try await store.stageCustomArtworkRemoval(for: playlist.id)
            XCTFail("The pending transaction directory must be bounded")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURL.path))
        }
    }

    func testClearMemoryCachePreservesCustomArtwork() async throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = UserPlaylist(name: "旅行", tracks: [])
        let sourceURL = fixture.root.appendingPathComponent("source.png")
        try Self.writeFixturePNG(to: sourceURL, width: 300, height: 300)
        let store = PlaylistArtworkStore(customDirectoryOverride: fixture.custom)
        try await store.importArtwork(from: sourceURL, for: playlist.id)

        _ = await store.image(for: playlist, targetPixelSize: 128)
        await store.clearMemoryCache()
        let hasCustomArtwork = await store.hasCustomArtwork(for: playlist.id)
        let reloaded = await store.image(for: playlist, targetPixelSize: 128)

        XCTAssertTrue(hasCustomArtwork)
        XCTAssertNotNil(reloaded)
    }

    private func makeFixtureDirectories() throws -> (root: URL, custom: URL, bundled: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlist-artwork-\(UUID().uuidString)",
            isDirectory: true
        )
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        return (root, custom, bundled)
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
