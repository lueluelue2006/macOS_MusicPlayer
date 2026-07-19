import Foundation
import XCTest
@testable import MusicPlayer

final class LibraryDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MusicPlayer-LibraryDatabase-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testQueueRoundTripAndCursorUpdateTouchesOnlyState() throws {
        let database = try makeDatabase()
        let first = LibraryQueueEntry(
            id: UUID(),
            sortKey: 0,
            path: "/Music/A.mp3",
            signature: signature(path: "/Music/A.mp3"),
            locationID: nil,
            relativePath: nil
        )
        let second = LibraryQueueEntry(
            id: UUID(),
            sortKey: 1_024,
            path: "/Music/A.mp3",
            signature: signature(path: "/Music/A.mp3"),
            locationID: nil,
            relativePath: nil
        )
        let rekey = LibraryQueueRekeyIntent(
            id: UUID(),
            oldPath: "/Music/Old.mp3",
            newPath: "/Music/New.mp3",
            createdAt: Date(timeIntervalSince1970: 123)
        )
        try database.replaceQueue(
            LibraryQueueSnapshot(
                revision: 7,
                entries: [first, second],
                currentEntryID: second.id,
                pendingRekeys: [rekey]
            )
        )

        XCTAssertEqual(try database.loadQueue().entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(try database.loadQueue().currentEntryID, second.id)
        XCTAssertTrue(try database.updateQueueCursor(currentEntryID: first.id, expectedQueueRevision: 7))
        XCTAssertEqual(try database.loadQueue().currentEntryID, first.id)
        XCTAssertFalse(try database.updateQueueCursor(currentEntryID: second.id, expectedQueueRevision: 6))
        XCTAssertEqual(try database.loadQueue().currentEntryID, first.id)
        XCTAssertEqual(try database.loadQueue().pendingRekeys, [rekey])
    }

    func testReplacingQueueRollsBackWhenCursorIsInvalid() throws {
        let database = try makeDatabase()
        let entry = queueEntry(path: "/Music/Keep.mp3", sortKey: 0)
        try database.replaceQueue(
            LibraryQueueSnapshot(revision: 1, entries: [entry], currentEntryID: entry.id, pendingRekeys: [])
        )

        XCTAssertThrowsError(
            try database.replaceQueue(
                LibraryQueueSnapshot(
                    revision: 2,
                    entries: [queueEntry(path: "/Music/New.mp3", sortKey: 0)],
                    currentEntryID: UUID(),
                    pendingRekeys: []
                )
            )
        )
        XCTAssertEqual(try database.loadQueue().entries, [entry])
        XCTAssertEqual(try database.loadQueue().revision, 1)
    }

    func testQueueRevisionCASDistinguishesRetryStaleAndConflict() throws {
        let database = try makeDatabase()
        let entry = queueEntry(path: "/Music/Stored.mp3", sortKey: 0)
        let stored = LibraryQueueSnapshot(
            revision: 5,
            entries: [entry],
            currentEntryID: entry.id,
            pendingRekeys: []
        )
        try database.replaceQueue(stored)

        XCTAssertEqual(
            try database.replaceQueue(stored, expectedRevision: 4),
            .alreadyCurrent(revision: 5)
        )
        XCTAssertEqual(
            try database.replaceQueue(
                LibraryQueueSnapshot(
                    revision: 4,
                    entries: [],
                    currentEntryID: nil,
                    pendingRekeys: []
                ),
                expectedRevision: 5
            ),
            .stale(storedRevision: 5)
        )
        XCTAssertEqual(
            try database.replaceQueue(
                LibraryQueueSnapshot(
                    revision: 5,
                    entries: [],
                    currentEntryID: nil,
                    pendingRekeys: []
                ),
                expectedRevision: 5
            ),
            .conflict(revision: 5)
        )
        let replacement = LibraryQueueSnapshot(
            revision: 7,
            entries: [],
            currentEntryID: nil,
            pendingRekeys: []
        )
        XCTAssertEqual(
            try database.replaceQueue(replacement, expectedRevision: 5),
            .committed(revision: 7)
        )
        XCTAssertEqual(try database.loadQueue(), replacement)
        XCTAssertThrowsError(try database.replaceQueue(stored))
    }

