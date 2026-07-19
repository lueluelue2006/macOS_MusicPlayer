import XCTest
@testable import MusicPlayer

private final class ControlledPlaybackWeightsWriter: @unchecked Sendable {
    private enum InjectedFailure: Error {
        case writeFailed
    }

    private let condition = NSCondition()
    private var blockNextWrite = false
    private var remainingFailingWrites = 0
    private var releaseRequested = false
    private var writeIsBlocked = false
    private var completedWriteCount = 0

    var isBlocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return writeIsBlocked
    }

    var writeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return completedWriteCount
    }

    func armBlockingWrite() {
        condition.lock()
        blockNextWrite = true
        releaseRequested = false
        condition.unlock()
    }

    func armFailingWrite() {
        armFailingWrites(1)
    }

    func armFailingWrites(_ count: Int) {
        condition.lock()
        remainingFailingWrites = max(0, count)
        condition.unlock()
    }

    func releaseBlockedWrite() {
        condition.lock()
        releaseRequested = true
        condition.broadcast()
        condition.unlock()
    }

    func write(_ data: Data, to url: URL) throws {
        condition.lock()
        let shouldBlock = blockNextWrite
        let shouldFail = remainingFailingWrites > 0
        blockNextWrite = false
        if shouldFail {
            remainingFailingWrites -= 1
        }
        if shouldBlock {
            writeIsBlocked = true
            condition.broadcast()
            while !releaseRequested {
                condition.wait()
            }
            releaseRequested = false
            writeIsBlocked = false
        }
        completedWriteCount += 1
        condition.unlock()

        if shouldFail { throw InjectedFailure.writeFailed }
        try data.write(to: url, options: .atomic)
    }
}

final class PlaylistsDurabilityTests: XCTestCase {
    func testPersistenceFailuresExposeRetryPolicy() {
        XCTAssertTrue(PlaylistPersistenceFailure.storageUnavailable.isRetryable)
        XCTAssertTrue(PlaylistPersistenceFailure.writeFailed("disk busy").isRetryable)
        XCTAssertFalse(PlaylistPersistenceFailure.encodingFailed("invalid payload").isRetryable)
        XCTAssertFalse(
            PlaylistPersistenceFailure.capacityExceeded(maximumBytes: 16 * 1_024 * 1_024)
                .isRetryable
        )
        XCTAssertFalse(
            PlaylistPersistenceFailure.readOnly(.unreadable).isRetryable
        )
    }

    @MainActor
    func testEncodingFailureCompletesAsNonretryableWithoutWriting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("user-playlists.json")
        let invalidPlaylist = UserPlaylist(
            name: "Invalid Date",
            tracks: [],
            updatedAt: Date(timeIntervalSince1970: .infinity)
        )
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([invalidPlaylist])

        guard case .applied(_, let receipt) = store.createEmptyPlaylistResult(name: "New") else {
            return XCTFail("the mutation should reach snapshot validation")
        }
        let result = await store.awaitDurableCommit(receipt)

        guard case .failed(let revision, .encodingFailed(_), let retryable) = result else {
            return XCTFail("invalid snapshots must report their encoding failure")
        }
        XCTAssertEqual(revision, receipt.revision)
        XCTAssertFalse(retryable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    @MainActor
    func testLibraryDatabaseBackendLoadsAuthoritativeSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(
            fileURL: root.appendingPathComponent("Library.sqlite")
        )
        defer { database.close() }
        let track = UserPlaylist.Track(
            path: "/Music/Database.mp3",
            signature: syntheticSignature(
                path: "/Music/Database.mp3",
                identity: "database-load"
            )
        )
        let playlist = UserPlaylist(
            name: "Database",
            tracks: [track],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let cleanup = PlaylistCleanupIntent(
            kind: .removeTracks,
            playlistID: playlist.id,
            trackPaths: [track.path],
            trackIDs: [track.id],
            createdAt: Date(timeIntervalSince1970: 3)
        )
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 7,
                playlists: [playlist],
                pendingCleanup: [cleanup]
            )
        )

        let store = PlaylistsStore(
            libraryDatabase: database,
            playbackWeights: PlaybackWeights(
                cacheFileURLOverride: root.appendingPathComponent("weights.json")
            ),
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        await store.ensureLoaded()

        XCTAssertEqual(store.playlists, [playlist])
        XCTAssertEqual(store.pendingCleanupIntents, [cleanup])
        XCTAssertEqual(store.selectedPlaylistID, playlist.id)
        XCTAssertEqual(store.persistenceState, .ready(durableRevision: 7))
    }

    @MainActor
    func testLibraryDatabaseBackendCoalescesMutationsToLatestDurableRevision() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(
            fileURL: root.appendingPathComponent("Library.sqlite")
        )
        defer { database.close() }
        let store = PlaylistsStore(
            libraryDatabase: database,
            automaticallyProcessesCleanup: false
        )
        await store.ensureLoaded()

        guard case .applied(let firstID, let firstReceipt) = store.createEmptyPlaylistResult(
            name: "First"
        ), case .applied(let secondID, let secondReceipt) = store.createEmptyPlaylistResult(
            name: "Second"
        ) else {
            return XCTFail("both mutations must be accepted before the writer drains")
        }

        guard case .committed(let throughRevision) = await store.awaitDurableCommit(
            secondReceipt
        ) else {
            return XCTFail("the latest coalesced database snapshot must commit")
        }
        XCTAssertGreaterThanOrEqual(throughRevision, secondReceipt.revision)
        guard case .committed(let firstThroughRevision) = await store.awaitDurableCommit(
            firstReceipt
        ) else {
            return XCTFail("a newer durable snapshot must acknowledge the older receipt")
        }
        XCTAssertGreaterThanOrEqual(firstThroughRevision, secondReceipt.revision)

