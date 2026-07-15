import XCTest
@testable import MusicPlayer

final class MetadataCacheTests: XCTestCase {
    func testCacheMissReturnsNil() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let url = directory.appendingPathComponent("missing.mp3")

            let metadata = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(metadata)
        }
    }

    func testStoreAndRetrieveMetadata() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data().write(to: url)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let metadata = AudioMetadata(
                title: "Test Song",
                artist: "Test Artist",
                album: "Test Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)

            let retrieved = await cache.cachedMetadataIfValid(for: url)
            let unwrapped = try XCTUnwrap(retrieved)
            XCTAssertEqual(unwrapped.title, "Test Song")
            XCTAssertEqual(unwrapped.artist, "Test Artist")
            XCTAssertEqual(unwrapped.album, "Test Album")
        }
    }

    func testCacheInvalidatesOnFileContentChange() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("original".utf8).write(to: url)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let metadata = AudioMetadata(
                title: "Original",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)

            let beforeChange = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNotNil(beforeChange)

            // Change file content (size changes)
            try Data("modified-longer-content".utf8).write(to: url)

            let afterChange = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(afterChange, "Cache should invalidate when file size changes")
        }
    }

    func testCacheInvalidatesOnFileMtimeChange() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            let content = Data(repeating: 42, count: 1000)
            try content.write(to: url)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let metadata = AudioMetadata(
                title: "Song",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)

            let beforeTouch = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNotNil(beforeTouch)

            // Touch file to change mtime
            let newDate = Date().addingTimeInterval(60)
            try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: url.path)

            let afterTouch = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(afterTouch, "Cache should invalidate when mtime changes")
        }
    }

    func testCachePersistsAcrossInstances() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("persistent".utf8).write(to: url)

            do {
                let writer = MetadataCache(cacheFileURLOverride: cacheURL)
                let metadata = AudioMetadata(
                    title: "Persistent Song",
                    artist: "Persistent Artist",
                    album: "Persistent Album",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
                await writer.storeBasicMetadata(metadata, for: url)
                // Wait for debounced save
                try await Task.sleep(nanoseconds: 600_000_000)
            }

            let reader = MetadataCache(cacheFileURLOverride: cacheURL)
            let retrieved = await reader.cachedMetadataIfValid(for: url)
            let unwrapped = try XCTUnwrap(retrieved)
            XCTAssertEqual(unwrapped.title, "Persistent Song")
            XCTAssertEqual(unwrapped.artist, "Persistent Artist")
            XCTAssertEqual(unwrapped.album, "Persistent Album")
        }
    }

    func testRemoveInvalidatesEntry() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data().write(to: url)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let metadata = AudioMetadata(
                title: "Song",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)

            let beforeRemove = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNotNil(beforeRemove)

            await cache.remove(for: url)

            let afterRemove = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(afterRemove)
        }
    }

    func testRemoveAllClearsAllEntries() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let urls = (0..<5).map { directory.appendingPathComponent("track\($0).mp3") }
            for url in urls {
                try Data().write(to: url)
            }

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            for (index, url) in urls.enumerated() {
                let metadata = AudioMetadata(
                    title: "Song \(index)",
                    artist: "Artist \(index)",
                    album: "Album \(index)",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
                await cache.storeBasicMetadata(metadata, for: url)
            }

            for url in urls {
                let cached = await cache.cachedMetadataIfValid(for: url)
                XCTAssertNotNil(cached)
            }

            await cache.removeAll()

            for url in urls {
                let afterRemove = await cache.cachedMetadataIfValid(for: url)
                XCTAssertNil(afterRemove)
            }
        }
    }

    func testCorruptedMetadataIsRejected() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data().write(to: url)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)

            // Test Unicode replacement character
            let replacementChar = AudioMetadata(
                title: "Song with \u{FFFD}",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(replacementChar, for: url)
            let retrieved1 = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(retrieved1, "Should reject metadata with Unicode replacement character")

            // Test multiple question marks
            let questionMarks = AudioMetadata(
                title: "??????",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(questionMarks, for: url)
            let retrieved2 = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(retrieved2, "Should reject metadata with corrupted question marks")

            // Test high ratio of question marks (>= 40%)
            let highRatio = AudioMetadata(
                title: "So???ng",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(highRatio, for: url)
            let retrieved3 = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNil(retrieved3, "Should reject metadata with high ratio of question marks")

            // Test valid metadata with few question marks (< 40% ratio)
            let validWithQuestion = AudioMetadata(
                title: "What? A Song!",
                artist: "Artist",
                album: "Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(validWithQuestion, for: url)
            let retrieved4 = await cache.cachedMetadataIfValid(for: url)
            XCTAssertNotNil(retrieved4, "Should accept metadata with low ratio of question marks")
        }
    }

    func testLegacyKeyMigration() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("Track.mp3")
            let content = Data("test-content".utf8)
            try content.write(to: url)

            // Read actual file attributes
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs[.size] as! NSNumber).int64Value
            let modDate = attrs[.modificationDate] as! Date
            let mtimeNs = Int64((modDate.timeIntervalSince1970 * 1_000_000_000).rounded())

            // Write cache file with legacy lowercased key
            let legacyKey = MetadataCache.legacyKey(for: url)
            let canonicalKey = MetadataCache.key(for: url)
            XCTAssertNotEqual(legacyKey, canonicalKey, "Test requires path with mixed case")

            let legacyEntry: [String: Any] = [
                "title": "Legacy Song",
                "artist": "Legacy Artist",
                "album": "Legacy Album",
                "fileSize": fileSize,
                "mtimeNs": mtimeNs
            ]

            let cacheFile: [String: Any] = [
                "version": 1,
                "entries": [legacyKey: legacyEntry]
            ]

            let data = try JSONSerialization.data(withJSONObject: cacheFile)
            try data.write(to: cacheURL, options: .atomic)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)

            // Should migrate legacy key to canonical on first access
            let metadata = await cache.cachedMetadataIfValid(for: url)
            let unwrapped = try XCTUnwrap(metadata)
            XCTAssertEqual(unwrapped.title, "Legacy Song")
            XCTAssertEqual(unwrapped.artist, "Legacy Artist")
            XCTAssertEqual(unwrapped.album, "Legacy Album")
        }
    }

    private func withTemporaryCache(
        _ body: (URL, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-metadata-cache-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("metadata-cache.json")
        try await body(cacheURL, directory)
    }
}
