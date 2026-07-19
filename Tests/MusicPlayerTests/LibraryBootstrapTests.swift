import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MusicPlayer

final class LibraryBootstrapTests: XCTestCase {
    private struct QueueDefaultsReceiptPayload: Encodable {
        let version = 1
        let paths: [String]
        let currentIndex: Int
    }

    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
            "MusicPlayer-LibraryBootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "library-bootstrap-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suite)
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMigratesCompleteLegacyImageAndNeverReimportsStaleFiles() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        let playlistID = UUID()
        let trackID = UUID()
        try writeJSON(
            [
                "version": 2,
                "tracks": [
                    ["path": "/Music/A.mp3"],
                    ["path": "/Music/A.mp3"],
                ],
                "paths": [],
                "currentIndex": 1,
                "pendingWeightRekeys": [],
            ],
            named: "playlist.json",
            environment: environment
        )
        try writeJSON(
            [
                "version": 2,
                "storeRevision": 4,
                "playlists": [[
                    "id": playlistID.uuidString,
                    "name": "收藏",
                    "tracks": [[
                        "id": trackID.uuidString,
                        "path": "/Music/A.mp3",
                    ]],
                    "createdAt": 0,
                    "updatedAt": 1,
                ]],
                "pendingCleanup": [],
            ],
            named: "user-playlists.json",
            environment: environment
        )
        try writeJSON(
            [
                "version": 3,
                "queueLevels": ["/Music/A.mp3": 2],
                "playlistLevels": [playlistID.uuidString: ["/Music/A.mp3": 5]],
            ],
            named: "playback-weights.json",
            environment: environment
        )
        let playbackData = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "state": ["filePath": "/Music/A.mp3", "lastPlayedTime": 12.5],
        ])
        defaults.set(playbackData, forKey: PlaybackStateStore.envelopeKey)
        let preferencesData = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "preferences": [
                "volume": 0.5,
                "playbackRate": 1,
                "playbackMode": "shuffle",
                "playbackScope": [
                    "kind": "playlist",
                    "playlistID": playlistID.uuidString,
                ],
            ],
        ])
        defaults.set(preferencesData, forKey: AppPreferencesStore.envelopeKey)

        let first = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(first.database)
        XCTAssertTrue(first.migratedLegacyData)
        let queue = try database.loadQueue()
        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertNotEqual(queue.entries[0].id, queue.entries[1].id)
        XCTAssertEqual(queue.currentEntryID, queue.entries[1].id)
        XCTAssertEqual(try database.loadPlaylists().playlists.first?.tracks.first?.id, trackID)
        XCTAssertEqual(try database.loadWeights().playlistLevels[playlistID]?.values.first, 5)
        XCTAssertEqual(try database.loadPlaybackSession()?.scope, .playlist)
        XCTAssertEqual(try database.loadPlaybackSession()?.positionMilliseconds, 12_500)
        XCTAssertTrue(try database.hasImportedSource("playback-state-v1"))
        XCTAssertTrue(try database.hasImportedSource("app-preferences"))
        XCTAssertFalse(try database.hasImportedSource("playback-session-v1"))
        database.close()

        // A stale legacy edit after authority switch must never be imported.
        try writeJSON(
            ["version": 2, "tracks": [], "paths": [], "currentIndex": 0],
            named: "playlist.json",
            environment: environment
        )
        let reopened = LibraryBootstrap.open(environment: environment)
        XCTAssertFalse(reopened.migratedLegacyData)
        XCTAssertEqual(try XCTUnwrap(reopened.database).loadQueue().entries.count, 2)
    }

    func testScatteredLegacyPlaybackScopeMigratesIntoDatabaseSession() throws {
        let environment = makeEnvironment()
        let playlistID = UUID()
        let trackID = UUID()
        try seedLegacySessionFixture(
            environment: environment,
            playlistID: playlistID,
            trackID: trackID
        )
        defaults.set("playlist", forKey: AppPreferencesStore.LegacyKey.scopeKind)
        defaults.set(
            playlistID.uuidString,
            forKey: AppPreferencesStore.LegacyKey.scopePlaylistID
        )

        let result = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(result.database)
        defer { database.close() }
        let session = try XCTUnwrap(database.loadPlaybackSession())

        XCTAssertEqual(session.scope, .playlist)
        XCTAssertEqual(session.playlistID, playlistID)
        XCTAssertEqual(session.scopeTrackID, trackID)
        XCTAssertEqual(session.positionMilliseconds, 8_500)
        XCTAssertTrue(try database.hasImportedSource("playback-state-v1"))
        XCTAssertTrue(try database.hasImportedSource("playback-scope-defaults"))
        XCTAssertEqual(
            defaults.string(forKey: AppPreferencesStore.LegacyKey.scopeKind),
            "playlist"
        )
    }

    func testV2PreferencesSuppressStaleScatteredPlaybackScope() throws {
        let environment = makeEnvironment()
        let playlistID = UUID()
        try seedLegacySessionFixture(
            environment: environment,
            playlistID: playlistID,
            trackID: UUID()
        )
        defaults.set("playlist", forKey: AppPreferencesStore.LegacyKey.scopeKind)
        defaults.set(
            playlistID.uuidString,
            forKey: AppPreferencesStore.LegacyKey.scopePlaylistID
        )
        let v2 = try JSONSerialization.data(withJSONObject: [
            "version": AppPreferencesStore.formatVersion,
            "preferences": [
                "volume": 0.5,
                "playbackRate": 1.0,
                "playbackMode": "shuffle",
                "normalizationEnabled": true,
                "immersiveEnabled": false,
                "analyzeDuringPlayback": false,
                "autoPreanalyze": true,
                "targetLUFS": -16.0,
                "immersiveFadeDuration": 0.6,
                "requireAnalysisBeforeTransition": false,
                "scanSubfolders": true,
                "notifyOnDeviceSwitch": true,
                "notifyDeviceSwitchSilent": true,
                "colorSchemeOverride": 0,
                "playlistPanelMode": 0,
                "compactRootPane": 0,
                "ipcDebugEnabled": false,
                "playbackScope": [
                    "kind": "playlist",
                    "playlistID": playlistID.uuidString,
                ],
            ],
        ])
        defaults.set(v2, forKey: AppPreferencesStore.envelopeKey)

        let result = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(result.database)
        defer { database.close() }

        XCTAssertEqual(try database.loadPlaybackSession()?.scope, .queue)
        XCTAssertTrue(try database.hasImportedSource("app-preferences"))
        XCTAssertFalse(try database.hasImportedSource("playback-scope-defaults"))
    }

    func testCorruptPreferencesUsesScatteredScopeWithIndependentReceipts() throws {
        let environment = makeEnvironment()
        let playlistID = UUID()
        try seedLegacySessionFixture(
            environment: environment,
            playlistID: playlistID,
            trackID: UUID()
        )
        defaults.set("playlist", forKey: AppPreferencesStore.LegacyKey.scopeKind)
        defaults.set(
            playlistID.uuidString,
            forKey: AppPreferencesStore.LegacyKey.scopePlaylistID
        )
        let corruptV2 = try JSONSerialization.data(withJSONObject: [
            "version": AppPreferencesStore.formatVersion,
            "preferences": ["volume": "not-a-number"],
        ])
        defaults.set(corruptV2, forKey: AppPreferencesStore.envelopeKey)

        let result = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(result.database)
        defer { database.close() }

        XCTAssertEqual(try database.loadPlaybackSession()?.scope, .playlist)
        XCTAssertTrue(try database.hasImportedSource("playback-state-v1"))
        XCTAssertTrue(try database.hasImportedSource("app-preferences"))
        XCTAssertTrue(try database.hasImportedSource("playback-scope-defaults"))
    }

    func testOversizedPreferencesEnvelopeFailsClosedIndependently() {
        let environment = makeEnvironment()
        defaults.set(
            Data(repeating: 0xA5, count: 64 * 1_024 + 1),
            forKey: AppPreferencesStore.envelopeKey
        )

        let result = LibraryBootstrap.open(environment: environment)

        XCTAssertNil(result.database)
        XCTAssertEqual(result.legacyFallbackIssue, .sourceOversized("app-preferences"))
    }

    func testFuturePreferencesEnvelopeFailsClosedWithoutPlaybackState() throws {
        let environment = makeEnvironment()
        let future = try JSONSerialization.data(withJSONObject: [
            "version": AppPreferencesStore.formatVersion + 1,
            "preferences": ["future": true],
        ])
        defaults.set(future, forKey: AppPreferencesStore.envelopeKey)

        let result = LibraryBootstrap.open(environment: environment)

        XCTAssertNil(result.database)
        XCTAssertEqual(
            result.legacyFallbackIssue,
            .sourceFuture(
                name: "app-preferences",
                version: AppPreferencesStore.formatVersion + 1
            )
        )
    }

    func testFutureLegacySourceKeepsLegacyAuthorityAndCreatesNoFinalDatabase() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        try writeJSON(
            ["version": 99, "tracks": [], "paths": [], "currentIndex": 0],
            named: "playlist.json",
            environment: environment
        )

        let result = LibraryBootstrap.open(environment: environment)
        XCTAssertNil(result.database)
        XCTAssertEqual(
            result.legacyFallbackIssue,
            .sourceFuture(name: "queue-v2", version: 99)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.applicationSupportURL
                    .appendingPathComponent(LibraryBootstrap.databaseFileName).path
            )
        )
    }

    func testHugeFinitePlaybackTimeClampsToInt64MaxWithoutTrap() throws {
        let environment = makeEnvironment()
        let playback = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "state": [
                "filePath": "/Music/Huge.mp3",
                "lastPlayedTime": Double.greatestFiniteMagnitude,
            ],
        ])
        defaults.set(playback, forKey: PlaybackStateStore.envelopeKey)

        let result = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(result.database)
        defer { database.close() }

        XCTAssertEqual(
            try database.loadPlaybackSession()?.positionMilliseconds,
            Int64.max
        )
    }

    func testUserDefaultsQueueHasDeterministicCompleteReceipt() throws {
        let environment = makeEnvironment()
        let now = Date(timeIntervalSince1970: 1_234_567)
        let paths = ["/Music/A.mp3", "/Music/B.mp3"]
        defaults.set(paths, forKey: "savedPlaylistPaths")
        defaults.set(1, forKey: "savedPlaylistIndex")

        let result = LibraryBootstrap.open(environment: environment, now: now)
        let database = try XCTUnwrap(result.database)
        defer { database.close() }
        let receipt = try XCTUnwrap(
            migrationReceipt(named: "queue-defaults", at: database.fileURL)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedData = try encoder.encode(
            QueueDefaultsReceiptPayload(paths: paths, currentIndex: 1)
        )

        XCTAssertEqual(receipt.sourceVersion, 1)
        XCTAssertEqual(receipt.byteCount, expectedData.count)
        XCTAssertEqual(receipt.modificationTimeNanoseconds, 0)
        XCTAssertEqual(receipt.digest, sha256Hex(expectedData))
        XCTAssertEqual(receipt.importedAt, now)
        XCTAssertTrue(try database.hasImportedSource("queue-defaults"))
    }

    func testInterruptedImportArtifactIsRebuiltDeterministically() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        let queueData: [String: Any] = [
            "version": 2,
            "tracks": [["path": "/Music/A.mp3"]],
            "paths": [],
            "currentIndex": 0,
        ]
        try writeJSON(queueData, named: "playlist.json", environment: environment)
        let importing = environment.applicationSupportURL.appendingPathComponent(
            LibraryBootstrap.databaseFileName + ".importing"
        )
        try Data("partial".utf8).write(to: importing)

        let first = LibraryBootstrap.open(environment: environment)
        let firstID = try XCTUnwrap(first.database).loadQueue().entries.first?.id
        first.database?.close()
        try FileManager.default.removeItem(
            at: environment.applicationSupportURL.appendingPathComponent(
                LibraryBootstrap.databaseFileName
            )
        )
        let second = LibraryBootstrap.open(environment: environment)
        let secondID = try XCTUnwrap(second.database).loadQueue().entries.first?.id
        XCTAssertEqual(firstID, secondID)
    }

    func testNoLegacyDataCreatesHealthyEmptyAuthority() throws {
        let result = LibraryBootstrap.open(environment: makeEnvironment())
        let database = try XCTUnwrap(result.database)
        XCTAssertFalse(result.migratedLegacyData)
        XCTAssertTrue(try database.quickCheck())
        XCTAssertTrue(try database.loadQueue().entries.isEmpty)
        XCTAssertTrue(try database.loadPlaylists().playlists.isEmpty)
    }

    func testZeroByteAuthorityIsProtectedWithoutLegacyFallback() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        let finalURL = environment.applicationSupportURL.appendingPathComponent(
            LibraryBootstrap.databaseFileName
        )
        try Data().write(to: finalURL)

        let result = LibraryBootstrap.open(environment: environment)

        XCTAssertNil(result.database)
        XCTAssertEqual(result.legacyFallbackIssue, .sourceCorrupt("Library.sqlite"))
        XCTAssertEqual(try Data(contentsOf: finalURL), Data())
    }

    func testExistingAuthorityForeignKeyViolationIsProtectedOnReopen() throws {
        let environment = makeEnvironment()
        let initial = LibraryBootstrap.open(environment: environment)
        let finalURL = try XCTUnwrap(initial.database).fileURL
        initial.database?.close()

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(finalURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA foreign_keys=OFF", nil, nil, nil), SQLITE_OK)
        let insert = """
        INSERT INTO queue_entries(
            entry_id, sort_key, path, path_key, location_id, relative_path
        ) VALUES(
            '\(UUID().uuidString)', 0, '/Music/FK.mp3', '/Music/FK.mp3',
            '\(UUID().uuidString)', 'FK.mp3'
        )
        """
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close_v2(database), SQLITE_OK)
        raw = nil

        let reopened = LibraryBootstrap.open(environment: environment)

        XCTAssertNil(reopened.database)
        XCTAssertEqual(reopened.legacyFallbackIssue, .sourceCorrupt("Library.sqlite"))
    }

    func testAuthorityDirectorySyncFailureStaysProtectedAndRetriesOnNextOpen() throws {
        let environment = makeEnvironment()

        let first = LibraryBootstrap.open(
            environment: environment,
            directorySyncOverride: { _ in EIO }
        )

        XCTAssertNil(first.database)
        XCTAssertEqual(first.legacyFallbackIssue, .authoritySwitchFailed(EIO))
        let second = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(second.database)
        XCTAssertTrue(try database.quickCheck())
        database.close()
    }

    func testOrphanJournalFamilyMembersAreRemovedBeforeAuthorityCreation() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        let finalURL = environment.applicationSupportURL.appendingPathComponent(
            LibraryBootstrap.databaseFileName
        )
        let orphanJournal = URL(fileURLWithPath: finalURL.path + "-journal")
        let importingJournal = URL(fileURLWithPath: finalURL.path + ".importing-journal")
        try Data("orphan".utf8).write(to: orphanJournal)
        try Data("partial".utf8).write(to: importingJournal)

        let result = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(result.database)
        database.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanJournal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: importingJournal.path))
    }

    func testStartupResumesManifestAndArchivesCompleteSQLiteFamily() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        let directory = environment.applicationSupportURL
        let finalURL = directory.appendingPathComponent(LibraryBootstrap.databaseFileName)
        let diagnosticURL = directory.appendingPathComponent(
            "Library.corrupted.fixture.sqlite"
        )
        let family: [(suffix: String, data: Data)] = [
            ("", Data("corrupt-main".utf8)),
            ("-wal", Data("corrupt-wal".utf8)),
            ("-shm", Data("corrupt-shm".utf8)),
            ("-journal", Data("corrupt-journal".utf8)),
        ]
        for member in family {
            try member.data.write(to: URL(fileURLWithPath: finalURL.path + member.suffix))
        }
        try FileManager.default.moveItem(at: finalURL, to: diagnosticURL)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "diagnosticFileName": diagnosticURL.lastPathComponent,
            "phase": "archiving",
        ], options: [.sortedKeys])
        try manifest.write(
            to: directory.appendingPathComponent(LibraryBootstrap.recoveryManifestFileName)
        )

        let result = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(result.database)
        XCTAssertTrue(try database.quickCheck())
        database.close()

        for member in family {
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: diagnosticURL.path + member.suffix)),
                member.data
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    LibraryBootstrap.recoveryManifestFileName
                ).path
            )
        )
    }

    func testExplicitCorruptAuthorityRecoveryArchivesBytesAndInstallsEmptyDatabase() throws {
        let environment = makeEnvironment()
        try environment.prepareDirectories()
        let finalURL = environment.applicationSupportURL.appendingPathComponent(
            LibraryBootstrap.databaseFileName
        )
        let corrupt = Data("not-a-sqlite-database".utf8)
        try corrupt.write(to: finalURL)

        let protected = LibraryBootstrap.open(environment: environment)
        XCTAssertNil(protected.database)
        XCTAssertEqual(protected.legacyFallbackIssue, .sourceCorrupt("Library.sqlite"))
        XCTAssertEqual(try Data(contentsOf: finalURL), corrupt)

        let recovery = try LibraryBootstrap.recoverCorruptAuthorityStartingEmpty(
            environment: environment
        )
        XCTAssertEqual(try Data(contentsOf: recovery.diagnosticDatabaseURL), corrupt)

        let reopened = LibraryBootstrap.open(environment: environment)
        let database = try XCTUnwrap(reopened.database)
        XCTAssertTrue(try database.quickCheck())
        XCTAssertTrue(try database.loadQueue().entries.isEmpty)
        XCTAssertTrue(try database.loadPlaylists().playlists.isEmpty)
        database.close()
    }

    private func makeEnvironment() -> PersistenceEnvironment {
        PersistenceEnvironment(
            applicationSupportURL: root.appendingPathComponent("Application Support/MusicPlayer"),
            cachesURL: root.appendingPathComponent("Caches/MusicPlayer"),
            userDefaults: defaults,
            isTesting: true
        )
    }

    private func seedLegacySessionFixture(
        environment: PersistenceEnvironment,
        playlistID: UUID,
        trackID: UUID
    ) throws {
        try environment.prepareDirectories()
        try writeJSON(
            [
                "version": 2,
                "tracks": [["path": "/Music/Legacy.mp3"]],
                "paths": [],
                "currentIndex": 0,
                "pendingWeightRekeys": [],
            ],
            named: "playlist.json",
            environment: environment
        )
        try writeJSON(
            [
                "version": 2,
                "storeRevision": 1,
                "playlists": [[
                    "id": playlistID.uuidString,
                    "name": "旧歌单",
                    "tracks": [[
                        "id": trackID.uuidString,
                        "path": "/Music/Legacy.mp3",
                    ]],
                    "createdAt": 0,
                    "updatedAt": 1,
                ]],
                "pendingCleanup": [],
            ],
            named: "user-playlists.json",
            environment: environment
        )
        let playback = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "state": [
                "filePath": "/Music/Legacy.mp3",
                "lastPlayedTime": 8.5,
            ],
        ])
        defaults.set(playback, forKey: PlaybackStateStore.envelopeKey)
    }

    private func writeJSON(
        _ object: Any,
        named name: String,
        environment: PersistenceEnvironment
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(
            to: environment.applicationSupportURL.appendingPathComponent(name),
            options: .atomic
        )
    }

    private func migrationReceipt(
        named name: String,
        at databaseURL: URL
    ) throws -> LibraryMigrationSource? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw XCTSkip("Could not open receipt fixture database")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let sql = """
        SELECT source_version, byte_count, mtime_ns, sha256, imported_at
        FROM migration_sources WHERE source_name = ?
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw XCTSkip("Could not prepare receipt fixture query")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawDigest = sqlite3_column_text(statement, 3) else { return nil }
        let sourceVersion = sqlite3_column_type(statement, 0) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, 0))
        return LibraryMigrationSource(
            name: name,
            sourceVersion: sourceVersion,
            byteCount: Int(sqlite3_column_int64(statement, 1)),
            modificationTimeNanoseconds: sqlite3_column_int64(statement, 2),
            digest: String(cString: rawDigest),
            importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