        let snapshot = try database.loadPlaylists()
        XCTAssertEqual(snapshot.revision, secondReceipt.revision)
        XCTAssertEqual(snapshot.playlists.map(\.id), [secondID, firstID])
        XCTAssertEqual(snapshot.playlists.map(\.name), ["Second", "First"])
        XCTAssertEqual(store.persistenceState, .ready(durableRevision: secondReceipt.revision))
    }

    @MainActor
    func testLibraryDatabaseCASConflictAndStaleEnterReloadProtection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let conflictDatabase = try LibraryDatabase(
            fileURL: root.appendingPathComponent("conflict-Library.sqlite")
        )
        defer { conflictDatabase.close() }
        let conflictStore = PlaylistsStore(
            libraryDatabase: conflictDatabase,
            automaticallyProcessesCleanup: false
        )
        await conflictStore.ensureLoaded()
        try conflictDatabase.replacePlaylists(
            .init(
                revision: 1,
                playlists: [UserPlaylist(name: "External", tracks: [])],
                pendingCleanup: []
            )
        )
        guard case .applied(_, let conflictReceipt) = conflictStore.createEmptyPlaylistResult(
            name: "Local"
        ) else {
            return XCTFail("local mutation should be accepted before CAS detects divergence")
        }
        guard case .failed(_, .readOnly(.databaseInconsistent(let conflictDetail)), false) =
            await conflictStore.awaitDurableCommit(conflictReceipt) else {
            return XCTFail("same-revision different content must require a reload")
        }
        XCTAssertTrue(conflictDetail.contains("不同内容"))

        let staleDatabase = try LibraryDatabase(
            fileURL: root.appendingPathComponent("stale-Library.sqlite")
        )
        defer { staleDatabase.close() }
        let staleStore = PlaylistsStore(
            libraryDatabase: staleDatabase,
            automaticallyProcessesCleanup: false
        )
        await staleStore.ensureLoaded()
        try staleDatabase.replacePlaylists(
            .init(
                revision: 2,
                playlists: [UserPlaylist(name: "External Newer", tracks: [])],
                pendingCleanup: []
            )
        )
        guard case .applied(_, let staleReceipt) = staleStore.createEmptyPlaylistResult(
            name: "Local Older"
        ) else {
            return XCTFail("local mutation should be accepted before CAS detects staleness")
        }
        guard case .failed(_, .readOnly(.databaseInconsistent(let staleDetail)), false) =
            await staleStore.awaitDurableCommit(staleReceipt) else {
            return XCTFail("stale revision must require a reload")
        }
        XCTAssertTrue(staleDetail.contains("已过期"))
    }

    @MainActor
    func testLibraryDatabaseBackendPersistsCleanupIntentAndDurableAcknowledgement() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(
            fileURL: root.appendingPathComponent("Library.sqlite")
        )
        defer { database.close() }
        let trackURL = root.appendingPathComponent("database-cleanup.mp3")
        try Data("audio".utf8).write(to: trackURL)
        let track = UserPlaylist.Track(
            path: trackURL.path,
            signature: syntheticSignature(
                path: trackURL.path,
                identity: "database-cleanup"
            )
        )
        let playlist = UserPlaylist(name: "Cleanup", tracks: [track])
        try database.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 1,
                playlists: [playlist],
                pendingCleanup: []
            )
        )
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            persistenceDebounceInterval: 60
        )
        _ = weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let store = PlaylistsStore(
            libraryDatabase: database,
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        await store.ensureLoaded()

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [track.id], from: playlist.id)
        ) else {
            return XCTFail("the database must first persist the cleanup debt")
        }
        XCTAssertEqual(try database.loadPlaylists().pendingCleanup.count, 1)

        let report = await store.processPendingCleanupIntents()
        XCTAssertTrue(report.sidecarsDurable)
        XCTAssertTrue(store.pendingCleanupIntents.isEmpty)
        XCTAssertTrue(try database.loadPlaylists().pendingCleanup.isEmpty)
        XCTAssertTrue(try database.loadPlaylists().playlists[0].tracks.isEmpty)
        XCTAssertEqual(
            weights.level(for: trackURL, scope: .playlist(playlist.id)),
            .defaultLevel
        )
    }

    @MainActor
    func testFutureLibraryDatabaseLoadsDataButRejectsMutationsReadOnly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("Library.sqlite")
        let initial = try LibraryDatabase(fileURL: databaseURL)
        let playlist = UserPlaylist(name: "Future", tracks: [])
        try initial.replacePlaylists(
            LibraryPlaylistsSnapshot(
                revision: 4,
                playlists: [playlist],
                pendingCleanup: []
            )
        )
        initial.close()
        let futureWriter = try SQLiteDatabase(
            fileURL: databaseURL,
            schema: SQLiteSchema(
                applicationID: LibraryDatabase.applicationID,
                version: 99,
                migrations: [
                    SQLiteMigration(
                        fromVersion: LibraryDatabase.schemaVersion,
                        toVersion: 99
                    ) { _ in }
                ]
            )
        )
        futureWriter.close()
        let future = try LibraryDatabase(fileURL: databaseURL)
        defer { future.close() }
        let store = PlaylistsStore(
            libraryDatabase: future,
            automaticallyProcessesCleanup: false
        )

        await store.ensureLoaded()

        XCTAssertEqual(store.playlists, [playlist])
        XCTAssertEqual(
            store.persistenceState,
            .readOnly(.futureVersion(found: 99, supported: LibraryDatabase.schemaVersion))
        )
        guard case .rejected(.readOnly(.futureVersion(let found, let supported))) =
            store.createEmptyPlaylistResult(name: "Rejected") else {
            return XCTFail("future database mutations must remain read-only")
        }
        XCTAssertEqual(found, 99)
        XCTAssertEqual(supported, LibraryDatabase.schemaVersion)
        XCTAssertEqual(try future.loadPlaylists().playlists, [playlist])
        XCTAssertEqual(try future.loadPlaylists().revision, 4)
    }

    @MainActor
    func testForeignLibraryDatabaseMapsToReadOnlyWithoutLegacyFallback() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("Library.sqlite")
        let foreignApplicationID: Int32 = 0x4652_474E // "FRGN"
        let foreignWriter = try SQLiteDatabase(
            fileURL: databaseURL,
            schema: SQLiteSchema(
                applicationID: foreignApplicationID,
                version: 1,
                migrations: [
                    SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                        try connection.execute("CREATE TABLE foreign_fixture(value INTEGER)")
                    }
                ]
            )
        )
        foreignWriter.close()
        let foreign = try LibraryDatabase(fileURL: databaseURL)
        defer { foreign.close() }
        let store = PlaylistsStore(
            libraryDatabase: foreign,
            automaticallyProcessesCleanup: false
        )

        await store.ensureLoaded()

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertEqual(
            store.persistenceState,
            .readOnly(.foreignDatabase(applicationID: foreignApplicationID))
        )
        guard case .rejected(.readOnly(.foreignDatabase(let actualID))) =
            store.createEmptyPlaylistResult(name: "Rejected") else {
            return XCTFail("a foreign database must never fall back to the JSON writer")
        }
        XCTAssertEqual(actualID, foreignApplicationID)
    }

    @MainActor
    func testFlushReturnsFalseBeforeLoadingStarts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("user-playlists.json"),
            automaticallyProcessesCleanup: false
        )

        XCTAssertEqual(store.persistenceState, .notLoaded)
        XCTAssertFalse(store.flushPersistence())
        XCTAssertEqual(store.persistenceState, .notLoaded)
    }

    @MainActor
    func testFlushReturnsFalseWhileInitialLoadIsPending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("user-playlists.json"),
            automaticallyProcessesCleanup: false
        )

        store.loadIfNeeded()
        XCTAssertEqual(store.persistenceState, .loading)
        XCTAssertFalse(store.flushPersistence())
        XCTAssertEqual(store.persistenceState, .loading)
    }

    @MainActor
    func testFlushReturnsFalseForProtectedReadOnlyStore() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("user-playlists.json")
        try Data(#"{"version":999}"#.utf8).write(to: storeURL)
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            automaticallyProcessesCleanup: false
        )

        await store.ensureLoaded()
        guard case .readOnly(.futureVersion(found: 999, supported: 2)) = store.persistenceState else {
            return XCTFail("future schema must stay protected and read-only")
        }
        XCTAssertFalse(store.flushPersistence())
    }

    @MainActor
    func testUnchangedMutationDoesNotAcknowledgePreviouslyDirtySnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedParent)
        let store = PlaylistsStore(
            playlistsFileURLOverride: blockedParent.appendingPathComponent("user-playlists.json"),
            automaticallyProcessesCleanup: false
        )

        await store.ensureLoaded()
        XCTAssertEqual(
            store.persistenceState,
            .dirty(revision: 0, lastError: .storageUnavailable)
        )

        let unchanged: PlaylistMutationResult<Int> = .unchanged(42)
        guard case .persistenceFailed(.storageUnavailable) = await store.awaitDurability(
            of: unchanged
        ) else {
            return XCTFail("an unchanged value must not acknowledge a dirty snapshot")
        }
    }

    @MainActor
    func testDurableDeleteCleansSidecarsThenAcknowledgesIntent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("user-playlists.json")
        let weightsURL = root.appendingPathComponent("playback-weights.json")
        let artworkDirectory = root.appendingPathComponent("PlaylistArtwork", isDirectory: true)
        let weights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            persistenceDebounceInterval: 60
        )
        let artwork = PlaylistArtworkStore(customDirectoryOverride: artworkDirectory)
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: weights,
            artworkStore: artwork,
            automaticallyProcessesCleanup: false
        )
        await store.ensureLoaded()

        let created = await store.awaitDurability(
            of: store.createEmptyPlaylistResult(name: "Durable")
        )
        let playlistID: UUID
        switch created {
        case .committed(let id), .unchanged(let id): playlistID = id
        default: return XCTFail("playlist creation must be durable")
        }

        let trackURL = root.appendingPathComponent("song.mp3")
        try Data("fixture".utf8).write(to: trackURL)
        let added = await store.addTracksResult([trackURL], to: playlistID)
        guard case .committed = await store.awaitDurability(of: added) else {
            return XCTFail("track addition must be durable")
        }
        XCTAssertEqual(
            weights.setLevel(.red, for: trackURL, scope: .playlist(playlistID)),
            .applied
        )
        XCTAssertTrue(weights.flushPersistence().isDurable)

        try FileManager.default.createDirectory(
            at: artworkDirectory,
            withIntermediateDirectories: true
        )
        let artworkURL = artworkDirectory.appendingPathComponent("\(playlistID.uuidString).jpg")
        try Data("user-artwork".utf8).write(to: artworkURL)

        let playlist = try XCTUnwrap(store.playlist(for: playlistID))
        let deletion = await store.awaitDurability(of: store.deletePlaylistResult(playlist))
        guard case .committed = deletion else {
            return XCTFail("playlist deletion must be durable before sidecar cleanup")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))
        XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlistID)), .red)
        XCTAssertEqual(store.pendingCleanupIntents.count, 1)

        let report = await store.processPendingCleanupIntents()
        XCTAssertEqual(report.processedIntentCount, 1)
        XCTAssertEqual(report.remainingIntentCount, 0)
        XCTAssertTrue(report.sidecarsDurable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkURL.path))
        XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlistID)), .defaultLevel)

        let reloaded = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: weights,
            artworkStore: artwork,
            automaticallyProcessesCleanup: false
        )
        await reloaded.ensureLoaded()
        XCTAssertTrue(reloaded.playlists.isEmpty)
        XCTAssertTrue(reloaded.pendingCleanupIntents.isEmpty)

        let freshWeights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            persistenceDebounceInterval: 60
        )
        XCTAssertEqual(
            freshWeights.level(for: trackURL, scope: .playlist(playlistID)),
            .defaultLevel,
            "cleanup acknowledgement must follow a durable sidecar deletion"
        )
    }

    @MainActor
    func testFailedMainCommitNeverDeletesSidecars() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedParent)
        let storeURL = blockedParent.appendingPathComponent("user-playlists.json")
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            persistenceDebounceInterval: 60
        )
        let artworkDirectory = root.appendingPathComponent("artwork", isDirectory: true)
        let artwork = PlaylistArtworkStore(customDirectoryOverride: artworkDirectory)
        let playlist = UserPlaylist(
            name: "Protected",
            tracks: [UserPlaylist.Track(path: root.appendingPathComponent("song.mp3").path)]
        )
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: weights,
            artworkStore: artwork,
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        let trackURL = URL(fileURLWithPath: playlist.tracks[0].path)
        _ = weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let artworkURL = artworkDirectory.appendingPathComponent("\(playlist.id.uuidString).jpg")
        try Data("user-artwork".utf8).write(to: artworkURL)

        let deletion = await store.awaitDurability(of: store.deletePlaylistResult(playlist))
        guard case .rejected(.storageUnavailable) = deletion else {
            return XCTFail("blocked storage must reject before mutating the main snapshot")
        }
        let report = await store.processPendingCleanupIntents()
        XCTAssertEqual(report.processedIntentCount, 0)
        XCTAssertTrue(report.sidecarsDurable, "A rejected mutation creates no cleanup debt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))
        XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlist.id)), .red)
    }

    @MainActor
    func testDeleteMergesEarlierRemovalIntentPaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mp3").path
        let second = root.appendingPathComponent("second.mp3").path
        let playlist = UserPlaylist(
            name: "Merge",
            tracks: [UserPlaylist.Track(path: first), UserPlaylist.Track(path: second)]
        )
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("user-playlists.json"),
            playbackWeights: PlaybackWeights(
                cacheFileURLOverride: root.appendingPathComponent("weights.json")
            ),
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        guard case .applied = store.removeTracksResult(paths: [first], from: playlist.id) else {
            return XCTFail("first mutation must apply")
        }
        let current = try XCTUnwrap(store.playlist(for: playlist.id))
        let deletion = store.deletePlaylistResult(current)
        guard case .committed = await store.awaitDurability(of: deletion) else {
            return XCTFail("coalesced delete must persist")
        }

        let intent = try XCTUnwrap(store.pendingCleanupIntents.first)
        XCTAssertEqual(intent.kind, .deletePlaylist)
        XCTAssertEqual(Set(intent.trackPaths), Set([first, second]))
    }

    @MainActor
    func testUniqueSignatureRelocationPersistsPathAndRekeysWeight() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("old/song.mp3").path
        let newURL = root.appendingPathComponent("new/song.mp3")
        try FileManager.default.createDirectory(
            at: newURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: newURL)
        let originalSignature = syntheticSignature(path: oldPath, identity: "stable-file")
        let candidateSignature = syntheticSignature(path: newURL.path, identity: "stable-file")
        let playlist = UserPlaylist(
            name: "Relocate",
            tracks: [.init(path: oldPath, signature: originalSignature)]
        )
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            persistenceDebounceInterval: 60
        )
        _ = weights.setLevel(
            .red,
            for: URL(fileURLWithPath: oldPath),
            scope: .playlist(playlist.id)
        )
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("user-playlists.json"),
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        let mutation = store.relocateMissingTracksResult(
            using: [FileRelocationCandidate(url: newURL, signature: candidateSignature)]
        )
        guard case .committed(let summary) = await store.awaitDurability(of: mutation) else {
            return XCTFail("unique signature match must commit")
        }
        XCTAssertEqual(summary.relocatedTrackCount, 1)
        XCTAssertEqual(store.playlist(for: playlist.id)?.tracks.first?.path, newURL.path)
        XCTAssertEqual(store.pendingCleanupIntents.first?.kind, .relocateTracks)

        let cleanup = await store.processPendingCleanupIntents()
        XCTAssertTrue(cleanup.sidecarsDurable)
        XCTAssertEqual(weights.level(for: newURL, scope: .playlist(playlist.id)), .red)
        XCTAssertEqual(
            weights.level(for: URL(fileURLWithPath: oldPath), scope: .playlist(playlist.id)),
            .defaultLevel
        )

        let freshWeights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            persistenceDebounceInterval: 60
        )
        XCTAssertEqual(freshWeights.level(for: newURL, scope: .playlist(playlist.id)), .red)
        XCTAssertEqual(
            freshWeights.level(
                for: URL(fileURLWithPath: oldPath),
                scope: .playlist(playlist.id)
            ),
            .defaultLevel,
            "rekey success must survive a fresh sidecar reload"
        )
    }

    @MainActor
    func testLocationBackedRelocationUpdatesRelativePathInsideStoredRoot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("External Music", isDirectory: true)
        let movedURL = libraryRoot.appendingPathComponent("Moved/song.mp3")
        try FileManager.default.createDirectory(
            at: movedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: movedURL)

        let database = try LibraryDatabase(
            fileURL: root.appendingPathComponent("Library.sqlite")
        )
        let location = try LibraryLocation(
            kind: .directory,
            bookmarkData: Data("bookmark".utf8),
            bookmarkKind: .regular,
            fallbackPath: libraryRoot.path,
            displayName: "External Music"
        )
        XCTAssertTrue(try database.upsertLibraryLocation(
            LibraryLocationRecord(location: location, updatedAt: Date()),
            expectedRevision: 0,
            nextRevision: 1
        ))

        let oldPath = libraryRoot.appendingPathComponent("Old/song.mp3").path
        let playlist = UserPlaylist(
            name: "External",
            tracks: [.init(
                path: oldPath,
                signature: syntheticSignature(path: oldPath, identity: "external-file"),
                locationID: location.id,
                relativePath: "Old/song.mp3"
            )]
        )
        let store = PlaylistsStore(
            libraryDatabase: database,
            playbackWeights: PlaybackWeights(
                cacheFileURLOverride: root.appendingPathComponent("weights.json")
            ),
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        let mutation = store.relocateMissingTracksResult(using: [
            FileRelocationCandidate(
                url: movedURL,
                signature: syntheticSignature(path: movedURL.path, identity: "external-file")
            )
        ])
        guard case .committed = await store.awaitDurability(of: mutation),
              let relocated = store.playlist(for: playlist.id)?.tracks.first else {
            return XCTFail("same-root relocation must persist")
        }
        XCTAssertEqual(relocated.path, movedURL.path)
        XCTAssertEqual(relocated.locationID, location.id)
        XCTAssertEqual(relocated.relativePath, "Moved/song.mp3")
    }

    @MainActor
    func testLocationBackedRelocationRejectsCandidateOutsideStoredRoot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("External Music", isDirectory: true)
        let outsideURL = root.appendingPathComponent("Elsewhere/song.mp3")
        try FileManager.default.createDirectory(
            at: outsideURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: outsideURL)

        let database = try LibraryDatabase(
            fileURL: root.appendingPathComponent("Library.sqlite")
        )
        let location = try LibraryLocation(
            kind: .directory,
            bookmarkData: Data("bookmark".utf8),
            bookmarkKind: .regular,
            fallbackPath: libraryRoot.path,
            displayName: "External Music"
        )
        XCTAssertTrue(try database.upsertLibraryLocation(
            LibraryLocationRecord(location: location, updatedAt: Date()),
            expectedRevision: 0,
            nextRevision: 1
        ))

        let oldPath = libraryRoot.appendingPathComponent("Old/song.mp3").path
        let playlist = UserPlaylist(
            name: "External",
            tracks: [.init(
                path: oldPath,
                signature: syntheticSignature(path: oldPath, identity: "external-file"),
                locationID: location.id,
                relativePath: "Old/song.mp3"
            )]
        )
        let store = PlaylistsStore(
            libraryDatabase: database,
            playbackWeights: PlaybackWeights(
                cacheFileURLOverride: root.appendingPathComponent("weights.json")
            ),
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        let result = store.relocateMissingTracksResult(using: [
            FileRelocationCandidate(
                url: outsideURL,
                signature: syntheticSignature(path: outsideURL.path, identity: "external-file")
            )
        ])
        guard case .unchanged(let summary) = result else {
            return XCTFail("candidate outside the stored root must be ignored")
        }
        XCTAssertEqual(summary.relocatedTrackCount, 0)
        XCTAssertEqual(store.playlist(for: playlist.id)?.tracks.first, playlist.tracks.first)
        XCTAssertTrue(store.pendingCleanupIntents.isEmpty)
    }

    @MainActor
    func testAmbiguousSignatureRelocationLeavesMissingPathUntouched() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("missing.mp3").path
        let firstURL = root.appendingPathComponent("first.mp3")
        let secondURL = root.appendingPathComponent("second.mp3")
        try Data("one".utf8).write(to: firstURL)
        try Data("two".utf8).write(to: secondURL)
        let playlist = UserPlaylist(
            name: "Ambiguous",
            tracks: [.init(
                path: oldPath,
                signature: syntheticSignature(path: oldPath, identity: "same")
            )]
        )
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("user-playlists.json"),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        let result = store.relocateMissingTracksResult(using: [
            .init(url: firstURL, signature: syntheticSignature(path: firstURL.path, identity: "same")),
            .init(url: secondURL, signature: syntheticSignature(path: secondURL.path, identity: "same")),
        ])
        guard case .unchanged(let summary) = result else {
            return XCTFail("ambiguous candidates must not mutate the playlist")
        }
        XCTAssertEqual(summary.relocatedTrackCount, 0)
        XCTAssertEqual(store.playlist(for: playlist.id)?.tracks.first?.path, oldPath)
        XCTAssertTrue(store.pendingCleanupIntents.isEmpty)
    }

    @MainActor
    func testRemovingOneDuplicateTrackKeepsOtherIdentityAndPathScopedWeight() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trackURL = root.appendingPathComponent("duplicate.mp3")
        try Data("audio".utf8).write(to: trackURL)
        let first = UserPlaylist.Track(path: trackURL.path)
        let second = UserPlaylist.Track(path: trackURL.path)
        let playlist = UserPlaylist(name: "Duplicates", tracks: [first, second])
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            persistenceDebounceInterval: 60
        )
        XCTAssertEqual(
            weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id)),
            .applied
        )
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        let mutation = store.removeTracksResult(trackIDs: [first.id], from: playlist.id)
        guard case .committed = await store.awaitDurability(of: mutation) else {
            return XCTFail("identity-based duplicate removal must persist")
        }
        XCTAssertEqual(store.playlist(for: playlist.id)?.tracks.map(\.id), [second.id])

        let report = await store.processPendingCleanupIntents()
        XCTAssertTrue(report.sidecarsDurable)
        XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlist.id)), .red)
    }

    @MainActor
    func testDelayedRemovalDoesNotDeleteWeightForReaddedPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trackURL = root.appendingPathComponent("readded.mp3")
        try Data("audio".utf8).write(to: trackURL)
        let original = UserPlaylist.Track(path: trackURL.path)
        let playlist = UserPlaylist(name: "Readd", tracks: [original])
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            persistenceDebounceInterval: 60
        )
        _ = weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [original.id], from: playlist.id)
        ) else {
            return XCTFail("removal must persist")
        }
        guard case .committed = await store.awaitDurability(
            of: await store.addTracksResult([trackURL], to: playlist.id)
        ) else {
            return XCTFail("re-add must persist")
        }

        let report = await store.processPendingCleanupIntents()
        XCTAssertTrue(
            report.sidecarsDurable,
            "report=\(report), state=\(store.persistenceState), pending=\(store.pendingCleanupIntents.count)"
        )
        XCTAssertEqual(store.playlist(for: playlist.id)?.tracks.count, 1)
        XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlist.id)), .red)
    }

    @MainActor
    func testCleanupInFlightDoesNotDeleteWeightForReaddedPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trackURL = root.appendingPathComponent("in-flight-readd.mp3")
        try Data("audio".utf8).write(to: trackURL)
        let originalTrack = UserPlaylist.Track(path: trackURL.path)
        let playlist = UserPlaylist(name: "In Flight", tracks: [originalTrack])
        let weightsURL = root.appendingPathComponent("weights.json")
        let writer = ControlledPlaybackWeightsWriter()
        let weights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            fileWriter: writer.write,
            persistenceDebounceInterval: 60,
            maximumAutomaticRetryAttempts: 0
        )
        _ = weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])
        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [originalTrack.id], from: playlist.id)
        ) else {
            return XCTFail("removal intent must be durable before cleanup")
        }

        writer.armBlockingWrite()
        defer { writer.releaseBlockedWrite() }
        let cleanupTask = Task { @MainActor in
            await store.processPendingCleanupIntents()
        }
        try await waitUntilWriterBlocks(writer)

        guard case .committed = await store.awaitDurability(
            of: await store.addTracksResult([trackURL], to: playlist.id)
        ) else {
            return XCTFail("re-add during sidecar flush must persist")
        }
        XCTAssertEqual(
            weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id)),
            .applied
        )
        writer.releaseBlockedWrite()

        let interruptedReport = await cleanupTask.value
        XCTAssertFalse(interruptedReport.sidecarsDurable)
        XCTAssertEqual(store.pendingCleanupIntents.count, 1)

        let retryReport = await store.processPendingCleanupIntents()
        XCTAssertTrue(
            retryReport.sidecarsDurable,
            "report=\(retryReport), state=\(store.persistenceState), pending=\(store.pendingCleanupIntents.count)"
        )
        XCTAssertTrue(
            store.pendingCleanupIntents.isEmpty,
            "state=\(store.persistenceState), pending=\(store.pendingCleanupIntents.count)"
        )
        XCTAssertEqual(store.playlist(for: playlist.id)?.tracks.count, 1)

        let freshWeights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        XCTAssertEqual(
            freshWeights.level(for: trackURL, scope: .playlist(playlist.id)),
            .red,
            "a post-linearization weight must survive cleanup retry"
        )
    }

    @MainActor
    func testConsecutiveRelocationsFoldEntirePathHistory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("A.mp3")
        let secondURL = root.appendingPathComponent("B.mp3")
        let finalURL = root.appendingPathComponent("C.mp3")
        try Data("second".utf8).write(to: secondURL)
        try Data("final".utf8).write(to: finalURL)

        let track = UserPlaylist.Track(
            path: firstURL.path,
            signature: syntheticSignature(path: firstURL.path, identity: "path-chain")
        )
        let playlist = UserPlaylist(name: "Path Chain", tracks: [track])
        let weightsURL = root.appendingPathComponent("weights.json")
        let weights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            persistenceDebounceInterval: 60
        )
        _ = weights.setLevel(.red, for: firstURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let storeURL = root.appendingPathComponent("playlists.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        guard case .committed = await store.awaitDurability(
            of: store.relocateMissingTracksResult(using: [
                .init(
                    url: secondURL,
                    signature: syntheticSignature(path: secondURL.path, identity: "path-chain")
                )
            ])
        ) else {
            return XCTFail("A to B relocation must persist")
        }
        XCTAssertEqual(
            weights.setLevel(.gold, for: secondURL, scope: .playlist(playlist.id)),
            .applied
        )
        try FileManager.default.removeItem(at: secondURL)
        guard case .committed = await store.awaitDurability(
            of: store.relocateMissingTracksResult(using: [
                .init(
                    url: finalURL,
                    signature: syntheticSignature(path: finalURL.path, identity: "path-chain")
                )
            ])
        ) else {
            return XCTFail("B to C relocation must persist")
        }
        XCTAssertEqual(store.pendingCleanupIntents.count, 2)

        let report = await store.processPendingCleanupIntents()
        XCTAssertTrue(report.sidecarsDurable)
        XCTAssertTrue(store.pendingCleanupIntents.isEmpty)
        XCTAssertEqual(weights.level(for: firstURL, scope: .playlist(playlist.id)), .defaultLevel)
        XCTAssertEqual(weights.level(for: secondURL, scope: .playlist(playlist.id)), .defaultLevel)
        XCTAssertEqual(weights.level(for: finalURL, scope: .playlist(playlist.id)), .gold)

        let freshWeights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        XCTAssertEqual(freshWeights.level(for: firstURL, scope: .playlist(playlist.id)), .defaultLevel)
        XCTAssertEqual(freshWeights.level(for: secondURL, scope: .playlist(playlist.id)), .defaultLevel)
        XCTAssertEqual(freshWeights.level(for: finalURL, scope: .playlist(playlist.id)), .gold)
        let reloadedStore = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: freshWeights,
            automaticallyProcessesCleanup: false
        )
        await reloadedStore.ensureLoaded()
        XCTAssertTrue(reloadedStore.pendingCleanupIntents.isEmpty)
        XCTAssertEqual(reloadedStore.playlist(for: playlist.id)?.tracks.first?.path, finalURL.path)
    }

    @MainActor
    func testRemovalAfterRelocationCleansTheWholeHistoricalChain() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("before.mp3")
        let relocatedURL = root.appendingPathComponent("after.mp3")
        try Data("relocated".utf8).write(to: relocatedURL)
        let track = UserPlaylist.Track(
            path: oldURL.path,
            signature: syntheticSignature(path: oldURL.path, identity: "remove-chain")
        )
        let playlist = UserPlaylist(name: "Remove Chain", tracks: [track])
        let weightsURL = root.appendingPathComponent("weights.json")
        let weights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            persistenceDebounceInterval: 60
        )
        _ = weights.setLevel(.red, for: oldURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])

        guard case .committed = await store.awaitDurability(
            of: store.relocateMissingTracksResult(using: [
                .init(
                    url: relocatedURL,
                    signature: syntheticSignature(
                        path: relocatedURL.path,
                        identity: "remove-chain"
                    )
                )
            ])
        ), let relocatedTrack = store.playlist(for: playlist.id)?.tracks.first else {
            return XCTFail("relocation must persist before removal")
        }
        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [relocatedTrack.id], from: playlist.id)
        ) else {
            return XCTFail("removal must preserve the earlier relocation debt")
        }

        let report = await store.processPendingCleanupIntents()
        XCTAssertTrue(report.sidecarsDurable)
        XCTAssertTrue(store.pendingCleanupIntents.isEmpty)
        let freshWeights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        XCTAssertEqual(freshWeights.level(for: oldURL, scope: .playlist(playlist.id)), .defaultLevel)
        XCTAssertEqual(
            freshWeights.level(for: relocatedURL, scope: .playlist(playlist.id)),
            .defaultLevel
        )
    }

    @MainActor
    func testFailedSidecarFlushKeepsIntentForRestartAndDurableAck() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trackURL = root.appendingPathComponent("restart.mp3")
        try Data("audio".utf8).write(to: trackURL)
        let track = UserPlaylist.Track(path: trackURL.path)
        let playlist = UserPlaylist(name: "Restart", tracks: [track])
        let weightsURL = root.appendingPathComponent("weights.json")
        let writer = ControlledPlaybackWeightsWriter()
        let weights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            fileWriter: writer.write,
            persistenceDebounceInterval: 60,
            maximumAutomaticRetryAttempts: 0
        )
        _ = weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let storeURL = root.appendingPathComponent("playlists.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: weights,
            automaticallyProcessesCleanup: false
        )
        store.debugSetPlaylistsForTesting([playlist])
        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [track.id], from: playlist.id)
        ) else {
            return XCTFail("removal intent must persist before cleanup")
        }

        writer.armFailingWrite()
        let failedReport = await store.processPendingCleanupIntents()
        XCTAssertFalse(failedReport.sidecarsDurable)
        XCTAssertEqual(store.pendingCleanupIntents.count, 1)

        let restartedWeights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        XCTAssertEqual(
            restartedWeights.level(for: trackURL, scope: .playlist(playlist.id)),
            .red,
            "a failed sidecar write must leave the durable cache unchanged"
        )
        let restartedStore = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: restartedWeights,
            automaticallyProcessesCleanup: false
        )
        await restartedStore.ensureLoaded()
        XCTAssertEqual(restartedStore.pendingCleanupIntents.count, 1)

        let retryReport = await restartedStore.processPendingCleanupIntents()
        XCTAssertTrue(retryReport.sidecarsDurable)
        XCTAssertTrue(restartedStore.pendingCleanupIntents.isEmpty)
        let durableWeights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        XCTAssertEqual(
            durableWeights.level(for: trackURL, scope: .playlist(playlist.id)),
            .defaultLevel
        )
        let acknowledgedStore = PlaylistsStore(
            playlistsFileURLOverride: storeURL,
            playbackWeights: durableWeights,
            automaticallyProcessesCleanup: false
        )
        await acknowledgedStore.ensureLoaded()
        XCTAssertTrue(acknowledgedStore.pendingCleanupIntents.isEmpty)
    }

    @MainActor
    func testAutomaticCleanupKeepsMaintenanceRetryAfterFastBackoffIsExhausted() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trackURL = root.appendingPathComponent("maintenance-retry.mp3")
        try Data("audio".utf8).write(to: trackURL)
        let track = UserPlaylist.Track(path: trackURL.path)
        let playlist = UserPlaylist(name: "Maintenance Retry", tracks: [track])
        let weightsURL = root.appendingPathComponent("weights.json")
        let writer = ControlledPlaybackWeightsWriter()
        let weights = PlaybackWeights(
            cacheFileURLOverride: weightsURL,
            fileWriter: writer.write,
            persistenceDebounceInterval: 60,
            maximumAutomaticRetryAttempts: 0
        )
        _ = weights.setLevel(.red, for: trackURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let baselineWriteCount = writer.writeCount

        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            artworkStore: PlaylistArtworkStore(
                customDirectoryOverride: root.appendingPathComponent("artwork")
            ),
            automaticallyProcessesCleanup: true,
            cleanupRetryDelays: [0.005, 0.005, 0.005],
            cleanupMaintenanceRetryDelay: 0.005
        )
        store.debugSetPlaylistsForTesting([playlist])
        writer.armFailingWrites(4)

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [track.id], from: playlist.id)
        ) else {
            return XCTFail("removal intent must be durable before automatic cleanup")
        }

        let deadline = Date().addingTimeInterval(2)
        while !store.pendingCleanupIntents.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(
            store.pendingCleanupIntents.isEmpty,
            "cleanup must continue after the three fast retries are exhausted"
        )
        XCTAssertEqual(
            writer.writeCount,
            baselineWriteCount + 5,
            "four failed passes should be followed by exactly one maintenance retry"
        )
        let freshWeights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        XCTAssertEqual(
            freshWeights.level(for: trackURL, scope: .playlist(playlist.id)),
            .defaultLevel
        )
    }

    @MainActor
    func testNewDurableIntentWakesLongMaintenanceSleep() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("maintenance-first.mp3")
        let secondURL = root.appendingPathComponent("maintenance-second.mp3")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let firstTrack = UserPlaylist.Track(path: firstURL.path)
        let secondTrack = UserPlaylist.Track(path: secondURL.path)
        let playlist = UserPlaylist(
            name: "Wake Maintenance",
            tracks: [firstTrack, secondTrack]
        )
        let writer = ControlledPlaybackWeightsWriter()
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            fileWriter: writer.write,
            persistenceDebounceInterval: 60,
            maximumAutomaticRetryAttempts: 0
        )
        _ = weights.setLevel(.red, for: firstURL, scope: .playlist(playlist.id))
        _ = weights.setLevel(.red, for: secondURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)
        let baselineWriteCount = writer.writeCount

        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            automaticallyProcessesCleanup: true,
            cleanupRetryDelays: [0.005],
            cleanupMaintenanceRetryDelay: 60
        )
        defer { store.prepareForImmediateTermination() }
        store.debugSetPlaylistsForTesting([playlist])
        writer.armFailingWrites(2)

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [firstTrack.id], from: playlist.id)
        ) else {
            return XCTFail("the first cleanup intent must be durable")
        }
        let enteredMaintenanceSleep = await waitUntil {
            store.debugIsCleanupMaintenanceRetryWaitingForTesting
        }
        XCTAssertTrue(enteredMaintenanceSleep)
        XCTAssertEqual(writer.writeCount, baselineWriteCount + 2)

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [secondTrack.id], from: playlist.id)
        ) else {
            return XCTFail("the new cleanup intent must be durable")
        }

        let maintenanceWasWoken = await waitUntil(timeout: 2) {
            store.pendingCleanupIntents.isEmpty
        }
        XCTAssertTrue(
            maintenanceWasWoken,
            "a durable new intent must wake the 60-second maintenance sleep"
        )
        XCTAssertFalse(store.debugIsCleanupMaintenanceRetryWaitingForTesting)
        XCTAssertEqual(writer.writeCount, baselineWriteCount + 3)
    }

    @MainActor
    func testNewDurableIntentDoesNotCancelActiveCleanupPass() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("active-first.mp3")
        let secondURL = root.appendingPathComponent("active-second.mp3")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let firstTrack = UserPlaylist.Track(path: firstURL.path)
        let secondTrack = UserPlaylist.Track(path: secondURL.path)
        let playlist = UserPlaylist(
            name: "Keep Active Pass",
            tracks: [firstTrack, secondTrack]
        )
        let writer = ControlledPlaybackWeightsWriter()
        let weights = PlaybackWeights(
            cacheFileURLOverride: root.appendingPathComponent("weights.json"),
            fileWriter: writer.write,
            persistenceDebounceInterval: 60,
            maximumAutomaticRetryAttempts: 0
        )
        _ = weights.setLevel(.red, for: firstURL, scope: .playlist(playlist.id))
        _ = weights.setLevel(.red, for: secondURL, scope: .playlist(playlist.id))
        XCTAssertTrue(weights.flushPersistence().isDurable)

        let store = PlaylistsStore(
            playlistsFileURLOverride: root.appendingPathComponent("playlists.json"),
            playbackWeights: weights,
            automaticallyProcessesCleanup: true,
            cleanupRetryDelays: [0.005],
            cleanupMaintenanceRetryDelay: 60
        )
        defer {
            writer.releaseBlockedWrite()
            store.prepareForImmediateTermination()
        }
        store.debugSetPlaylistsForTesting([playlist])
        writer.armBlockingWrite()

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [firstTrack.id], from: playlist.id)
        ) else {
            return XCTFail("the first cleanup intent must be durable")
        }
        try await waitUntilWriterBlocks(writer)
        XCTAssertTrue(store.debugIsAutomaticCleanupProcessingForTesting)

        guard case .committed = await store.awaitDurability(
            of: store.removeTracksResult(trackIDs: [secondTrack.id], from: playlist.id)
        ) else {
            return XCTFail("the second cleanup intent must be durable")
        }
        XCTAssertTrue(writer.isBlocked)
        XCTAssertTrue(store.debugIsAutomaticCleanupProcessingForTesting)
        XCTAssertFalse(store.debugAutomaticCleanupProcessingIsCancelledForTesting)

        writer.releaseBlockedWrite()
        let activePassFinished = await waitUntil(timeout: 2) {
            store.pendingCleanupIntents.isEmpty
        }
        XCTAssertTrue(
            activePassFinished,
            "the active pass may finish, then a fresh pass must acknowledge both intents"
        )
    }

    private func syntheticSignature(path: String, identity: String) -> FileSignature {
        FileSignature(
            pathKey: PathKey.canonical(path: path),
            size: 123,
            modificationTimeNanoseconds: 456,
            inode: 789,
            fileResourceIdentifier: identity,
            volumeIdentifier: "test-volume"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlists-durability-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntilWriterBlocks(
        _ writer: ControlledPlaybackWeightsWriter
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !writer.isBlocked, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(writer.isBlocked, "timed out waiting for the injected write barrier")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}
