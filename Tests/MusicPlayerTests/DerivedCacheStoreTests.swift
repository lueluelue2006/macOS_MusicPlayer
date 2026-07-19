import XCTest
@testable import MusicPlayer

final class DerivedCacheStoreTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var value: TimeInterval

        init(_ value: TimeInterval) {
            self.value = value
        }
    }

    func testDefaultURLUsesCachesDirectory() throws {
        let fileManager = FileManager.default
        let expectedRoot = try XCTUnwrap(
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let url = try XCTUnwrap(DerivedCacheStore.defaultDatabaseURL(fileManager: fileManager))

        XCTAssertTrue(url.path.hasPrefix(expectedRoot.path + "/"))
        XCTAssertEqual(url.lastPathComponent, "derived-cache.sqlite3")
        XCTAssertFalse(url.path.contains("Application Support"))
    }

    func testBatchedRecordsAndMigrationMarkerPersistAcrossInstances() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("derived.sqlite3")
            let clock = Clock(1_000)
            let identity = DerivedCacheStore.FileIdentity(
                fileSize: 100,
                modificationTimeNanoseconds: 200,
                fileIdentifier: 300
            )
            let records = DerivedCacheStore.CacheKind.allCases.enumerated().map { index, kind in
                DerivedCacheStore.Record(
                    kind: kind,
                    key: "/music/track-\(index).mp3",
                    variant: "v1",
                    payload: Data("payload-\(index)".utf8),
                    fileIdentity: identity,
                    updatedAt: clock.value,
                    lastAccessedAt: clock.value
                )
            }
            let marker = DerivedCacheStore.MigrationMarker(
                key: "legacy-json-v1",
                sourceFingerprint: "sha256:fixture",
                completedAt: clock.value
            )

            do {
                let store = try DerivedCacheStore(
                    databaseURL: databaseURL,
                    limits: limits(writeDelay: 60),
                    now: { clock.value }
                )
                let enqueue = store.enqueue(
                    records.map { .upsert($0) },
                    migrationMarkers: [marker]
                )
                XCTAssertEqual(
                    try enqueue.get(),
                    .init(acceptedMutationCount: 3, acceptedMigrationMarkerCount: 1)
                )
                let flush = try store.flush().get()
                XCTAssertTrue(flush.wroteDatabase)
                XCTAssertEqual(flush.appliedMutationCount, 3)
                XCTAssertEqual(flush.appliedMigrationMarkerCount, 1)
            }

            let reader = try DerivedCacheStore(
                databaseURL: databaseURL,
                limits: limits(writeDelay: 60),
                now: { clock.value }
            )
            for record in records {
                XCTAssertEqual(
                    reader.record(
                        kind: record.kind,
                        key: record.key,
                        variant: record.variant,
                        matching: identity,
                        touch: false
                    ),
                    record
                )
            }
            XCTAssertEqual(reader.migrationMarker(for: marker.key), marker)
        }
    }

    func testIdentityMismatchDeletesStaleRecordOnFlush() throws {
        try withTemporaryDirectory { directory in
            let store = try DerivedCacheStore(
                databaseURL: directory.appendingPathComponent("derived.sqlite3"),
                limits: limits(writeDelay: 60)
            )
            let record = makeRecord(kind: .duration, key: "track", order: 1)
            _ = try store.enqueue([.upsert(record)]).get()
            _ = try store.flush().get()

            let replacement = DerivedCacheStore.FileIdentity(
                fileSize: record.fileIdentity.fileSize + 1,
                modificationTimeNanoseconds: record.fileIdentity.modificationTimeNanoseconds,
                fileIdentifier: record.fileIdentity.fileIdentifier
            )
            XCTAssertNil(
                store.record(
                    kind: .duration,
                    key: record.key,
                    variant: record.variant,
                    matching: replacement
                )
            )
            _ = try store.flush().get()
            XCTAssertEqual(store.persistedEntryCount(for: .duration), 0)
        }
    }

    func testLastAccessTouchIsIncrementalAndDurable() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("derived.sqlite3")
            let clock = Clock(1_000)
            let store = try DerivedCacheStore(
                databaseURL: databaseURL,
                limits: limits(writeDelay: 60, accessRefreshInterval: 10),
                now: { clock.value }
            )
            let original = makeRecord(kind: .metadata, key: "touch", order: 1, timestamp: clock.value)
            _ = try store.enqueue([.upsert(original)]).get()
            _ = try store.flush().get()

            clock.value = 1_011
            let touched = try XCTUnwrap(
                store.record(kind: .metadata, key: original.key, variant: original.variant)
            )
            XCTAssertEqual(touched.lastAccessedAt, 1_011)
            let flush = try store.flush().get()
            XCTAssertEqual(flush.appliedMutationCount, 1)

            let reader = try DerivedCacheStore(
                databaseURL: databaseURL,
                limits: limits(writeDelay: 60),
                now: { clock.value }
            )
            XCTAssertEqual(
                reader.record(
                    kind: .metadata,
                    key: original.key,
                    variant: original.variant,
                    touch: false
                )?.lastAccessedAt,
                1_011
            )
        }
    }

    func testCapacityPrunesToLowWatermark() throws {
        try withTemporaryDirectory { directory in
            let tableLimit = DerivedCacheStore.TableLimit(maximumEntries: 3, lowWatermark: 2)
            let store = try DerivedCacheStore(
                databaseURL: directory.appendingPathComponent("derived.sqlite3"),
                limits: .init(
                    metadata: tableLimit,
                    duration: tableLimit,
                    immersive: tableLimit,
                    maximumPendingOperations: 32,
                    writeDelay: 60
                )
            )
            let records = (0..<4).map {
                makeRecord(kind: .immersive, key: "track-\($0)", order: $0)
            }
            _ = try store.enqueue(records.map { .upsert($0) }).get()
            let report = try store.flush().get()

            XCTAssertEqual(report.prunedEntryCount, 2)
            XCTAssertEqual(store.persistedEntryCount(for: .immersive), 2)
            XCTAssertNil(store.record(kind: .immersive, key: "track-0", variant: "v1", touch: false))
            XCTAssertNil(store.record(kind: .immersive, key: "track-1", variant: "v1", touch: false))
            XCTAssertNotNil(store.record(kind: .immersive, key: "track-2", variant: "v1", touch: false))
            XCTAssertNotNil(store.record(kind: .immersive, key: "track-3", variant: "v1", touch: false))
        }
    }

    func testLargeBatchDrainsIncrementallyWithoutLosingRows() throws {
        try withTemporaryDirectory { directory in
            let store = try DerivedCacheStore(
                databaseURL: directory.appendingPathComponent("derived.sqlite3"),
                limits: .init(maximumPendingOperations: 2, writeDelay: 60)
            )
            let records = (0..<7).map {
                makeRecord(kind: .duration, key: "batch-\($0)", order: $0)
            }

            let enqueue = try store.enqueue(records.map { .upsert($0) }).get()
            XCTAssertEqual(enqueue.acceptedMutationCount, records.count)
            _ = try store.flush().get()
            XCTAssertEqual(store.persistedEntryCount(for: .duration), records.count)
        }
    }

    func testBoundsRejectWholeBatchWithoutPartialEnqueue() throws {
        try withTemporaryDirectory { directory in
            let store = try DerivedCacheStore(
                databaseURL: directory.appendingPathComponent("derived.sqlite3"),
                limits: .init(maximumKeyBytes: 8, maximumPayloadBytes: 4, writeDelay: 60)
            )
            let valid = makeRecord(kind: .metadata, key: "valid", order: 1)
            let oversized = DerivedCacheStore.Record(
                kind: .duration,
                key: "also-ok",
                variant: "",
                payload: Data(repeating: 1, count: 5),
                fileIdentity: valid.fileIdentity,
                updatedAt: 1,
                lastAccessedAt: 1
            )

            XCTAssertEqual(
                store.enqueue([.upsert(valid), .upsert(oversized)]),
                .failure(.payloadTooLarge(maximumBytes: 4))
            )
            XCTAssertFalse(try store.flush().get().wroteDatabase)
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 0)
            XCTAssertEqual(store.persistedEntryCount(for: .duration), 0)
        }
    }

    func testClearAdvancesGenerationAndRejectsLateWrite() throws {
        try withTemporaryDirectory { directory in
            let store = try DerivedCacheStore(
                databaseURL: directory.appendingPathComponent("derived.sqlite3"),
                limits: limits(writeDelay: 60)
            )
            let generation = store.generation(for: .metadata)
            let record = makeRecord(kind: .metadata, key: "late", order: 1)
            _ = try store.enqueue([.upsert(record, expectedGeneration: generation)]).get()

            let clear = try store.clear(.metadata).get()
            XCTAssertEqual(clear.removedEntryCount, 1)
            XCTAssertEqual(store.persistedEntryCount(for: .metadata), 0)
            let nextGeneration = store.generation(for: .metadata)
            XCTAssertEqual(nextGeneration, generation + 1)
            XCTAssertEqual(
                store.enqueue([.upsert(record, expectedGeneration: generation)]),
                .failure(
                    .staleGeneration(
                        kind: .metadata,
                        expected: generation,
                        actual: nextGeneration
                    )
                )
            )
        }
    }

    func testFutureDatabaseIsReadOnlyAndPreserved() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("future.sqlite3")
            let seed = try SQLiteDatabase(fileURL: databaseURL)
            try seed.execute("PRAGMA application_id = \(DerivedCacheStore.applicationID)")
            try seed.execute("PRAGMA user_version = 99")
            try seed.checkpoint()
            seed.close()
            let original = try Data(contentsOf: databaseURL)

            let store = try DerivedCacheStore(
                databaseURL: databaseURL,
                limits: limits(writeDelay: 60)
            )
            XCTAssertEqual(store.accessMode, .readOnlyFuture(schemaVersion: 99))
            let record = makeRecord(kind: .duration, key: "future", order: 1)
            XCTAssertEqual(
                store.enqueue([.upsert(record)]),
                .failure(.readOnly(.readOnlyFuture(schemaVersion: 99)))
            )
            XCTAssertEqual(
                store.clear(.duration),
                .failure(.readOnly(.readOnlyFuture(schemaVersion: 99)))
            )
            XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        }
    }

    private func limits(
        writeDelay: TimeInterval,
        accessRefreshInterval: TimeInterval = 24 * 60 * 60
    ) -> DerivedCacheStore.Limits {
        .init(
            maximumPendingOperations: 32,
            writeDelay: writeDelay,
            accessRefreshInterval: accessRefreshInterval
        )
    }

    private func makeRecord(
        kind: DerivedCacheStore.CacheKind,
        key: String,
        order: Int,
        timestamp: TimeInterval? = nil
    ) -> DerivedCacheStore.Record {
        let timestamp = timestamp ?? TimeInterval(order + 1)
        return DerivedCacheStore.Record(
            kind: kind,
            key: key,
            variant: "v1",
            payload: Data("payload-\(order)".utf8),
            fileIdentity: .init(
                fileSize: Int64(order + 10),
                modificationTimeNanoseconds: Int64(order + 20),
                fileIdentifier: Int64(order + 30)
            ),
            updatedAt: timestamp,
            lastAccessedAt: timestamp
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-derived-cache-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