    func testQueueMetadataUpdateMissRollsBackWholeReplacement() throws {
        let url = databaseURL()
        let database = try makeDatabase(at: url)
        let entry = queueEntry(path: "/Music/Keep.mp3", sortKey: 0)
        let stored = LibraryQueueSnapshot(
            revision: 1,
            entries: [entry],
            currentEntryID: entry.id,
            pendingRekeys: []
        )
        try database.replaceQueue(stored)
        let raw = try openExistingDatabase(at: url)
        try raw.execute(
            """
            CREATE TRIGGER delete_queue_revision_after_insert
            AFTER INSERT ON queue_entries BEGIN
                DELETE FROM domain_revisions WHERE domain = 'queue';
            END
            """
        )
        raw.close()

        XCTAssertThrowsError(
            try database.replaceQueue(
                LibraryQueueSnapshot(
                    revision: 2,
                    entries: [queueEntry(path: "/Music/New.mp3", sortKey: 0)],
                    currentEntryID: nil,
                    pendingRekeys: []
                )
            )
        ) { error in
            XCTAssertTrue(error is LibraryDatabaseError)
        }
        XCTAssertEqual(try database.loadQueue(), stored)
    }

    func testPlaylistsCleanupAndWeightsRoundTrip() throws {
        let database = try makeDatabase()
        let playlistID = UUID()
        let track = UserPlaylist.Track(
            id: UUID(),
            path: "/Music/Song.mp3",
            signature: signature(path: "/Music/Song.mp3")
        )
        let playlist = UserPlaylist(
            id: playlistID,
            name: "收藏",
            tracks: [track],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let cleanup = PlaylistCleanupIntent(
            kind: .relocateTracks,
            playlistID: playlistID,
            trackPaths: [track.path],
            trackIDs: [track.id],
            trackRelocations: [
                .init(trackID: track.id, oldPath: track.path, newPath: "/Music/Moved.mp3")
            ],
            createdAt: Date(timeIntervalSince1970: 3)
        )
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(revision: 4, playlists: [playlist], pendingCleanup: [cleanup])
        )
        try database.replaceWeights(
            LibraryWeightsSnapshot(
                revision: 5,
                queueLevels: [PathKey.canonical(path: track.path): 2],
                playlistLevels: [playlistID: [PathKey.canonical(path: track.path): 5]]
            )
        )

        XCTAssertEqual(try database.loadPlaylists().playlists, [playlist])
        XCTAssertEqual(try database.loadPlaylists().pendingCleanup, [cleanup])
        XCTAssertEqual(try database.loadWeights().queueLevels.values.first, 2)
        XCTAssertEqual(try database.loadWeights().playlistLevels[playlistID]?.values.first, 5)
    }

