import Foundation
import XCTest
@testable import MusicPlayer

final class PlaybackSessionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MusicPlayer-PlaybackSessionStore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testLoadsAndIndependentlyMergesOneDatabaseSession() throws {
        let database = try LibraryDatabase(
            fileURL: directory.appendingPathComponent("Library.sqlite", isDirectory: false)
        )
        defer { database.close() }

        let oldQueueEntryID = UUID()
        try database.storePlaybackSession(
            LibraryPlaybackSession(
                revision: 7,
                scope: .queue,
                playlistID: nil,
                scopeTrackID: nil,
                queueEntryID: oldQueueEntryID,
                fallbackPath: "/Music/Old.mp3",
                positionMilliseconds: 2_000
            )
        )

        let store = PlaybackSessionStore(
            libraryDatabase: database,
            debounceInterval: 60,
            maximumAutomaticRetryAttempts: 0
        )
        XCTAssertEqual(
            store.snapshot,
            PlaybackSessionStore.Snapshot(
                revision: 7,
                scope: .queue,
                installedTrack: .init(
                    queueEntryID: oldQueueEntryID,
                    scopeTrackID: nil,
                    fallbackPath: "/Music/Old.mp3"
                ),
                positionMilliseconds: 2_000
            )
        )
        XCTAssertEqual(store.persistenceState, .ready(durableRevision: 7))

        let playlistID = UUID()
        let playlistTrackID = UUID()
        let queueEntryID = UUID()
        assertApplied(
            store.mergeInstalledTrack(
                queueEntryID: queueEntryID,
                scopeTrackID: playlistTrackID,
                fallbackPath: "/Music/New.mp3"
            ),
            revision: 8
        )
        XCTAssertEqual(store.snapshot.scope, .queue)
        XCTAssertEqual(store.snapshot.installedTrack.scopeTrackID, playlistTrackID)
        assertApplied(store.mergePosition(milliseconds: 12_345), revision: 9)
        assertApplied(store.mergeScope(.playlist(playlistID)), revision: 10)
        XCTAssertEqual(store.snapshot.installedTrack.scopeTrackID, playlistTrackID)
        XCTAssertEqual(
            store.mergePosition(milliseconds: 12_345),
            .unchanged(store.snapshot)
        )
        XCTAssertEqual(store.persistenceState, .dirty(revision: 10, lastFailure: nil))

