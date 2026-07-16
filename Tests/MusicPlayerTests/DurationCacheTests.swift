import XCTest
@testable import MusicPlayer

final class DurationCacheTests: XCTestCase {
    func testCacheMissReturnsNil() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            let url = directory.appendingPathComponent("missing.mp3")

            let duration = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(duration)
        }
    }

    func testStoreAndRetrieveDuration() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data().write(to: url)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            await cache.storeDuration(180.5, for: url)

            let retrieved = await cache.cachedDurationIfValid(for: url)
            let unwrapped = try XCTUnwrap(retrieved)
            XCTAssertEqual(unwrapped, 180.5, accuracy: 0.001)
        }
    }

    func testCacheInvalidatesOnFileContentChange() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("original".utf8).write(to: url)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            await cache.storeDuration(120.0, for: url)

            let beforeChange = await cache.cachedDurationIfValid(for: url)
            XCTAssertNotNil(beforeChange)

            // Change file content
            try Data("modified-longer-content".utf8).write(to: url)

            let afterChange = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(afterChange, "Cache should invalidate when file size changes")
        }
    }

    func testCacheInvalidatesOnFileMtimeChange() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            let content = Data(repeating: 42, count: 1000)
            try content.write(to: url)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            await cache.storeDuration(240.0, for: url)

            let beforeTouch = await cache.cachedDurationIfValid(for: url)
            XCTAssertNotNil(beforeTouch)

            // Touch file to change mtime
            let newDate = Date().addingTimeInterval(60)
            try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: url.path)

            let afterTouch = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(afterTouch, "Cache should invalidate when mtime changes")
        }
    }

    func testCachePersistsAcrossInstances() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("persistent".utf8).write(to: url)

            do {
                let writer = DurationCache(cacheFileURLOverride: cacheURL)
                await writer.storeDuration(300.0, for: url)
                // Wait for debounced save to complete before writer is released
                try await Task.sleep(nanoseconds: 600_000_000)
            }

            let reader = DurationCache(cacheFileURLOverride: cacheURL)
            let retrieved = await reader.cachedDurationIfValid(for: url)
            let unwrapped = try XCTUnwrap(retrieved)
            XCTAssertEqual(unwrapped, 300.0, accuracy: 0.001)
        }
    }

    func testRemoveInvalidatesEntry() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data().write(to: url)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            await cache.storeDuration(150.0, for: url)

            let beforeRemove = await cache.cachedDurationIfValid(for: url)
            XCTAssertNotNil(beforeRemove)

            await cache.remove(for: url)

            let afterRemove = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(afterRemove)
        }
    }

    func testRemoveAllClearsAllEntries() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let urls = (0..<5).map { directory.appendingPathComponent("track\($0).mp3") }
            for url in urls {
                try Data().write(to: url)
            }

            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            for (index, url) in urls.enumerated() {
                await cache.storeDuration(Double(100 + index * 10), for: url)
            }

            for url in urls {
                let cached = await cache.cachedDurationIfValid(for: url)
                XCTAssertNotNil(cached)
            }

            await cache.removeAll()

            for url in urls {
                let afterRemove = await cache.cachedDurationIfValid(for: url)
                XCTAssertNil(afterRemove)
            }
        }
    }

    func testRejectsInvalidDurations() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data().write(to: url)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)

            await cache.storeDuration(-1.0, for: url)
            let negative = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(negative)

            await cache.storeDuration(0.0, for: url)
            let zero = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(zero)

            await cache.storeDuration(.infinity, for: url)
            let infinite = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(infinite)

            await cache.storeDuration(.nan, for: url)
            let nan = await cache.cachedDurationIfValid(for: url)
            XCTAssertNil(nan)
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
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.int64Value

            // Write cache file with legacy lowercased key
            let legacyKey = DurationCache.legacyKey(for: url)
            let canonicalKey = DurationCache.key(for: url)
            XCTAssertNotEqual(legacyKey, canonicalKey, "Test requires path with mixed case")

            let legacyEntry: [String: Any] = [
                "durationSeconds": 200.0,
                "fileSize": fileSize,
                "mtimeNs": mtimeNs,
                "inode": inode.map { $0 as Any } ?? NSNull()
            ]

            let cacheFile: [String: Any] = [
                "version": 2,
                "entries": [legacyKey: legacyEntry]
            ]

            let data = try JSONSerialization.data(withJSONObject: cacheFile)
            try data.write(to: cacheURL, options: .atomic)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)

            // Should migrate legacy key to canonical on first access
            let duration = await cache.cachedDurationIfValid(for: url)
            XCTAssertNotNil(duration)
        }
    }

    func testFutureVersionPreservesOriginalBytes() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("audio".utf8).write(to: url)

            // Create future version cache file missing current required fields
            let futureCache = """
            {
                "version": 999,
                "futureField": "must-preserve"
            }
            """
            let originalBytes = Data(futureCache.utf8)
            try originalBytes.write(to: cacheURL, options: .atomic)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)

            // Attempt normal operations
            await cache.storeDuration(123.45, for: url)
            await cache.flushForTesting()

            let afterBytes = try Data(contentsOf: cacheURL)
            XCTAssertEqual(afterBytes, originalBytes, "Future version file must remain unchanged")
        }
    }

    func testUnknownFormatPreservesOriginalBytes() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("audio".utf8).write(to: url)

            // Create corrupted/unknown format
            let corruptedCache = Data("not valid json".utf8)
            try corruptedCache.write(to: cacheURL, options: .atomic)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)

            await cache.storeDuration(123.45, for: url)
            await cache.flushForTesting()

            let afterBytes = try Data(contentsOf: cacheURL)
            XCTAssertEqual(afterBytes, corruptedCache, "Unknown format file must remain unchanged")
        }
    }

    func testFutureVersionPreservesAfterRemoveAll() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let futureCache = """
            {
                "version": 999,
                "futureField": "must-preserve"
            }
            """
            let originalBytes = Data(futureCache.utf8)
            try originalBytes.write(to: cacheURL, options: .atomic)

            let cache = DurationCache(cacheFileURLOverride: cacheURL)
            await cache.removeAll()
            await cache.flushForTesting()

            let afterBytes = try Data(contentsOf: cacheURL)
            XCTAssertEqual(afterBytes, originalBytes, "Future version file must survive removeAll")
        }
    }

    private func withTemporaryCache(
        _ body: (URL, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-duration-cache-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("duration-cache.json")
        try await body(cacheURL, directory)
    }
}