    func testIncrementalPlaylistReplacementPreservesUnchangedSparseWeights() throws {
        let database = try makeDatabase()
        let first = UserPlaylist(
            id: UUID(),
            name: "First",
            tracks: [.init(path: "/Music/First.mp3")],
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let second = UserPlaylist(
            id: UUID(),
            name: "Second",
            tracks: [.init(path: "/Music/Second.mp3")],
            createdAt: Date(timeIntervalSinceReferenceDate: 3),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4)
        )
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 1,
                playlists: [first, second],
                pendingCleanup: []
            )
        )
        try database.replaceWeights(
            LibraryWeightsSnapshot(
                revision: 1,
                queueLevels: [:],
                playlistLevels: [
                    first.id: [PathKey.canonical(path: first.tracks[0].path): 2],
                    second.id: [PathKey.canonical(path: second.tracks[0].path): 5],
                ]
            )
        )

        var changedFirst = first
        changedFirst.name = "First Updated"
        changedFirst.updatedAt = Date(timeIntervalSinceReferenceDate: 5)
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 2,
                playlists: [second, changedFirst],
                pendingCleanup: []
            )
        )
        let afterUpdate = try database.loadWeights()
        XCTAssertEqual(afterUpdate.playlistLevels[first.id]?.values.first, 2)
        XCTAssertEqual(afterUpdate.playlistLevels[second.id]?.values.first, 5)
        XCTAssertEqual(
            try database.loadPlaylists().playlists.map(\.id),
            [second.id, first.id]
        )

        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 3,
                playlists: [second],
                pendingCleanup: []
            )
        )
        let afterDelete = try database.loadWeights()
        XCTAssertNil(afterDelete.playlistLevels[first.id])
        XCTAssertEqual(afterDelete.playlistLevels[second.id]?.values.first, 5)
        XCTAssertEqual(afterDelete.revision, 2)
    }

    func testPlaylistTrackContentChangesEvenWhenUpdatedAtDoesNot() throws {
        let database = try makeDatabase()
        let timestamp = Date(timeIntervalSinceReferenceDate: 42)
        let original = UserPlaylist(
            id: UUID(),
            name: "Stable Metadata",
            tracks: [.init(path: "/Music/Original.mp3")],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try database.replacePlaylists(
            .init(revision: 1, playlists: [original], pendingCleanup: [])
        )
        var replacement = original
        replacement.tracks = [.init(path: "/Music/Replacement.mp3")]
        try database.replacePlaylists(
            .init(revision: 2, playlists: [replacement], pendingCleanup: [])
        )

        XCTAssertEqual(try database.loadPlaylists().playlists, [replacement])
    }

    func testPlaylistDeletionCascadesSparseWeightsAndPersistsCleanupInOneTransaction() throws {
        let database = try makeDatabase()
        let playlistID = UUID()
        let track = UserPlaylist.Track(path: "/Music/Delete.mp3")
        let playlist = UserPlaylist(id: playlistID, name: "Delete", tracks: [track])
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(revision: 1, playlists: [playlist], pendingCleanup: [])
        )
        try database.replaceWeights(
            LibraryWeightsSnapshot(
                revision: 1,
                queueLevels: [:],
                playlistLevels: [playlistID: [PathKey.canonical(path: track.path): 3]]
            )
        )
        let cleanup = PlaylistCleanupIntent(
            kind: .deletePlaylist,
            playlistID: playlistID,
            trackPaths: [track.path],
            trackIDs: [track.id]
        )

        XCTAssertTrue(try database.deletePlaylist(id: playlistID, cleanupIntent: cleanup, nextRevision: 2))
        XCTAssertTrue(try database.loadPlaylists().playlists.isEmpty)
        XCTAssertEqual(try database.loadPlaylists().pendingCleanup, [cleanup])
        XCTAssertNil(try database.loadWeights().playlistLevels[playlistID])
        XCTAssertEqual(try database.loadWeights().revision, 2)
    }

    func testPlaybackSessionIsRevisionMonotonic() throws {
        let database = try makeDatabase()
        let playlistID = UUID()
        let trackID = UUID()
        let newest = LibraryPlaybackSession(
            revision: 9,
            scope: .playlist,
            playlistID: playlistID,
            scopeTrackID: trackID,
            queueEntryID: nil,
            fallbackPath: "/Music/A.mp3",
            positionMilliseconds: 12_345
        )
        XCTAssertEqual(
            try database.storePlaybackSession(newest, expectedRevision: 0),
            .committed(revision: 9)
        )
        XCTAssertEqual(
            try database.storePlaybackSession(newest, expectedRevision: 0),
            .alreadyCurrent(revision: 9)
        )
        let stale = LibraryPlaybackSession(
            revision: 8,
            scope: .queue,
            playlistID: nil,
            scopeTrackID: nil,
            queueEntryID: nil,
            fallbackPath: "/Music/Old.mp3",
            positionMilliseconds: 0
        )
        XCTAssertEqual(
            try database.storePlaybackSession(stale, expectedRevision: 9),
            .stale(storedRevision: 9)
        )
        let conflict = LibraryPlaybackSession(
            revision: 9,
            scope: newest.scope,
            playlistID: newest.playlistID,
            scopeTrackID: newest.scopeTrackID,
            queueEntryID: newest.queueEntryID,
            fallbackPath: newest.fallbackPath,
            positionMilliseconds: newest.positionMilliseconds + 1
        )
        XCTAssertEqual(
            try database.storePlaybackSession(conflict, expectedRevision: 9),
            .conflict(revision: 9)
        )
        XCTAssertThrowsError(try database.storePlaybackSession(stale))
        XCTAssertEqual(try database.loadPlaybackSession(), newest)
        XCTAssertEqual(try database.playbackSessionRevision(), newest.revision)
    }

    func testMalformedPlaybackSessionIsReportedAsCorruption() throws {
        let url = databaseURL()
        let database = try makeDatabase(at: url)
        let raw = try openExistingDatabase(at: url)
        try raw.execute(
            """
            INSERT INTO playback_session(
                singleton, revision, scope_kind, playlist_id, scope_track_id,
                queue_entry_id, fallback_path, position_ms
            ) VALUES(1, 1, 1, NULL, NULL, NULL, '/Music/Broken.mp3', 0)
            """
        )
        try raw.execute(
            "UPDATE domain_revisions SET revision = 1 WHERE domain = 'session'"
        )
        raw.close()

        XCTAssertThrowsError(try database.loadPlaybackSession()) { error in
            XCTAssertTrue(error is LibraryDatabaseError)
        }
    }

    func testLibraryLocationRoundTripStreamingRefreshAndTouch() throws {
        let database = try makeDatabase()
        let id = UUID()
        let original = try locationRecord(
            id: id,
            bookmark: Data("scoped-bookmark".utf8),
            bookmarkKind: .securityScoped,
            fallbackPath: "/Volumes/Archive/Music",
            volumeIdentifier: "volume-id",
            volumeRelativeRootPath: "Music",
            rootResourceIdentifier: "root-resource",
            displayName: "Archive Music",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )

        XCTAssertEqual(try database.libraryLocationsRevision(), 0)
        XCTAssertTrue(
            try database.upsertLibraryLocation(
                original,
                expectedRevision: 0,
                nextRevision: 1
            )
        )
        XCTAssertEqual(try database.loadLibraryLocation(id: id), original)
        XCTAssertEqual(try database.libraryLocationsRevision(), 1)

        var streamed: [LibraryLocationRecord] = []
        let visited = try database.forEachLibraryLocation { record in
            streamed.append(record)
            return true
        }
        XCTAssertEqual(visited, 1)
        XCTAssertEqual(streamed, [original])

        let refreshed = try locationRecord(
            id: id,
            kind: .singleFile,
            bookmark: Data("regular-bookmark".utf8),
            bookmarkKind: .regular,
            fallbackPath: "/Volumes/Archive/Moved.mp3",
            volumeIdentifier: "volume-id",
            volumeRelativeRootPath: "Moved.mp3",
            rootResourceIdentifier: "file-resource",
            displayName: "Moved.mp3",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        XCTAssertTrue(
            try database.upsertLibraryLocation(
                refreshed,
                expectedRevision: 1,
                nextRevision: 2
            )
        )
        XCTAssertEqual(try database.loadLibraryLocation(id: id), refreshed)

        let touchedAt = Date(timeIntervalSinceReferenceDate: 30)
        XCTAssertTrue(
            try database.touchLibraryLocation(
                id: id,
                updatedAt: touchedAt,
                expectedRevision: 2,
                nextRevision: 3
            )
        )
        let touched = try XCTUnwrap(database.loadLibraryLocation(id: id))
        XCTAssertEqual(touched.location, refreshed.location)
        XCTAssertEqual(touched.updatedAt, touchedAt)
        XCTAssertEqual(try database.libraryLocationsRevision(), 3)
    }

    func testLibraryLocationBookmarkBoundary() throws {
        let database = try makeDatabase()
        let maximumBookmark = Data(
            repeating: 0xA5,
            count: LibraryLocationLimits.maximumBookmarkBytes
        )
        let record = try locationRecord(bookmark: maximumBookmark)

        XCTAssertTrue(
            try database.upsertLibraryLocation(
                record,
                expectedRevision: 0,
                nextRevision: 1
            )
        )
        XCTAssertEqual(
            try database.loadLibraryLocation(id: record.location.id)?.location.bookmarkData.count,
            LibraryLocationLimits.maximumBookmarkBytes
        )

        XCTAssertThrowsError(
            try LibraryLocation(
                kind: .directory,
                bookmarkData: Data(
                    repeating: 0,
                    count: LibraryLocationLimits.maximumBookmarkBytes + 1
                ),
                bookmarkKind: .regular,
                fallbackPath: "/Volumes/Test/Music",
                displayName: "Music"
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryLocationValidationError,
                .bookmarkTooLarge(maximumBytes: LibraryLocationLimits.maximumBookmarkBytes)
            )
        }
    }

    func testLibraryLocationRevisionConflictDoesNotMutateState() throws {
        let database = try makeDatabase()
        let record = try locationRecord(updatedAt: Date(timeIntervalSinceReferenceDate: 1))

        XCTAssertFalse(
            try database.upsertLibraryLocation(
                record,
                expectedRevision: 1,
                nextRevision: 2
            )
        )
        XCTAssertNil(try database.loadLibraryLocation(id: record.location.id))
        XCTAssertEqual(try database.libraryLocationsRevision(), 0)

        XCTAssertThrowsError(
            try database.upsertLibraryLocation(
                record,
                expectedRevision: 0,
                nextRevision: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryDatabaseError,
                .invalidData("外置位置修订号必须连续递增")
            )
        }

        XCTAssertTrue(
            try database.upsertLibraryLocation(
                record,
                expectedRevision: 0,
                nextRevision: 1
            )
        )
        XCTAssertFalse(
            try database.touchLibraryLocation(
                id: record.location.id,
                updatedAt: Date(timeIntervalSinceReferenceDate: 999),
                expectedRevision: 0,
                nextRevision: 1
            )
        )
        XCTAssertEqual(try database.loadLibraryLocation(id: record.location.id), record)
        XCTAssertEqual(try database.libraryLocationsRevision(), 1)
    }

    func testDeletingLibraryLocationDetachesTrackReferencesAtomically() throws {
        let url = databaseURL()
        let database = try makeDatabase(at: url)
        let record = try locationRecord()
        XCTAssertTrue(
            try database.upsertLibraryLocation(
                record,
                expectedRevision: 0,
                nextRevision: 1
            )
        )
        let entry = LibraryQueueEntry(
            id: UUID(),
            sortKey: 0,
            path: "/Volumes/Test/Music/Artist/Song.mp3",
            signature: signature(path: "/Volumes/Test/Music/Artist/Song.mp3"),
            locationID: record.location.id,
            relativePath: "Artist/Song.mp3"
        )
        try database.replaceQueue(
            LibraryQueueSnapshot(
                revision: 1,
                entries: [entry],
                currentEntryID: entry.id,
                pendingRekeys: []
            )
        )
        let playlistTrack = UserPlaylist.Track(
            path: "/Volumes/Test/Music/Artist/Playlist Song.mp3",
            signature: signature(path: "/Volumes/Test/Music/Artist/Playlist Song.mp3")
        )
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 1,
                playlists: [
                    UserPlaylist(id: UUID(), name: "External", tracks: [playlistTrack])
                ],
                pendingCleanup: []
            )
        )
        let referenceWriter = try openExistingDatabase(at: url)
        try referenceWriter.execute(
            "UPDATE playlist_tracks SET location_id = ?, relative_path = ? WHERE track_id = ?",
            bindings: [
                .text(record.location.id.uuidString),
                .text("Artist/Playlist Song.mp3"),
                .text(playlistTrack.id.uuidString),
            ]
        )
        referenceWriter.close()
        XCTAssertEqual(
            try database.libraryLocationReferenceCounts(id: record.location.id),
            LibraryLocationReferenceCounts(queueEntries: 1, playlistTracks: 1)
        )

        XCTAssertTrue(
            try database.deleteLibraryLocation(
                id: record.location.id,
                expectedRevision: 1,
                nextRevision: 2
            )
        )
        XCTAssertNil(try database.loadLibraryLocation(id: record.location.id))
        XCTAssertEqual(try database.libraryLocationsRevision(), 2)
        XCTAssertEqual(
            try database.libraryLocationReferenceCounts(id: record.location.id),
            LibraryLocationReferenceCounts(queueEntries: 0, playlistTracks: 0)
        )
        let detached = try XCTUnwrap(database.loadQueue().entries.first)
        XCTAssertEqual(detached.path, entry.path)
        XCTAssertEqual(detached.signature, entry.signature)
        XCTAssertNil(detached.locationID)
        XCTAssertNil(detached.relativePath)
        XCTAssertEqual(try database.loadQueue().revision, 2)
        XCTAssertEqual(try database.loadPlaylists().revision, 2)
        let referenceReader = try openExistingDatabase(at: url)
        XCTAssertEqual(
            try referenceReader.scalarInt(
                "SELECT COUNT(*) FROM playlist_tracks WHERE location_id IS NOT NULL OR relative_path IS NOT NULL"
            ),
            0
        )
        referenceReader.close()

        XCTAssertFalse(
            try database.deleteLibraryLocation(
                id: record.location.id,
                expectedRevision: 2,
                nextRevision: 3
            )
        )
        XCTAssertEqual(try database.libraryLocationsRevision(), 2)
    }

    func testLibraryLocationStreamingStopsWithoutMaterializingAllRows() throws {
        let database = try makeDatabase()
        for revision in 0..<3 {
            let record = try locationRecord(
                id: UUID(),
                displayName: "Root \(revision)"
            )
            XCTAssertTrue(
                try database.upsertLibraryLocation(
                    record,
                    expectedRevision: UInt64(revision),
                    nextRevision: UInt64(revision + 1)
                )
            )
        }

        var delivered = 0
        let visited = try database.forEachLibraryLocation { _ in
            delivered += 1
            return delivered < 2
        }
        XCTAssertEqual(visited, 2)
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(try database.libraryLocationsRevision(), 3)
    }

    func testFutureDatabaseOpensReadOnly() throws {
        let url = databaseURL()
        let current = try makeDatabase(at: url)
        let location = try locationRecord()
        XCTAssertTrue(
            try current.upsertLibraryLocation(
                location,
                expectedRevision: 0,
                nextRevision: 1
            )
        )
        current.close()
        let futureWriter = try SQLiteDatabase(
            fileURL: url,
            schema: SQLiteSchema(
                applicationID: LibraryDatabase.applicationID,
                version: 99,
                migrations: [
                    SQLiteMigration(fromVersion: 1, toVersion: 99) { _ in }
                ]
            )
        )
        futureWriter.close()

        let future = try makeDatabase(at: url)
        XCTAssertEqual(future.accessMode, .readOnlyFuture(version: 99))
        XCTAssertEqual(try future.loadLibraryLocation(id: location.location.id), location)
        XCTAssertThrowsError(
            try future.replaceQueue(
                LibraryQueueSnapshot(revision: 1, entries: [], currentEntryID: nil, pendingRekeys: [])
            )
        )
        XCTAssertThrowsError(
            try future.upsertLibraryLocation(
                location,
                expectedRevision: 1,
                nextRevision: 2
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .readOnly)
        }
        XCTAssertThrowsError(
            try future.touchLibraryLocation(
                id: location.location.id,
                expectedRevision: 1,
                nextRevision: 2
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .readOnly)
        }
        XCTAssertThrowsError(
            try future.deleteLibraryLocation(
                id: location.location.id,
                expectedRevision: 1,
                nextRevision: 2
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .readOnly)
        }
    }

    func testForeignDatabaseRejectsLibraryLocationWritesBeforeTouchingSchema() throws {
        let url = databaseURL()
        let foreignApplicationID: Int32 = 0x1234_5678
        let foreign = try SQLiteDatabase(
            fileURL: url,
            schema: SQLiteSchema(
                applicationID: foreignApplicationID,
                version: 1,
                migrations: [
                    SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                        try connection.execute("CREATE TABLE foreign_data(value TEXT)")
                    }
                ]
            )
        )
        foreign.close()

        let database = try makeDatabase(at: url)
        XCTAssertEqual(
            database.accessMode,
            .readOnlyForeign(applicationID: foreignApplicationID)
        )
        let record = try locationRecord()
        XCTAssertThrowsError(
            try database.upsertLibraryLocation(
                record,
                expectedRevision: 0,
                nextRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .readOnly)
        }
    }

    func testQuickCheckAndMigrationReceipt() throws {
        let database = try makeDatabase()
        XCTAssertTrue(try database.quickCheck())
        XCTAssertFalse(try database.hasImportedSource("queue-v2"))
        try database.recordImportedSource(
            name: "queue-v2",
            sourceVersion: 2,
            byteCount: 123,
            modificationTimeNanoseconds: 456,
            digest: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertTrue(try database.hasImportedSource("queue-v2"))
    }

    private func makeDatabase() throws -> LibraryDatabase {
        try makeDatabase(at: databaseURL())
    }

    private func makeDatabase(at url: URL) throws -> LibraryDatabase {
        try LibraryDatabase(fileURL: url)
    }

    private func databaseURL() -> URL {
        directory.appendingPathComponent("Library.sqlite", isDirectory: false)
    }

    private func openExistingDatabase(at url: URL) throws -> SQLiteDatabase {
        try SQLiteDatabase(
            fileURL: url,
            schema: SQLiteSchema(
                applicationID: LibraryDatabase.applicationID,
                version: LibraryDatabase.schemaVersion,
                migrations: []
            )
        )
    }

    private func queueEntry(path: String, sortKey: Int64) -> LibraryQueueEntry {
        LibraryQueueEntry(
            id: UUID(),
            sortKey: sortKey,
            path: path,
            signature: nil,
            locationID: nil,
            relativePath: nil
        )
    }

    private func signature(path: String) -> FileSignature {
        FileSignature(
            pathKey: PathKey.canonical(path: path),
            size: 42,
            modificationTimeNanoseconds: 99,
            inode: UInt64.max,
            fileResourceIdentifier: "resource",
            volumeIdentifier: "volume"
        )
    }

    private func locationRecord(
        id: UUID = UUID(),
        kind: LibraryLocationKind = .directory,
        bookmark: Data = Data("bookmark".utf8),
        bookmarkKind: LibraryBookmarkKind = .securityScoped,
        fallbackPath: String = "/Volumes/Test/Music",
        volumeIdentifier: String? = "volume-id",
        volumeRelativeRootPath: String? = "Music",
        rootResourceIdentifier: String? = "root-resource",
        displayName: String = "Music",
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 100)
    ) throws -> LibraryLocationRecord {
        LibraryLocationRecord(
            location: try LibraryLocation(
                id: id,
                kind: kind,
                bookmarkData: bookmark,
                bookmarkKind: bookmarkKind,
                fallbackPath: fallbackPath,
                volumeIdentifier: volumeIdentifier,
                volumeRelativeRootPath: volumeRelativeRootPath,
                rootResourceIdentifier: rootResourceIdentifier,
                displayName: displayName
            ),
            updatedAt: updatedAt
        )
    }
}