        let flush = store.flush(timeout: 2)
        XCTAssertEqual(flush.outcome, .durable)
        XCTAssertEqual(flush.targetRevision, 10)
        XCTAssertEqual(flush.durableRevision, 10)
        XCTAssertTrue(flush.isDurable)
        XCTAssertEqual(store.persistenceState, .ready(durableRevision: 10))
        XCTAssertEqual(
            try database.loadPlaybackSession(),
            LibraryPlaybackSession(
                revision: 10,
                scope: .playlist,
                playlistID: playlistID,
                scopeTrackID: playlistTrackID,
                queueEntryID: queueEntryID,
                fallbackPath: "/Music/New.mp3",
                positionMilliseconds: 12_345
            )
        )
    }

    func testConcurrentMergesAreThreadSafeAndRevisionNeverMovesBackward() {
        let backend = SessionBackend(
            initialSession: LibraryPlaybackSession(
                revision: 50,
                scope: .queue,
                playlistID: nil,
                scopeTrackID: nil,
                queueEntryID: nil,
                fallbackPath: nil,
                positionMilliseconds: 0
            )
        )
        let store = makeStore(backend: backend, debounceInterval: 60)
        let appliedRevisions = LockedRevisions()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "MusicPlayer.PlaybackSessionStoreTests.ConcurrentMerge",
            attributes: .concurrent
        )

        for value in 1...100 {
            group.enter()
            queue.async {
                if case .applied(let snapshot) = store.mergePosition(milliseconds: Int64(value)) {
                    appliedRevisions.append(snapshot.revision)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let revisions = appliedRevisions.values.sorted()
        XCTAssertEqual(revisions, Array(51...150).map(UInt64.init))
        XCTAssertEqual(store.snapshot.revision, 150)
        XCTAssertEqual(store.mergePosition(milliseconds: -1), .rejectedInvalid)
        XCTAssertEqual(store.snapshot.revision, 150)

        let flush = store.flush(timeout: 2)
        XCTAssertTrue(flush.isDurable)
        XCTAssertEqual(backend.persistedRevisions, [150])
        XCTAssertEqual(backend.expectedRevisions, [50])
        XCTAssertEqual(backend.session?.revision, 150)
    }

    func testFailedFlushStaysDirtyAndRetriesTheSameRevision() {
        let backend = SessionBackend(failFirstWrites: 1)
        let store = makeStore(backend: backend, debounceInterval: 60)
        assertApplied(store.mergePosition(milliseconds: 4_200), revision: 1)

        let failed = store.flush(timeout: 2)
        XCTAssertEqual(failed.outcome, .failed(.writeFailed))
        XCTAssertEqual(failed.targetRevision, 1)
        XCTAssertEqual(failed.durableRevision, 0)
        XCTAssertTrue(failed.hasPendingChanges)
        XCTAssertEqual(
            store.persistenceState,
            .dirty(revision: 1, lastFailure: .writeFailed)
        )

        let retried = store.flush(timeout: 2)
        XCTAssertEqual(retried.outcome, .durable)
        XCTAssertTrue(retried.isDurable)
        XCTAssertEqual(store.snapshot.revision, 1)
        XCTAssertEqual(backend.persistedRevisions, [1, 1])
        XCTAssertEqual(backend.expectedRevisions, [0, 0])
        XCTAssertEqual(backend.session?.revision, 1)
    }

    func testDebouncedWritesRemainSerialWhenNewerStateArrivesDuringACommit() {
        let backend = SessionBackend(blockFirstWrites: 1)
        let store = makeStore(backend: backend, debounceInterval: 0)
        assertApplied(store.mergePosition(milliseconds: 1_000), revision: 1)
        XCTAssertEqual(backend.waitForBlockedWrite(timeout: 2), .success)

        assertApplied(store.mergePosition(milliseconds: 2_000), revision: 2)
        backend.releaseBlockedWrite()

        let flush = store.flush(timeout: 2)
        XCTAssertTrue(flush.isDurable)
        XCTAssertEqual(backend.persistedRevisions, [1, 2])
        XCTAssertEqual(backend.expectedRevisions, [0, 1])
        XCTAssertEqual(backend.maximumConcurrentWrites, 1)
        XCTAssertEqual(backend.session?.positionMilliseconds, 2_000)
    }

    func testDatabaseCASConflictAndStaleResultEnterReloadProtection() {
        let initial = LibraryPlaybackSession(
            revision: 10,
            scope: .queue,
            playlistID: nil,
            scopeTrackID: nil,
            queueEntryID: nil,
            fallbackPath: "/Music/Initial.mp3",
            positionMilliseconds: 0
        )

        let conflictBackend = SessionBackend(initialSession: initial)
        let conflictWinner = makeStore(backend: conflictBackend, debounceInterval: 60)
        let conflictLoser = makeStore(backend: conflictBackend, debounceInterval: 60)
        assertApplied(conflictWinner.mergePosition(milliseconds: 1), revision: 11)
        XCTAssertTrue(conflictWinner.flush(timeout: 2).isDurable)
        assertApplied(conflictLoser.mergePosition(milliseconds: 2), revision: 11)
        XCTAssertEqual(
            conflictLoser.flush(timeout: 2).outcome,
            .rejectedReadOnly(.databaseConflict(storedRevision: 11))
        )
        XCTAssertEqual(conflictBackend.expectedRevisions, [10, 10])

        let staleBackend = SessionBackend(initialSession: initial)
        let staleWinner = makeStore(backend: staleBackend, debounceInterval: 60)
        let staleLoser = makeStore(backend: staleBackend, debounceInterval: 60)
        assertApplied(staleWinner.mergePosition(milliseconds: 1), revision: 11)
        assertApplied(staleWinner.mergePosition(milliseconds: 2), revision: 12)
        XCTAssertTrue(staleWinner.flush(timeout: 2).isDurable)
        assertApplied(staleLoser.mergePosition(milliseconds: 3), revision: 11)
        XCTAssertEqual(
            staleLoser.flush(timeout: 2).outcome,
            .rejectedReadOnly(.databaseConflict(storedRevision: 12))
        )
        XCTAssertEqual(staleBackend.expectedRevisions, [10, 10])
    }

    func testFutureAndForeignDatabasesAreReadOnly() {
        let futureBackend = SessionBackend(
            initialSession: LibraryPlaybackSession(
                revision: 4,
                scope: .queue,
                playlistID: nil,
                scopeTrackID: nil,
                queueEntryID: nil,
                fallbackPath: "/Music/Future.mp3",
                positionMilliseconds: 90
            )
        )
        let future = makeStore(
            backend: futureBackend,
            accessMode: .readOnlyFuture(version: 9)
        )
        XCTAssertEqual(future.snapshot.revision, 4)
        XCTAssertEqual(future.persistenceState, .readOnly(.futureSchema(9)))
        XCTAssertEqual(
            future.mergePosition(milliseconds: 100),
            .rejectedReadOnly(.futureSchema(9))
        )
        XCTAssertEqual(
            future.flush().outcome,
            .rejectedReadOnly(.futureSchema(9))
        )
        XCTAssertEqual(futureBackend.persistedRevisions, [])

        let foreignBackend = SessionBackend()
        let foreign = makeStore(
            backend: foreignBackend,
            accessMode: .readOnlyForeign(applicationID: 0x1234)
        )
        XCTAssertEqual(foreignBackend.loadCount, 0)
        XCTAssertEqual(foreign.persistenceState, .readOnly(.foreignDatabase(0x1234)))
        XCTAssertEqual(
            foreign.mergeScope(.queue),
            .rejectedReadOnly(.foreignDatabase(0x1234))
        )
        XCTAssertEqual(
            foreign.flush().outcome,
            .rejectedReadOnly(.foreignDatabase(0x1234))
        )
        XCTAssertEqual(foreignBackend.persistedRevisions, [])
    }

    func testFlushWaitIsAbsolutelyBoundedToSevenHundredFiftyMilliseconds() {
        let backend = SessionBackend(blockFirstWrites: 1)
        let store = makeStore(backend: backend, debounceInterval: 60)
        assertApplied(store.mergePosition(milliseconds: 750), revision: 1)

        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = store.flush(timeout: 0.75)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(elapsed, 0.65)
        XCTAssertLessThan(elapsed, 1.25)
        XCTAssertTrue(result.hasPendingChanges)
        XCTAssertEqual(backend.waitForBlockedWrite(timeout: 0.1), .success)

        backend.releaseBlockedWrite()
        let drained = store.flush(timeout: 2)
        XCTAssertTrue(drained.isDurable)
        XCTAssertEqual(backend.maximumConcurrentWrites, 1)
    }

    private func makeStore(
        backend: SessionBackend,
        accessMode: PlaybackSessionStore.AccessMode = .writable,
        debounceInterval: TimeInterval = 60
    ) -> PlaybackSessionStore {
        PlaybackSessionStore(
            accessMode: accessMode,
            debounceInterval: debounceInterval,
            retryBaseInterval: 0,
            maximumAutomaticRetryAttempts: 0,
            load: { try backend.load() },
            persist: { try backend.persist($0, expectedRevision: $1) }
        )
    }

    private func assertApplied(
        _ result: PlaybackSessionStore.MergeResult,
        revision: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .applied(let snapshot) = result else {
            XCTFail("Expected an applied merge, got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(snapshot.revision, revision, file: file, line: line)
    }
}

private final class LockedRevisions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ revision: UInt64) {
        lock.lock()
        storage.append(revision)
        lock.unlock()
    }
}

private final class SessionBackend: @unchecked Sendable {
    enum Failure: Error {
        case requested
    }

    private let lock = NSLock()
    private let blockedWriteStarted = DispatchSemaphore(value: 0)
    private let blockedWriteRelease = DispatchSemaphore(value: 0)
    private var sessionValue: LibraryPlaybackSession?
    private var persistedRevisionValues: [UInt64] = []
    private var expectedRevisionValues: [UInt64] = []
    private var remainingFailures: Int
    private var remainingBlocks: Int
    private var loadCountValue = 0
    private var concurrentWrites = 0
    private var maximumConcurrentWritesValue = 0

    init(
        initialSession: LibraryPlaybackSession? = nil,
        failFirstWrites: Int = 0,
        blockFirstWrites: Int = 0
    ) {
        sessionValue = initialSession
        remainingFailures = max(0, failFirstWrites)
        remainingBlocks = max(0, blockFirstWrites)
    }

    var session: LibraryPlaybackSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionValue
    }

    var persistedRevisions: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return persistedRevisionValues
    }

    var expectedRevisions: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return expectedRevisionValues
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCountValue
    }

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumConcurrentWritesValue
    }

    func load() throws -> LibraryPlaybackSession? {
        lock.lock()
        defer { lock.unlock() }
        loadCountValue += 1
        return sessionValue
    }

    func persist(
        _ session: LibraryPlaybackSession,
        expectedRevision: UInt64
    ) throws -> LibraryRevisionCommitResult {
        let shouldFail: Bool
        let shouldBlock: Bool
        lock.lock()
        persistedRevisionValues.append(session.revision)
        expectedRevisionValues.append(expectedRevision)
        concurrentWrites += 1
        maximumConcurrentWritesValue = max(maximumConcurrentWritesValue, concurrentWrites)
        shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        shouldBlock = remainingBlocks > 0
        if shouldBlock { remainingBlocks -= 1 }
        lock.unlock()

        defer {
            lock.lock()
            concurrentWrites -= 1
            lock.unlock()
        }
        if shouldBlock {
            blockedWriteStarted.signal()
            blockedWriteRelease.wait()
        }
        if shouldFail { throw Failure.requested }

        lock.lock()
        let storedRevision = sessionValue?.revision ?? 0
        if session.revision == storedRevision, let sessionValue {
            let result: LibraryRevisionCommitResult = sessionValue == session
                ? .alreadyCurrent(revision: storedRevision)
                : .conflict(revision: storedRevision)
            lock.unlock()
            return result
        }
        if expectedRevision != storedRevision || session.revision < storedRevision {
            lock.unlock()
            return .stale(storedRevision: storedRevision)
        }
        sessionValue = session
        lock.unlock()
        return .committed(revision: session.revision)
    }

    func waitForBlockedWrite(timeout: TimeInterval) -> DispatchTimeoutResult {
        blockedWriteStarted.wait(timeout: .now() + timeout)
    }

    func releaseBlockedWrite() {
        blockedWriteRelease.signal()
    }
}
