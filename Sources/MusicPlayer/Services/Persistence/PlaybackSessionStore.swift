import Foundation

/// Thread-safe aggregation and persistence for the single resumable playback
/// session. Callers may merge scope, installed-track identity, and position from
/// different components without transferring their ownership to a main actor.
final class PlaybackSessionStore: @unchecked Sendable {
    enum Scope: Equatable, Sendable {
        case queue
        case playlist(UUID)
    }

    struct InstalledTrack: Equatable, Sendable {
        let queueEntryID: UUID?
        let scopeTrackID: UUID?
        let fallbackPath: String?

        static let empty = InstalledTrack(
            queueEntryID: nil,
            scopeTrackID: nil,
            fallbackPath: nil
        )

        init(
            queueEntryID: UUID?,
            scopeTrackID: UUID?,
            fallbackPath: String?
        ) {
            self.queueEntryID = queueEntryID
            self.scopeTrackID = scopeTrackID
            self.fallbackPath = fallbackPath
        }
    }

    struct Snapshot: Equatable, Sendable {
        let revision: UInt64
        let scope: Scope
        let installedTrack: InstalledTrack
        let positionMilliseconds: Int64
    }

    enum AccessMode: Equatable, Sendable {
        case writable
        case readOnlyFuture(version: Int)
        case readOnlyForeign(applicationID: Int32)
    }

    enum ReadOnlyReason: Equatable, Sendable {
        case futureSchema(Int)
        case foreignDatabase(Int32)
        case unreadable
        case revisionExhausted
        case databaseConflict(storedRevision: UInt64)
    }

    enum PersistenceFailure: Equatable, Sendable {
        case incompletePlaylistIdentity
        case writeFailed
        case reentrantFlush
    }

    enum PersistenceState: Equatable, Sendable {
        case ready(durableRevision: UInt64)
        case dirty(revision: UInt64, lastFailure: PersistenceFailure?)
        case readOnly(ReadOnlyReason)
    }

    enum MergeResult: Equatable, Sendable {
        case applied(Snapshot)
        case unchanged(Snapshot)
        case rejectedReadOnly(ReadOnlyReason)
        case rejectedInvalid
    }

