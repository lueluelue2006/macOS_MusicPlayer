import XCTest
@testable import MusicPlayer

final class PathKeyTests: XCTestCase {
    func testCanonicalNormalizesPath() {
        let path = "/Users/Test/Music/../Music/Song.mp3"
        let canonical = PathKey.canonical(path: path)

        XCTAssertEqual(canonical, "/Users/Test/Music/Song.mp3")
        XCTAssertFalse(canonical.contains(".."))
    }

    func testCanonicalForURLUsesStandardizedPath() {
        let url = URL(fileURLWithPath: "/tmp/../tmp/song.mp3")
        let canonical = PathKey.canonical(for: url)

        XCTAssertEqual(canonical, "/tmp/song.mp3")
    }

    func testCanonicalPreservesCase() {
        let path = "/Users/Test/Music/Song.MP3"
        let canonical = PathKey.canonical(path: path)

        XCTAssertEqual(canonical, "/Users/Test/Music/Song.MP3")
        XCTAssertTrue(canonical.contains("MP3"))
    }

    func testLegacyLowercasesCanonicalPath() {
        let path = "/Users/Test/Music/Song.MP3"
        let legacy = PathKey.legacy(path: path)

        XCTAssertEqual(legacy, "/users/test/music/song.mp3")
        XCTAssertFalse(legacy.contains("MP3"))
    }

    func testLegacyForURLLowercasesCanonicalPath() {
        let url = URL(fileURLWithPath: "/Users/Test/Music/Song.MP3")
        let legacy = PathKey.legacy(for: url)

        XCTAssertEqual(legacy, "/users/test/music/song.mp3")
    }

    func testLookupKeysReturnsSingleKeyWhenIdentical() {
        let path = "/users/test/song.mp3"
        let keys = PathKey.lookupKeys(forPath: path)

        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0], "/users/test/song.mp3")
    }

    func testLookupKeysReturnsTwoKeysWhenDifferent() {
        let path = "/Users/Test/Song.MP3"
        let keys = PathKey.lookupKeys(forPath: path)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], "/Users/Test/Song.MP3")
        XCTAssertEqual(keys[1], "/users/test/song.mp3")
    }

    func testLookupKeysForURLReturnsTwoKeysWhenDifferent() {
        let url = URL(fileURLWithPath: "/Users/Test/Song.MP3")
        let keys = PathKey.lookupKeys(for: url)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], "/Users/Test/Song.MP3")
        XCTAssertEqual(keys[1], "/users/test/song.mp3")
    }

    func testCanonicalHandlesUnicodeNormalization() {
        // é can be represented as single character (U+00E9) or combining (e + U+0301)
        let composedPath = "/Users/Test/café.mp3" // U+00E9
        let decomposedPath = "/Users/Test/caf\u{0065}\u{0301}.mp3" // e + combining acute

        let canonical1 = PathKey.canonical(path: composedPath)
        let canonical2 = PathKey.canonical(path: decomposedPath)

        XCTAssertEqual(canonical1, canonical2, "Unicode normalization should produce identical keys")
    }

    func testCanonicalNormalizesPathWithoutResolvingSymlinks() {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("pathkey-test-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: testDir) }

            let realFile = testDir.appendingPathComponent("real.mp3")
            try Data().write(to: realFile)

            let symlinkFile = testDir.appendingPathComponent("link.mp3")
            try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

            let canonicalReal = PathKey.canonical(for: realFile)
            let canonicalLink = PathKey.canonical(for: symlinkFile)

            // PathKey is for path normalization, not file identity resolution
            // Both paths should be normalized, but we don't assume symlink resolution
            XCTAssertTrue(canonicalReal.hasSuffix("/real.mp3"))
            XCTAssertTrue(canonicalLink.hasSuffix("/link.mp3"))
        } catch {
            XCTFail("Symlink test setup failed: \(error)")
        }
    }

    func testCanonicalHandlesRelativePaths() {
        let relativePath = "Music/Song.mp3"
        let canonical = PathKey.canonical(path: relativePath)

        // Relative paths are resolved relative to current directory
        XCTAssertTrue(canonical.hasSuffix("Music/Song.mp3"))
        XCTAssertTrue(canonical.hasPrefix("/"))
    }

    func testLookupKeysOrderPutsCanonicalFirst() {
        let path = "/Users/Test/Song.MP3"
        let keys = PathKey.lookupKeys(forPath: path)

        guard keys.count == 2 else {
            XCTFail("Expected 2 keys")
            return
        }

        // Canonical (case-preserved) should be first
        XCTAssertEqual(keys[0], "/Users/Test/Song.MP3")
        // Legacy (lowercased) should be second
        XCTAssertEqual(keys[1], "/users/test/song.mp3")
    }
}
