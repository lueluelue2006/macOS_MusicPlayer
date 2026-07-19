import XCTest
@testable import MusicPlayer

final class MetadataCacheTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var value: TimeInterval

        init(_ value: TimeInterval) {
            self.value = value
        }
    }

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
                year: "2026",
                genre: "Pop",
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)

            let retrieved = await cache.cachedMetadataIfValid(for: url)
            let unwrapped = try XCTUnwrap(retrieved)
            XCTAssertEqual(unwrapped.title, "Test Song")
            XCTAssertEqual(unwrapped.artist, "Test Artist")
            XCTAssertEqual(unwrapped.album, "Test Album")
            XCTAssertEqual(unwrapped.year, "2026")
            XCTAssertEqual(unwrapped.genre, "Pop")
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
                await writer.flushForTesting()
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

            // Literal question marks are valid metadata, not evidence of corruption.
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
            XCTAssertEqual(retrieved2?.title, "??????")

            // A high question-mark ratio is valid as well.
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
            XCTAssertEqual(retrieved3?.title, "So???ng")

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
                "mtimeNs": mtimeNs,
                "inode": (attrs[.systemFileNumber] as? NSNumber).map { $0.int64Value as Any } ?? NSNull(),
                "year": "2026",
                "genre": "Pop",
                "lastAccessedAt": Int64(Date().timeIntervalSince1970)
            ]

            let cacheFile: [String: Any] = [
                "version": 2,
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
            XCTAssertEqual(unwrapped.year, "2026")
            XCTAssertEqual(unwrapped.genre, "Pop")
        }
    }

    func testFutureVersionIsQuarantinedAndCurrentCacheRemainsWritable() async throws {
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

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)

            // Attempt normal operations
            let metadata = AudioMetadata(
                title: "New Song",
                artist: "New Artist",
                album: "New Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)
            await cache.flushForTesting()

            let active = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
            XCTAssertEqual(active?["version"] as? Int, 2)
            let quarantined = try quarantineFiles(nextTo: cacheURL)
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertEqual(try Data(contentsOf: quarantined[0]), originalBytes)
        }
    }

    func testUnknownFormatIsQuarantinedAndRebuilt() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let url = directory.appendingPathComponent("track.mp3")
            try Data("audio".utf8).write(to: url)

            // Create corrupted/unknown format
            let corruptedCache = Data("not valid json".utf8)
            try corruptedCache.write(to: cacheURL, options: .atomic)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)

            let metadata = AudioMetadata(
                title: "New Song",
                artist: "New Artist",
                album: "New Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
            await cache.storeBasicMetadata(metadata, for: url)
            await cache.flushForTesting()

            let active = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
            XCTAssertEqual(active?["version"] as? Int, 2)
            let quarantined = try quarantineFiles(nextTo: cacheURL)
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertEqual(try Data(contentsOf: quarantined[0]), corruptedCache)
        }
    }

    func testClearPersistenceReplacesFutureVersion() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let futureCache = """
            {
                "version": 999,
                "futureField": "must-preserve"
            }
            """
            let originalBytes = Data(futureCache.utf8)
            try originalBytes.write(to: cacheURL, options: .atomic)

            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let result = await cache.clearPersistence()

            guard case .success(let report) = result else {
                return XCTFail("Expected clear to succeed")
            }
            XCTAssertEqual(report.quarantinedFileCount, 0, "Load already quarantines a readable future file")
            let active = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
            XCTAssertEqual(active?["version"] as? Int, 2)
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantineFiles(nextTo: cacheURL).first)), originalBytes)
        }
    }

    func testSameSizeAndMtimeWithDifferentInodeInvalidatesMetadata() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let cache = MetadataCache(cacheFileURLOverride: cacheURL)
            let url = directory.appendingPathComponent("track.mp3")
            let stored = FileValidationSnapshot(exists: true, fileSize: 100, mtimeNs: 200, inode: 1)
            let replaced = FileValidationSnapshot(exists: true, fileSize: 100, mtimeNs: 200, inode: 2)
            let metadata = AudioMetadata(
                title: "Original",
                artist: "Artist",
                album: "Album",
                year: "2025",
                genre: "Pop",
                artwork: nil
            )

            await cache.storeBasicMetadata(metadata, for: url, snapshot: stored)
            let result = await cache.cachedMetadataIfValid(for: url, snapshot: replaced)
            XCTAssertNil(result)
        }
    }

    func testEntryLimitPrunesToLowWatermark() async throws {
        try await withTemporaryCache { cacheURL, directory in
            let limits = DerivedCacheLimits(maximumEntries: 3, lowWatermark: 2, maximumFileBytes: 16_384)
            let cache = MetadataCache(
                cacheFileURLOverride: cacheURL,
                limits: limits,
                now: { Date(timeIntervalSince1970: 1_000) }
            )
            let snapshot = FileValidationSnapshot(exists: true, fileSize: 1, mtimeNs: 2, inode: 3)
            for index in 0..<4 {
                let metadata = AudioMetadata(
                    title: "Song \(index)", artist: "Artist", album: "Album",
                    year: nil, genre: nil, artwork: nil
                )
                await cache.storeBasicMetadata(
                    metadata,
                    for: directory.appendingPathComponent("track\(index).mp3"),
                    snapshot: snapshot
                )
            }
            let result = await cache.flushPersistence()
            guard case .success(let report) = result else {
                return XCTFail("Expected flush to succeed")
            }
            XCTAssertEqual(report.entryCount, 2)
            XCTAssertGreaterThanOrEqual(report.prunedEntryCount, 2)
        }
    }

    func testOversizedCacheIsQuarantinedWithFiniteRetention() async throws {
        try await withTemporaryCache { cacheURL, _ in
            let limits = DerivedCacheLimits(maximumEntries: 3, lowWatermark: 2, maximumFileBytes: 1_024)
            try Data(repeating: 0x41, count: 2_048).write(to: cacheURL)
            let original = try Data(contentsOf: cacheURL)
            let cache = MetadataCache(cacheFileURLOverride: cacheURL, limits: limits)

            _ = await cache.flushPersistence()

            let quarantined = try quarantineFiles(nextTo: cacheURL)
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertEqual(try Data(contentsOf: quarantined[0]), original)
            let active = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
            XCTAssertEqual(active?["version"] as? Int, 2)
        }
    }

    func testDerivedBackendPersistsPerKeyAndInvalidatesReplacedFile() async throws {
        try await withTemporaryDerivedCache { directory, store, legacyURL in
            let url = directory.appendingPathComponent("derived-track.mp3")
            try Data("original".utf8).write(to: url)
            let snapshot = FileValidationSnapshot.load(for: url)
            let metadata = AudioMetadata(
                title: "SQLite Song",
                artist: "SQLite Artist",
                album: "SQLite Album",
                year: "2026",
                genre: "Pop",
                artwork: nil
            )
            let writer = MetadataCache(
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )

            await writer.storeBasicMetadata(metadata, for: url, snapshot: snapshot)
            guard case .success(let flush) = await writer.flushPersistence() else {
                return XCTFail("Expected the SQLite metadata write to flush")
            }
            XCTAssertTrue(flush.wroteFile)
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 1)

            let reader = MetadataCache(
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )
            let loaded = await reader.cachedMetadataIfValid(for: url, snapshot: snapshot)
            XCTAssertEqual(loaded?.title, metadata.title)
            XCTAssertEqual(loaded?.artist, metadata.artist)
            XCTAssertEqual(loaded?.year, metadata.year)

            let replacement = FileValidationSnapshot(
                exists: true,
                fileSize: snapshot.fileSize + 1,
                mtimeNs: snapshot.mtimeNs,
                inode: snapshot.inode
            )
            let replacedFileMetadata = await reader.cachedMetadataIfValid(
                for: url,
                snapshot: replacement
            )
            XCTAssertNil(replacedFileMetadata)
            _ = await reader.flushPersistence()
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 0)
        }
    }

    func testDerivedBackendTouchIsThrottledAndDurable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-metadata-derived-touch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(1_000)
        let store = try DerivedCacheStore(
            databaseURL: directory.appendingPathComponent("derived.sqlite3"),
            limits: .init(
                maximumPendingOperations: 32,
                writeDelay: 60,
                accessRefreshInterval: 10
            ),
            now: { clock.value }
        )
        let legacyURL = directory.appendingPathComponent("missing-legacy.json")
        let url = directory.appendingPathComponent("touch.mp3")
        try Data("touch".utf8).write(to: url)
        let snapshot = FileValidationSnapshot.load(for: url)
        let cache = MetadataCache(
            now: { Date(timeIntervalSince1970: clock.value) },
            derivedStoreOverride: store,
            legacyMigrationURLOverride: legacyURL
        )
        await cache.storeBasicMetadata(
            AudioMetadata(
                title: "Touch", artist: "Artist", album: "Album",
                year: nil, genre: nil, artwork: nil
            ),
            for: url,
            snapshot: snapshot
        )
        _ = await cache.flushPersistence()

        clock.value = 1_005
        let beforeRefreshInterval = await cache.cachedMetadataIfValid(
            for: url,
            snapshot: snapshot
        )
        XCTAssertNotNil(beforeRefreshInterval)
        XCTAssertFalse(try store.flush().get().wroteDatabase)

        clock.value = 1_011
        let afterRefreshInterval = await cache.cachedMetadataIfValid(
            for: url,
            snapshot: snapshot
        )
        XCTAssertNotNil(afterRefreshInterval)
        _ = await cache.flushPersistence()
        let record = store.record(
            kind: .metadata,
            key: MetadataCache.key(for: url),
            variant: MetadataCache.derivedVariant,
            touch: false
        )
        XCTAssertEqual(record?.lastAccessedAt, 1_011)
    }

    func testDerivedClearIsDurableAndAdvancesGeneration() async throws {
        try await withTemporaryDerivedCache { directory, store, legacyURL in
            let url = directory.appendingPathComponent("clear.mp3")
            try Data("clear".utf8).write(to: url)
            let snapshot = FileValidationSnapshot.load(for: url)
            let cache = MetadataCache(
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )
            await cache.storeBasicMetadata(
                AudioMetadata(
                    title: "Clear", artist: "Artist", album: "Album",
                    year: nil, genre: nil, artwork: nil
                ),
                for: url,
                snapshot: snapshot
            )
            _ = await cache.flushPersistence()
            let generation = store.generation(for: .metadata)

            guard case .success(let report) = await cache.clearPersistence() else {
                return XCTFail("Expected SQLite metadata clear to succeed")
            }
            XCTAssertEqual(report.removedEntryCount, 1)
            XCTAssertEqual(report.quarantinedFileCount, 0)
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 0)
            XCTAssertEqual(store.generation(for: .metadata), generation + 1)
            let metadataAfterClear = await cache.cachedMetadataIfValid(
                for: url,
                snapshot: snapshot
            )
            XCTAssertNil(metadataAfterClear)
        }
    }

    func testCurrentLegacyJSONMigratesOnceIntoDerivedStore() async throws {
        try await withTemporaryDerivedCache { directory, store, legacyURL in
            let url = directory.appendingPathComponent("migrated.mp3")
            try Data("migration-source".utf8).write(to: url)
            let snapshot = FileValidationSnapshot.load(for: url)
            let legacyObject: [String: Any] = [
                "version": 2,
                "entries": [
                    MetadataCache.key(for: url): [
                        "title": "Migrated Song",
                        "artist": "Migrated Artist",
                        "album": "Migrated Album",
                        "year": "2026",
                        "genre": "Pop",
                        "fileSize": snapshot.fileSize,
                        "mtimeNs": snapshot.mtimeNs,
                        "inode": snapshot.inode.map { $0 as Any } ?? NSNull(),
                        "lastAccessedAt": 1_000
                    ]
                ]
            ]
            try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL)
            let cache = MetadataCache(
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )

            let migrated = await cache.cachedMetadataIfValid(for: url, snapshot: snapshot)
            XCTAssertEqual(migrated?.title, "Migrated Song")
            XCTAssertEqual(migrated?.artist, "Migrated Artist")
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 1)
            XCTAssertNotNil(
                store.migrationMarker(for: MetadataCache.derivedMigrationMarkerKey)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

            let reader = MetadataCache(
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )
            let reloaded = await reader.cachedMetadataIfValid(
                for: url,
                snapshot: snapshot
            )
            XCTAssertEqual(reloaded?.album, "Migrated Album")
        }
    }

    func testFutureLegacyJSONIsPreservedDuringDerivedMigration() async throws {
        try await withTemporaryDerivedCache { directory, store, legacyURL in
            let future = Data(#"{"version":999,"future":"preserve"}"#.utf8)
            try future.write(to: legacyURL)
            let url = directory.appendingPathComponent("future.mp3")
            let cache = MetadataCache(
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )

            let result = await cache.cachedMetadataIfValid(
                for: url,
                snapshot: .missing
            )
            XCTAssertNil(result)
            XCTAssertEqual(try Data(contentsOf: legacyURL), future)
            XCTAssertNil(
                store.migrationMarker(for: MetadataCache.derivedMigrationMarkerKey)
            )
        }
    }

    func testOversizedLegacyJSONIsNotLoadedByDerivedMigration() async throws {
        try await withTemporaryDerivedCache { directory, store, legacyURL in
            let oversized = Data(repeating: 0x41, count: 2_048)
            try oversized.write(to: legacyURL)
            let cache = MetadataCache(
                limits: DerivedCacheLimits(
                    maximumEntries: 3,
                    lowWatermark: 2,
                    maximumFileBytes: 1_024
                ),
                derivedStoreOverride: store,
                legacyMigrationURLOverride: legacyURL
            )

            let result = await cache.cachedMetadataIfValid(
                for: directory.appendingPathComponent("missing.mp3"),
                snapshot: .missing
            )
            XCTAssertNil(result)
            XCTAssertEqual(try Data(contentsOf: legacyURL), oversized)
            XCTAssertNil(
                store.migrationMarker(for: MetadataCache.derivedMigrationMarkerKey)
            )
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 0)
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

    private func withTemporaryDerivedCache(
        _ body: (URL, DerivedCacheStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-metadata-derived-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DerivedCacheStore(
            databaseURL: directory.appendingPathComponent("derived.sqlite3"),
            limits: .init(maximumPendingOperations: 32, writeDelay: 60)
        )
        let legacyURL = directory.appendingPathComponent("metadata-cache.json")
        try await body(directory, store, legacyURL)
    }

    private func quarantineFiles(nextTo cacheURL: URL) throws -> [URL] {
        let directory = cacheURL.deletingLastPathComponent().appendingPathComponent(
            DerivedCacheFileIO.quarantineDirectoryName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