    struct FlushResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case durable
            case alreadyCurrent
            case failed(PersistenceFailure)
            case timedOut
            case rejectedReadOnly(ReadOnlyReason)
        }

        let outcome: Outcome
        let targetRevision: UInt64
        let durableRevision: UInt64
        let hasPendingChanges: Bool

        var isDurable: Bool {
            switch outcome {
            case .durable, .alreadyCurrent:
                return !hasPendingChanges
            case .failed, .timedOut, .rejectedReadOnly:
                return false
            }
        }
    }

    private static let maximumPathBytes = 16 * 1_024
    private static let maximumRevision = UInt64(Int64.max)

    private let stateLock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "MusicPlayer.PlaybackSessionStore.Persistence",
        qos: .utility
    )
    private let persistenceQueueKey = DispatchSpecificKey<Void>()
    private let loadSession: @Sendable () throws -> LibraryPlaybackSession?
    private let persistSession: @Sendable (
        LibraryPlaybackSession,
        UInt64
    ) throws -> LibraryRevisionCommitResult
    private let debounceInterval: TimeInterval
    private let retryBaseInterval: TimeInterval
    private let maximumAutomaticRetryAttempts: Int

    private var snapshotValue = Snapshot(
        revision: 0,
        scope: .queue,
        installedTrack: .empty,
        positionMilliseconds: 0
    )
    private var durableRevision: UInt64 = 0
    private var stateValue: PersistenceState = .ready(durableRevision: 0)
    private let accessMode: AccessMode
    private var scheduleGeneration: UInt64 = 0
    private var pendingWorkItem: DispatchWorkItem?
    private var automaticRetryAttempt = 0
    private var lastFailedRevision: UInt64?
    private var lastFailure: PersistenceFailure?

    convenience init(
        libraryDatabase: LibraryDatabase,
        debounceInterval: TimeInterval = 0.35,
        retryBaseInterval: TimeInterval = 1,
        maximumAutomaticRetryAttempts: Int = 3
    ) {
        let accessMode: AccessMode
        switch libraryDatabase.accessMode {
        case .writable:
            accessMode = .writable
        case .readOnlyFuture(let version):
            accessMode = .readOnlyFuture(version: version)
        case .readOnlyForeign(let applicationID):
            accessMode = .readOnlyForeign(applicationID: applicationID)
        }
        self.init(
            accessMode: accessMode,
            debounceInterval: debounceInterval,
            retryBaseInterval: retryBaseInterval,
            maximumAutomaticRetryAttempts: maximumAutomaticRetryAttempts,
            load: { try libraryDatabase.loadPlaybackSession() },
            persist: { session, expectedRevision in
                try libraryDatabase.storePlaybackSession(
                    session,
                    expectedRevision: expectedRevision
                )
            }
        )
    }

    /// Injectable backend initializer used by focused persistence tests and by
    /// alternate production composition roots. The LibraryDatabase initializer
    /// above remains the normal application entry point.
    init(
        accessMode: AccessMode = .writable,
        debounceInterval: TimeInterval = 0.35,
        retryBaseInterval: TimeInterval = 1,
        maximumAutomaticRetryAttempts: Int = 3,
        load: @escaping @Sendable () throws -> LibraryPlaybackSession?,
        persist: @escaping @Sendable (
            LibraryPlaybackSession,
            UInt64
        ) throws -> LibraryRevisionCommitResult
    ) {
        self.accessMode = accessMode
        self.debounceInterval = Self.sanitizedDelay(debounceInterval)
        self.retryBaseInterval = Self.sanitizedDelay(retryBaseInterval)
        self.maximumAutomaticRetryAttempts = max(0, maximumAutomaticRetryAttempts)
        self.loadSession = load
        self.persistSession = persist
        persistenceQueue.setSpecific(key: persistenceQueueKey, value: ())
        loadInitialSession()
    }

    deinit {
        stateLock.lock()
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        stateLock.unlock()
    }

    var snapshot: Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotValue
    }

    var persistenceState: PersistenceState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateValue
    }

    var hasPendingPersistence: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotValue.revision > durableRevision
    }

    @discardableResult
    func mergeScope(_ scope: Scope) -> MergeResult {
        mutate { snapshot in
            guard snapshot.scope != scope else { return false }
            snapshot = Snapshot(
                revision: snapshot.revision,
                scope: scope,
                installedTrack: snapshot.installedTrack,
                positionMilliseconds: snapshot.positionMilliseconds
            )
            return true
        }
    }

    @discardableResult
    func mergeInstalledTrack(_ installedTrack: InstalledTrack) -> MergeResult {
        guard Self.isValidFallbackPath(installedTrack.fallbackPath) else {
            return .rejectedInvalid
        }
        return mutate { snapshot in
            guard snapshot.installedTrack != installedTrack else { return false }
            snapshot = Snapshot(
                revision: snapshot.revision,
                scope: snapshot.scope,
                installedTrack: installedTrack,
                positionMilliseconds: snapshot.positionMilliseconds
            )
            return true
        }
    }

    @discardableResult
    func mergeInstalledTrack(
        queueEntryID: UUID?,
        scopeTrackID: UUID?,
        fallbackPath: String?
    ) -> MergeResult {
        mergeInstalledTrack(
            InstalledTrack(
                queueEntryID: queueEntryID,
                scopeTrackID: scopeTrackID,
                fallbackPath: fallbackPath
            )
        )
    }

    @discardableResult
    func mergePosition(milliseconds: Int64) -> MergeResult {
        guard milliseconds >= 0 else { return .rejectedInvalid }
        return mutate { snapshot in
            guard snapshot.positionMilliseconds != milliseconds else { return false }
            snapshot = Snapshot(
                revision: snapshot.revision,
                scope: snapshot.scope,
                installedTrack: snapshot.installedTrack,
                positionMilliseconds: milliseconds
            )
            return true
        }
    }

    /// Flushes the snapshot observed at entry. The absolute deadline bounds only
    /// the caller's wait; a SQLite transaction already in progress is allowed to
    /// finish on the serial persistence queue.
    @discardableResult
    func flush(timeout: TimeInterval = 0.75) -> FlushResult {
        if DispatchQueue.getSpecific(key: persistenceQueueKey) != nil {
            return flushResult(outcome: .failed(.reentrantFlush), targetRevision: snapshot.revision)
        }

        let target: Snapshot
        stateLock.lock()
        if let reason = readOnlyReasonLocked() {
            let result = makeFlushResultLocked(
                outcome: .rejectedReadOnly(reason),
                targetRevision: snapshotValue.revision
            )
            stateLock.unlock()
            return result
        }
        target = snapshotValue
        if target.revision <= durableRevision {
            let result = makeFlushResultLocked(
                outcome: .alreadyCurrent,
                targetRevision: target.revision
            )
            stateLock.unlock()
            return result
        }
        scheduleGeneration &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        automaticRetryAttempt = 0
        stateLock.unlock()

        let completion = DispatchSemaphore(value: 0)
        persistenceQueue.async { [self] in
            commit(target, automaticallyRetrying: false)
            completion.signal()
        }

        let sanitizedTimeout = timeout.isFinite ? max(0, timeout) : 0
        let deadline = DispatchTime.now() + sanitizedTimeout
        guard completion.wait(timeout: deadline) == .success else {
            return flushResult(outcome: .timedOut, targetRevision: target.revision)
        }

        stateLock.lock()
        let outcome: FlushResult.Outcome
        if let reason = readOnlyReasonLocked() {
            outcome = .rejectedReadOnly(reason)
        } else if durableRevision >= target.revision {
            outcome = .durable
        } else if lastFailedRevision == target.revision, let lastFailure {
            outcome = .failed(lastFailure)
        } else {
            outcome = .failed(.writeFailed)
        }
        let result = makeFlushResultLocked(outcome: outcome, targetRevision: target.revision)
        stateLock.unlock()
        return result
    }

    private func loadInitialSession() {
        switch accessMode {
        case .readOnlyForeign(let applicationID):
            stateValue = .readOnly(.foreignDatabase(applicationID))
            return
        case .writable, .readOnlyFuture:
            break
        }

        do {
            if let stored = try loadSession() {
                guard let loaded = Self.snapshot(from: stored) else {
                    setLoadFailureState()
                    return
                }
                snapshotValue = loaded
                durableRevision = stored.revision
            }
            switch accessMode {
            case .writable:
                stateValue = .ready(durableRevision: durableRevision)
            case .readOnlyFuture(let version):
                stateValue = .readOnly(.futureSchema(version))
            case .readOnlyForeign:
                break
            }
        } catch {
            setLoadFailureState()
        }
    }

    private func setLoadFailureState() {
        switch accessMode {
        case .readOnlyFuture(let version):
            stateValue = .readOnly(.futureSchema(version))
        case .writable:
            stateValue = .readOnly(.unreadable)
        case .readOnlyForeign(let applicationID):
            stateValue = .readOnly(.foreignDatabase(applicationID))
        }
    }

    private func mutate(_ body: (inout Snapshot) -> Bool) -> MergeResult {
        stateLock.lock()
        if let reason = readOnlyReasonLocked() {
            stateLock.unlock()
            return .rejectedReadOnly(reason)
        }
        guard snapshotValue.revision < Self.maximumRevision else {
            stateValue = .readOnly(.revisionExhausted)
            stateLock.unlock()
            return .rejectedReadOnly(.revisionExhausted)
        }

        var updated = snapshotValue
        guard body(&updated) else {
            let unchanged = snapshotValue
            stateLock.unlock()
            return .unchanged(unchanged)
        }
        updated = Snapshot(
            revision: snapshotValue.revision + 1,
            scope: updated.scope,
            installedTrack: updated.installedTrack,
            positionMilliseconds: updated.positionMilliseconds
        )
        snapshotValue = updated
        automaticRetryAttempt = 0
        lastFailedRevision = nil
        lastFailure = nil
        stateValue = .dirty(revision: updated.revision, lastFailure: nil)
        stateLock.unlock()

        scheduleDebouncedCommit()
        return .applied(updated)
    }

    private func scheduleDebouncedCommit() {
        let workItem: DispatchWorkItem
        let previous: DispatchWorkItem?
        stateLock.lock()
        guard readOnlyReasonLocked() == nil else {
            stateLock.unlock()
            return
        }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        previous = pendingWorkItem
        workItem = DispatchWorkItem { [weak self] in
            self?.performScheduledCommit(generation: generation)
        }
        pendingWorkItem = workItem
        stateLock.unlock()
        previous?.cancel()
        persistenceQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func performScheduledCommit(generation: UInt64) {
        let target: Snapshot
        stateLock.lock()
        guard generation == scheduleGeneration,
              readOnlyReasonLocked() == nil else {
            stateLock.unlock()
            return
        }
        pendingWorkItem = nil
        target = snapshotValue
        stateLock.unlock()
        commit(target, automaticallyRetrying: true)
    }

    private func commit(_ target: Snapshot, automaticallyRetrying: Bool) {
        guard let stored = Self.storedSession(from: target) else {
            finishFailure(
                .incompletePlaylistIdentity,
                revision: target.revision,
                automaticallyRetrying: false
            )
            return
        }
        do {
            stateLock.lock()
            let expectedRevision = durableRevision
            stateLock.unlock()
            let result = try persistSession(stored, expectedRevision)
            let committedRevision: UInt64
            switch result {
            case .committed(let revision), .alreadyCurrent(let revision):
                committedRevision = revision
            case .stale(let storedRevision):
                finishDatabaseConflict(storedRevision: storedRevision)
                return
            case .conflict(let revision):
                finishDatabaseConflict(storedRevision: revision)
                return
            }
            guard committedRevision == target.revision else {
                finishDatabaseConflict(storedRevision: committedRevision)
                return
            }
            stateLock.lock()
            durableRevision = max(durableRevision, committedRevision)
            if lastFailedRevision.map({ $0 <= durableRevision }) == true {
                lastFailedRevision = nil
                lastFailure = nil
            }
            automaticRetryAttempt = 0
            stateValue = snapshotValue.revision <= durableRevision
                ? .ready(durableRevision: durableRevision)
                : .dirty(revision: snapshotValue.revision, lastFailure: nil)
            stateLock.unlock()
        } catch {
            finishFailure(
                .writeFailed,
                revision: target.revision,
                automaticallyRetrying: automaticallyRetrying
            )
        }
    }

    private func finishDatabaseConflict(storedRevision: UInt64) {
        stateLock.lock()
        scheduleGeneration &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        automaticRetryAttempt = 0
        stateValue = .readOnly(.databaseConflict(storedRevision: storedRevision))
        stateLock.unlock()
    }

    private func finishFailure(
        _ failure: PersistenceFailure,
        revision: UInt64,
        automaticallyRetrying: Bool
    ) {
        var retry: (workItem: DispatchWorkItem, delay: TimeInterval)?
        stateLock.lock()
        if snapshotValue.revision == revision {
            lastFailedRevision = revision
            lastFailure = failure
            stateValue = .dirty(revision: revision, lastFailure: failure)
        }
        if automaticallyRetrying,
           failure == .writeFailed,
           snapshotValue.revision == revision,
           pendingWorkItem == nil,
           automaticRetryAttempt < maximumAutomaticRetryAttempts {
            automaticRetryAttempt += 1
            let attempt = automaticRetryAttempt
            scheduleGeneration &+= 1
            let generation = scheduleGeneration
            let workItem = DispatchWorkItem { [weak self] in
                self?.performScheduledCommit(generation: generation)
            }
            pendingWorkItem = workItem
            retry = (
                workItem,
                retryBaseInterval * pow(2, Double(attempt - 1))
            )
        }
        stateLock.unlock()

        if let retry {
            persistenceQueue.asyncAfter(
                deadline: .now() + retry.delay,
                execute: retry.workItem
            )
        }
    }

    private func readOnlyReasonLocked() -> ReadOnlyReason? {
        if case .readOnly(let reason) = stateValue { return reason }
        return nil
    }

    private func flushResult(
        outcome: FlushResult.Outcome,
        targetRevision: UInt64
    ) -> FlushResult {
        stateLock.lock()
        defer { stateLock.unlock() }
        return makeFlushResultLocked(outcome: outcome, targetRevision: targetRevision)
    }

    private func makeFlushResultLocked(
        outcome: FlushResult.Outcome,
        targetRevision: UInt64
    ) -> FlushResult {
        FlushResult(
            outcome: outcome,
            targetRevision: targetRevision,
            durableRevision: durableRevision,
            hasPendingChanges: snapshotValue.revision > durableRevision
        )
    }

    private static func snapshot(from stored: LibraryPlaybackSession) -> Snapshot? {
        guard stored.revision <= maximumRevision,
              stored.positionMilliseconds >= 0,
              isValidFallbackPath(stored.fallbackPath) else { return nil }
        let scope: Scope
        switch stored.scope {
        case .queue:
            guard stored.playlistID == nil, stored.scopeTrackID == nil else { return nil }
            scope = .queue
        case .playlist:
            guard let playlistID = stored.playlistID,
                  stored.scopeTrackID != nil else { return nil }
            scope = .playlist(playlistID)
        }
        return Snapshot(
            revision: stored.revision,
            scope: scope,
            installedTrack: InstalledTrack(
                queueEntryID: stored.queueEntryID,
                scopeTrackID: stored.scopeTrackID,
                fallbackPath: stored.fallbackPath
            ),
            positionMilliseconds: stored.positionMilliseconds
        )
    }

    private static func storedSession(from snapshot: Snapshot) -> LibraryPlaybackSession? {
        switch snapshot.scope {
        case .queue:
            return LibraryPlaybackSession(
                revision: snapshot.revision,
                scope: .queue,
                playlistID: nil,
                scopeTrackID: nil,
                queueEntryID: snapshot.installedTrack.queueEntryID,
                fallbackPath: snapshot.installedTrack.fallbackPath,
                positionMilliseconds: snapshot.positionMilliseconds
            )
        case .playlist(let playlistID):
            guard let scopeTrackID = snapshot.installedTrack.scopeTrackID else { return nil }
            return LibraryPlaybackSession(
                revision: snapshot.revision,
                scope: .playlist,
                playlistID: playlistID,
                scopeTrackID: scopeTrackID,
                queueEntryID: snapshot.installedTrack.queueEntryID,
                fallbackPath: snapshot.installedTrack.fallbackPath,
                positionMilliseconds: snapshot.positionMilliseconds
            )
        }
    }

    private static func isValidFallbackPath(_ path: String?) -> Bool {
        guard let path else { return true }
        let bytes = path.utf8.count
        return path.hasPrefix("/")
            && bytes > 1
            && bytes <= maximumPathBytes
            && !path.utf8.contains(0)
    }

    private static func sanitizedDelay(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 0 }
        return interval
    }
}
