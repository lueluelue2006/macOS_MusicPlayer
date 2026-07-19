import Foundation
import Darwin

/// Persistent, lightweight per-track playback weight settings.
///
/// Design:
/// - Scoped: queue weights and per-playlist weights are isolated.
/// - Keyed by canonical file path (no bookmarks), with legacy lowercased key compatibility.
/// - Durable, bounded disk persistence (JSON, debounced with explicit flush results).
final class PlaybackWeights: ObservableObject, @unchecked Sendable {
    static let shared = PlaybackWeights()

    struct SyncResult: Sendable {
        let total: Int
        let changed: Int
        let mutationResult: MutationResult
    }

    enum MutationResult: Equatable, Sendable {
        case applied
        case unchanged
        case rejectedReadOnly(ReadOnlyReason)
    }

    enum PersistenceState: Equatable, Sendable {
        case notLoaded
        case loading
        case ready
        case migrated(fromVersion: Int)
        case quarantinedCorrupt(backupURL: URL)
        case readOnlyPreserved(ReadOnlyReason)
    }

    enum ReadOnlyReason: Equatable, Sendable {
        case unsupportedVersion(Int)
        case foreignDatabase(Int32)
        case unreadable
        case quarantineFailed
        case capacityExceeded
        case databaseConflict(storedRevision: UInt64)

        var diagnosticMessage: String {
            switch self {
            case .unsupportedVersion(let version):
                return "权重文件版本 v\(version) 不受支持"
            case .foreignDatabase(let applicationID):
                return "权重数据库标识不匹配（\(applicationID)）"
            case .unreadable:
                return "权重文件不可读"
            case .quarantineFailed:
                return "权重文件损坏且隔离失败"
            case .capacityExceeded:
                return "权重数据超过安全容量上限"
            case .databaseConflict(let storedRevision):
                return "权重数据库已被其他写入更新（修订号 \(storedRevision)），需要重新加载"
            }
        }
    }

    enum PersistenceFailure: Equatable, Sendable {
        case storageUnavailable
        case capacityExceeded
        case writeFailed
    }

    struct PersistenceFlushResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case persisted
            case alreadyCurrent
            case rejectedReadOnly(ReadOnlyReason)
            case failed(PersistenceFailure)
        }

        let outcome: Outcome
        let attemptedGeneration: UInt64
        let durableGeneration: UInt64
        let hasPendingChanges: Bool

        var isDurable: Bool {
            switch outcome {
            case .persisted, .alreadyCurrent:
                return !hasPendingChanges
            case .rejectedReadOnly, .failed:
                return false
            }
        }
    }

    enum Scope: Equatable, Sendable {
        case queue
        case playlist(UserPlaylist.ID)
    }

    struct PlaylistTrackRemoval: Sendable {
        let playlistID: UserPlaylist.ID
        let trackURLs: [URL]

        init(playlistID: UserPlaylist.ID, trackURLs: [URL]) {
            self.playlistID = playlistID
            self.trackURLs = trackURLs
        }
    }

    struct TrackRekey: Sendable {
        let oldURL: URL
        let newURL: URL

        init(oldURL: URL, newURL: URL) {
            self.oldURL = oldURL
            self.newURL = newURL
        }
    }

    enum Level: Int, CaseIterable, Sendable {
        case white = 0
        case green = 1
        case blue = 2
        case purple = 3
        case gold = 4
        case red = 5

        static let defaultLevel: Level = .green
        static let minimumStoredRawValue = Level.white.rawValue
        static let maximumStoredRawValue = Level.red.rawValue

        var multiplier: Double {
            switch self {
            case .white: return 0.5
            case .green: return 1.0
            case .blue: return 1.6
            case .purple: return 3.2
            case .gold: return 4.8
            case .red: return 6.4
            }
        }
    }

    @Published private(set) var revision: UInt64 = 0

    var persistenceState: PersistenceState {
        lock.lock()
        defer { lock.unlock() }
        return _persistenceState
    }

    private let cacheFileName = "playback-weights.json"
    private let formatVersion = 3
    private static let supportedFormatVersions: Set<Int> = [1, 2, 3]
    private static let maximumFileBytes = 16 * 1_024 * 1_024
    private static let maximumPathBytes = 16 * 1_024
    private static let maximumAggregatePathBytes = 12 * 1_024 * 1_024
    private static let maximumQueueEntries = 100_000
    private static let maximumPlaylistCount = 2_000
    private static let maximumEntriesPerPlaylist = 50_000
    private static let maximumTotalEntries = 100_000
    private let libraryDatabase: LibraryDatabase?
    private let cacheFileURLOverride: URL?
    /// Optional legacy hooks are retained for deterministic failure tests. Normal
    /// production IO always goes through `DerivedCacheFileIO`.
    private let fileMover: ((URL, URL) throws -> Void)?
    private let fileWriter: ((Data, URL) throws -> Void)?
    private let persistenceDebounceInterval: TimeInterval
    private let persistenceRetryBaseInterval: TimeInterval
    private let maximumAutomaticRetryAttempts: Int
    private let lock = NSLock()
    private let persistenceLock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "MusicPlayer.PlaybackWeights.Persistence",
        qos: .utility
    )
    private let persistenceQueueKey = DispatchSpecificKey<Void>()

    private struct CacheFile: Codable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    private struct CacheVersionEnvelope: Decodable {
        let version: Int
    }

    private var isLoaded = false
    private var _persistenceState: PersistenceState = .notLoaded
    private var needsReplacementWrite = false
    private var queueLevels: [String: Int] = [:]
    private var playlistLevels: [String: [String: Int]] = [:] // playlistID.uuidString -> (pathKey -> level)
    private var storedEntryCount = 0
    private var storedPathByteCount = 0
    private var logicalRevision: UInt64 = 0
    private var dirtyGeneration: UInt64 = 0
    private var durableGeneration: UInt64 = 0
    /// Last revision actually acknowledged by the authoritative SQLite domain.
    /// It is deliberately separate from the coalesced in-memory generation.
    private var durableDatabaseRevision: UInt64 = 0
    private var lastFailureNotificationGeneration: UInt64?
    private var persistenceRevision: UInt64 = 0
    private var automaticRetryAttempt = 0
    private var pendingSaveWorkItem: DispatchWorkItem?

    init(
        cacheFileURLOverride: URL? = nil,
        fileMover: ((URL, URL) throws -> Void)? = nil,
        fileWriter: ((Data, URL) throws -> Void)? = nil,
        persistenceDebounceInterval: TimeInterval = 0.5,
        persistenceRetryBaseInterval: TimeInterval = 1.0,
        maximumAutomaticRetryAttempts: Int = 3,
        libraryDatabase: LibraryDatabase? = nil
    ) {
        self.libraryDatabase = libraryDatabase
        self.cacheFileURLOverride = cacheFileURLOverride
        self.fileMover = fileMover
        self.fileWriter = fileWriter
        self.persistenceDebounceInterval = max(0, persistenceDebounceInterval)
        self.persistenceRetryBaseInterval = max(0, persistenceRetryBaseInterval)
        self.maximumAutomaticRetryAttempts = max(0, maximumAutomaticRetryAttempts)
        persistenceQueue.setSpecific(key: persistenceQueueKey, value: ())
        loadIfNeeded()
    }

    var hasPendingPersistence: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPersistenceDirtyLocked
    }

    func level(for url: URL, scope: Scope) -> Level {
        guard url.isFileURL, Self.isValidRuntimePath(url.path) else { return .defaultLevel }
        let keys = Self.lookupKeys(for: url)
        if let first = keys.first {
            return level(forLookupKeys: keys, canonicalKey: first, scope: scope)
        }
        return .defaultLevel
    }

    func level(forKey key: String, scope: Scope) -> Level {
        guard Self.isValidRuntimePath(key) else { return .defaultLevel }
        let canonicalKey = PathKey.canonical(path: key)
        return level(
            forLookupKeys: [canonicalKey, PathKey.legacy(path: key)],
            canonicalKey: canonicalKey,
            scope: scope
        )
    }

    private func level(forLookupKeys lookupKeys: [String], canonicalKey: String, scope: Scope) -> Level {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        let raw: Int? = {
            switch scope {
            case .queue:
                return valueWithMigration(in: &queueLevels, lookupKeys: lookupKeys, canonicalKey: canonicalKey)
            case .playlist(let id):
                let pid = id.uuidString
                guard playlistLevels[pid] != nil else { return nil }
                return valueWithMigration(in: &playlistLevels[pid]!, lookupKeys: lookupKeys, canonicalKey: canonicalKey)
            }
        }()
        return Level(rawValue: raw ?? Level.defaultLevel.rawValue) ?? .defaultLevel
    }

    func multiplier(for url: URL, scope: Scope) -> Double {
        level(for: url, scope: scope).multiplier
    }

    func multiplier(forKey key: String, scope: Scope) -> Double {
        level(forKey: key, scope: scope).multiplier
    }

    func setLevel(_ level: Level, for url: URL, scope: Scope) -> MutationResult {
        guard url.isFileURL, Self.isValidRuntimePath(url.path) else {
            return .rejectedReadOnly(.capacityExceeded)
        }
        let key = Self.key(for: url)
        return setLevelRaw(level.rawValue, forKey: key, scope: scope)
    }

    func setLevelRaw(_ raw: Int, forKey key: String, scope: Scope) -> MutationResult {
        loadIfNeeded()

        guard Self.isValidRuntimePath(key) else {
            return .rejectedReadOnly(.capacityExceeded)
        }
        let canonicalKey = PathKey.canonical(path: key)
        let clamped = normalizedStoredRaw(raw)
        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        switch scope {
        case .queue:
            let projection = Self.projectStoredLevelMutation(
                clamped,
                canonicalKey: canonicalKey,
                in: queueLevels
            )
            guard capacityAllowsLocked(
                projection,
                currentMapCount: queueLevels.count,
                maximumMapEntries: Self.maximumQueueEntries,
                createsPlaylist: false
            ) else {
                lock.unlock()
                return .rejectedReadOnly(.capacityExceeded)
            }
            if projection.changed {
                Self.applyStoredLevelMutation(
                    clamped,
                    canonicalKey: canonicalKey,
                    to: &queueLevels
                )
                applyResourceDeltaLocked(projection)
                changed = true
            }

        case .playlist(let id):
            let pid = id.uuidString
            var levels = playlistLevels[pid] ?? [:]
            let projection = Self.projectStoredLevelMutation(
                clamped,
                canonicalKey: canonicalKey,
                in: levels
            )
            guard capacityAllowsLocked(
                projection,
                currentMapCount: levels.count,
                maximumMapEntries: Self.maximumEntriesPerPlaylist,
                createsPlaylist: levels.isEmpty && projection.entryDelta > 0
            ) else {
                lock.unlock()
                return .rejectedReadOnly(.capacityExceeded)
            }
            if projection.changed {
                Self.applyStoredLevelMutation(
                    clamped,
                    canonicalKey: canonicalKey,
                    to: &levels
                )
                if levels.isEmpty {
                    playlistLevels.removeValue(forKey: pid)
                } else {
                    playlistLevels[pid] = levels
                }
                applyResourceDeltaLocked(projection)
                changed = true
            }
        }

        let changeRevision = changed ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        return finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
    }

    func clear(scope: Scope) -> MutationResult {
        loadIfNeeded()

        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        switch scope {
        case .queue:
            if !queueLevels.isEmpty {
                let footprint = Self.resourceFootprint(of: queueLevels)
                queueLevels.removeAll()
                storedEntryCount -= footprint.entries
                storedPathByteCount -= footprint.pathBytes
                changed = true
            }
        case .playlist(let id):
            let pid = id.uuidString
            if let levels = playlistLevels[pid], !levels.isEmpty {
                let footprint = Self.resourceFootprint(of: levels)
                playlistLevels.removeValue(forKey: pid)
                storedEntryCount -= footprint.entries
                storedPathByteCount -= footprint.pathBytes
                changed = true
            }
        }

        let changeRevision = changed ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        return finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
    }

    func clearAll() -> MutationResult {
        loadIfNeeded()

        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        if !queueLevels.isEmpty || !playlistLevels.isEmpty {
            queueLevels.removeAll()
            playlistLevels.removeAll()
            storedEntryCount = 0
            storedPathByteCount = 0
            changed = true
        }

        let changeRevision = changed ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        return finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
    }

    func removePlaylist(_ id: UserPlaylist.ID) -> MutationResult {
        removePlaylists([id])
    }

    /// Removes multiple playlist scopes as one logical mutation. The batch
    /// produces at most one revision, one notification, and one persisted snapshot.
    func removePlaylists(_ ids: [UserPlaylist.ID]) -> MutationResult {
        loadIfNeeded()

        guard ids.count <= Self.maximumPlaylistCount else {
            return .rejectedReadOnly(.capacityExceeded)
        }

        let playlistIDs = Set(ids.map(\.uuidString))
        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        for playlistID in playlistIDs {
            if let removed = playlistLevels.removeValue(forKey: playlistID) {
                let footprint = Self.resourceFootprint(of: removed)
                storedEntryCount -= footprint.entries
                storedPathByteCount -= footprint.pathBytes
                changed = true
            }
        }

        let changeRevision = changed ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        return finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
    }

    func removeTrack(_ url: URL, fromPlaylist id: UserPlaylist.ID) -> MutationResult {
        removeTracks([url], fromPlaylist: id)
    }

    /// Removes several tracks from one playlist scope as one logical mutation.
    func removeTracks(_ urls: [URL], fromPlaylist id: UserPlaylist.ID) -> MutationResult {
        removeTracks([PlaylistTrackRemoval(playlistID: id, trackURLs: urls)])
    }

    /// Removes tracks from multiple playlist scopes as one logical mutation.
    func removeTracks(_ removals: [PlaylistTrackRemoval]) -> MutationResult {
        loadIfNeeded()

        var keysByPlaylist: [String: Set<String>] = [:]
        var requestedTrackCount = 0
        for removal in removals {
            let playlistID = removal.playlistID.uuidString
            for url in removal.trackURLs {
                guard url.isFileURL,
                      Self.isValidRuntimePath(url.path),
                      requestedTrackCount < Self.maximumTotalEntries else {
                    return .rejectedReadOnly(.capacityExceeded)
                }
                keysByPlaylist[playlistID, default: []].insert(Self.key(for: url))
                requestedTrackCount += 1
            }
        }

        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        for (playlistID, keys) in keysByPlaylist {
            guard var levels = playlistLevels[playlistID] else { continue }
            for key in keys {
                let projection = Self.projectStoredLevelMutation(
                    Level.defaultLevel.rawValue,
                    canonicalKey: key,
                    in: levels
                )
                guard projection.changed else { continue }
                Self.applyStoredLevelMutation(
                    Level.defaultLevel.rawValue,
                    canonicalKey: key,
                    to: &levels
                )
                applyResourceDeltaLocked(projection)
                changed = true
            }
            if levels.isEmpty {
                playlistLevels.removeValue(forKey: playlistID)
            } else {
                playlistLevels[playlistID] = levels
            }
        }

        let changeRevision = changed ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        return finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
    }

    /// Rekeys track overrides in every scope. Existing destination overrides win;
    /// the obsolete source keys are still removed.
    func rekeyTrack(from oldURL: URL, to newURL: URL) -> MutationResult {
        rekeyTracks([TrackRekey(oldURL: oldURL, newURL: newURL)])
    }

    func rekeyTracks(_ changes: [TrackRekey]) -> MutationResult {
        mutateRekeys(changes, scope: nil)
    }

    /// Scoped rekey variant for callers that know only one scope moved.
    func rekeyTrack(from oldURL: URL, to newURL: URL, scope: Scope) -> MutationResult {
        rekeyTracks([TrackRekey(oldURL: oldURL, newURL: newURL)], scope: scope)
    }

    func rekeyTracks(_ changes: [TrackRekey], scope: Scope) -> MutationResult {
        mutateRekeys(changes, scope: scope)
    }

    private func mutateRekeys(_ changes: [TrackRekey], scope: Scope?) -> MutationResult {
        loadIfNeeded()

        guard changes.count <= Self.maximumTotalEntries,
              changes.allSatisfy({
                  $0.oldURL.isFileURL
                      && $0.newURL.isFileURL
                      && Self.isValidRuntimePath($0.oldURL.path)
                      && Self.isValidRuntimePath($0.newURL.path)
              }) else {
            return .rejectedReadOnly(.capacityExceeded)
        }

        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        var nextQueue = queueLevels
        var nextPlaylists = playlistLevels
        if let scope {
            switch scope {
            case .queue:
                changed = applyRekeys(changes, to: &nextQueue)
            case .playlist(let id):
                let playlistID = id.uuidString
                if var levels = nextPlaylists[playlistID] {
                    changed = applyRekeys(changes, to: &levels)
                    if levels.isEmpty {
                        nextPlaylists.removeValue(forKey: playlistID)
                    } else {
                        nextPlaylists[playlistID] = levels
                    }
                }
            }
        } else {
            changed = applyRekeys(changes, to: &nextQueue)
            for playlistID in Array(nextPlaylists.keys) {
                guard var levels = nextPlaylists[playlistID] else { continue }
                if applyRekeys(changes, to: &levels) {
                    changed = true
                }
                if levels.isEmpty {
                    nextPlaylists.removeValue(forKey: playlistID)
                } else {
                    nextPlaylists[playlistID] = levels
                }
            }
        }

        if changed {
            let candidate = CacheFile(
                version: formatVersion,
                queueLevels: nextQueue,
                playlistLevels: nextPlaylists
            )
            guard Self.validate(candidate, requireCanonicalSparseForm: true) else {
                lock.unlock()
                return .rejectedReadOnly(.capacityExceeded)
            }
            queueLevels = nextQueue
            playlistLevels = nextPlaylists
            refreshResourceCountersLocked()
        }

        let changeRevision = changed ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        return finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
    }

    /// Copy weight overrides from a playlist scope into the queue scope.
    ///
    /// Notes:
    /// - Only non-default levels are stored, so this copies *overrides* and will not wipe queue weights
    ///   for tracks that are default (green) in the playlist.
    /// - Returns how many overrides were present and how many actually changed in the queue scope.
    func syncPlaylistOverridesToQueue(from playlistID: UserPlaylist.ID) -> SyncResult {
        loadIfNeeded()

        let pid = playlistID.uuidString
        var changed = 0
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            let source = playlistLevels[pid] ?? [:]
            lock.unlock()
            return SyncResult(total: source.count, changed: 0, mutationResult: .rejectedReadOnly(reason))
        }

        let source = playlistLevels[pid] ?? [:]
        if source.isEmpty {
            shouldSave = isPersistenceDirtyLocked
            lock.unlock()
            let result = finishMutation(changeRevision: nil, shouldSave: shouldSave)
            return SyncResult(total: 0, changed: 0, mutationResult: result)
        }

        var nextQueue = queueLevels
        for (key, raw) in source {
            let clamped = normalizedStoredRaw(raw)
            guard clamped != Level.defaultLevel.rawValue else { continue }
            if nextQueue[key] != clamped {
                nextQueue[key] = clamped
                changed += 1
            }
        }

        if changed > 0 {
            let candidate = CacheFile(
                version: formatVersion,
                queueLevels: nextQueue,
                playlistLevels: playlistLevels
            )
            guard Self.validate(candidate, requireCanonicalSparseForm: true) else {
                lock.unlock()
                return SyncResult(
                    total: source.count,
                    changed: 0,
                    mutationResult: .rejectedReadOnly(.capacityExceeded)
                )
            }
            queueLevels = nextQueue
            refreshResourceCountersLocked()
        }

        let changeRevision = changed > 0 ? markDirtyLocked(publishChange: true) : nil
        shouldSave = isPersistenceDirtyLocked
        lock.unlock()
        let result = finishMutation(changeRevision: changeRevision, shouldSave: shouldSave)
        return SyncResult(total: source.count, changed: changed, mutationResult: result)
    }

    private var isPersistenceDirtyLocked: Bool {
        needsReplacementWrite || dirtyGeneration != durableGeneration
    }

    /// Must be called with `lock` held and exactly once per logical mutation.
    @discardableResult
    private func markDirtyLocked(publishChange: Bool = false) -> UInt64? {
        dirtyGeneration &+= 1
        guard publishChange else { return nil }
        logicalRevision &+= 1
        return logicalRevision
    }

    private func finishMutation(changeRevision: UInt64?, shouldSave: Bool) -> MutationResult {
        if let changeRevision {
            publishChangeOnMainThread(changeRevision)
        }
        if shouldSave {
            scheduleSave(resetRetryAttempt: changeRevision != nil)
            return .applied
        }
        return .unchanged
    }

    private func publishChangeOnMainThread(_ changeRevision: UInt64) {
        let publish = { [weak self] in
            guard let self else { return }
            if self.revision < changeRevision {
                self.revision = changeRevision
            }
            NotificationCenter.default.post(name: .playbackWeightsDidChange, object: self)
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    // MARK: - IO

    private func loadIfNeeded() {
        lock.lock()
        guard !isLoaded else {
            lock.unlock()
            return
        }
        guard _persistenceState == .notLoaded else {
            // Another thread is loading
            lock.unlock()
            return
        }
        _persistenceState = .loading
        isLoaded = true
        lock.unlock()

        if let libraryDatabase {
            loadFromLibraryDatabase(libraryDatabase)
            return
        }

        guard let url = cacheFileURL() else {
            PersistenceLogger.log("随机权重缓存目录不可访问")
            lock.lock()
            _persistenceState = .readOnlyPreserved(.unreadable)
            lock.unlock()
            return
        }

        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0 else {
            if errno != ENOENT {
                PersistenceLogger.log("随机权重文件状态不可读")
                lock.lock()
                _persistenceState = .readOnlyPreserved(.unreadable)
                lock.unlock()
                return
            }
            lock.lock()
            _persistenceState = .ready
            lock.unlock()
            return
        }

        guard let data = try? DerivedCacheFileIO.readBoundedRegularFile(
            at: url,
            maximumBytes: Self.maximumFileBytes
        ) else {
            PersistenceLogger.log("随机权重文件 \(url.lastPathComponent) 不可读")
            lock.lock()
            _persistenceState = .readOnlyPreserved(.unreadable)
            lock.unlock()
            return
        }

        // Try to decode version envelope first
        guard let envelope = try? JSONDecoder().decode(CacheVersionEnvelope.self, from: data) else {
            // No valid version - corrupted JSON, quarantine it
            quarantineCorruptedFile(url: url)
            return
        }

        // Check if version is supported
        guard Self.supportedFormatVersions.contains(envelope.version) else {
            // Unsupported version (future or unknown), preserve read-only
            PersistenceLogger.log("随机权重文件 \(url.lastPathComponent) 版本 v\(envelope.version) 不受支持，只读保留")
            lock.lock()
            _persistenceState = .readOnlyPreserved(.unsupportedVersion(envelope.version))
            lock.unlock()
            return
        }

        // Try to decode full structure
        guard let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            // Valid version but corrupted structure, quarantine it
            quarantineCorruptedFile(url: url)
            return
        }

        guard decoded.version == envelope.version,
              Self.validate(decoded, requireCanonicalSparseForm: false) else {
            quarantineCorruptedFile(url: url)
            return
        }

        // Successfully decoded a supported version
        let normalizedQueue: [String: Int]
        let normalizedPlaylists: [String: [String: Int]]
        let needsPersistence: Bool
        let finalState: PersistenceState

        switch decoded.version {
        case 1:
            normalizedQueue = normalizeLevelMap(
                decoded.queueLevels,
                transform: migrateV1RawValue
            )
            normalizedPlaylists = normalizePlaylistLevelMaps(
                decoded.playlistLevels,
                transform: migrateV1RawValue
            )
            needsPersistence = true
            finalState = .migrated(fromVersion: 1)
        case 2:
            // v2 used the same raw values, but treated blue (1.6x) as the
            // sparse default. Re-normalize it against the v3 green (1.0x)
            // default while preserving every explicit non-default override.
            normalizedQueue = normalizeLevelMap(decoded.queueLevels)
            normalizedPlaylists = normalizePlaylistLevelMaps(decoded.playlistLevels)
            needsPersistence = true
            finalState = .migrated(fromVersion: 2)
        case formatVersion:
            normalizedQueue = normalizeLevelMap(decoded.queueLevels)
            normalizedPlaylists = normalizePlaylistLevelMaps(decoded.playlistLevels)
            needsPersistence = normalizedQueue != decoded.queueLevels
                || normalizedPlaylists != decoded.playlistLevels
            finalState = .ready
        default:
            // Should never reach here due to earlier check, but be defensive
            PersistenceLogger.log("随机权重文件 \(url.lastPathComponent) 版本 v\(decoded.version) 不受支持，只读保留")
            lock.lock()
            _persistenceState = .readOnlyPreserved(.unsupportedVersion(decoded.version))
            lock.unlock()
            return
        }

        lock.lock()
        queueLevels = normalizedQueue
        playlistLevels = normalizedPlaylists
        refreshResourceCountersLocked()
        _persistenceState = finalState
        if needsPersistence {
            needsReplacementWrite = true
            markDirtyLocked()
        }
        lock.unlock()

        if needsPersistence {
            _ = flushPersistence()
        }
    }

    private func loadFromLibraryDatabase(_ database: LibraryDatabase) {
        let protectedReason: ReadOnlyReason?
        switch database.accessMode {
        case .writable:
            protectedReason = nil
        case .readOnlyFuture(let version):
            protectedReason = .unsupportedVersion(version)
        case .readOnlyForeign(let applicationID):
            lock.lock()
            _persistenceState = .readOnlyPreserved(.foreignDatabase(applicationID))
            lock.unlock()
            return
        }

        do {
            let snapshot = try database.loadWeights()
            let decoded = CacheFile(
                version: formatVersion,
                queueLevels: snapshot.queueLevels,
                playlistLevels: Dictionary(
                    uniqueKeysWithValues: snapshot.playlistLevels.map {
                        ($0.key.uuidString, $0.value)
                    }
                )
            )
            guard Self.validate(decoded, requireCanonicalSparseForm: false) else {
                lock.lock()
                _persistenceState = .readOnlyPreserved(.capacityExceeded)
                lock.unlock()
                return
            }

            let normalizedQueue = normalizeLevelMap(decoded.queueLevels)
            let normalizedPlaylists = normalizePlaylistLevelMaps(decoded.playlistLevels)
            let needsPersistence = protectedReason == nil
                && (normalizedQueue != decoded.queueLevels
                    || normalizedPlaylists != decoded.playlistLevels)

            lock.lock()
            queueLevels = normalizedQueue
            playlistLevels = normalizedPlaylists
            refreshResourceCountersLocked()
            dirtyGeneration = snapshot.revision
            durableGeneration = snapshot.revision
            durableDatabaseRevision = snapshot.revision
            _persistenceState = protectedReason.map(PersistenceState.readOnlyPreserved) ?? .ready
            if needsPersistence {
                needsReplacementWrite = true
                markDirtyLocked()
            }
            lock.unlock()

            if needsPersistence {
                _ = flushPersistence()
            }
        } catch {
            lock.lock()
            _persistenceState = .readOnlyPreserved(protectedReason ?? .unreadable)
            lock.unlock()
        }
    }

    private func quarantineCorruptedFile(url: URL) {
        do {
            let quarantineURL: URL
            if let fileMover {
                let directory = url.deletingLastPathComponent()
                let candidate = directory.appendingPathComponent(
                    "playback-weights.quarantined-\(UUID().uuidString).json",
                    isDirectory: false
                )
                try fileMover(url, candidate)
                quarantineURL = candidate
            } else {
                quarantineURL = try DerivedCacheFileIO.quarantine(url, reason: .corrupt)
            }
            PersistenceLogger.log("随机权重损坏文件已隔离: \(quarantineURL.lastPathComponent)")

            lock.lock()
            _persistenceState = .quarantinedCorrupt(backupURL: quarantineURL)
            needsReplacementWrite = true
            markDirtyLocked()
            lock.unlock()
        } catch {
            // Quarantine failed - preserve original file read-only
            PersistenceLogger.log("随机权重文件隔离失败，只读保护 (移动失败)")
            lock.lock()
            _persistenceState = .readOnlyPreserved(.quarantineFailed)
            lock.unlock()
        }
    }

    private func checkMutationRejection() -> ReadOnlyReason? {
        // Must be called with lock held
        switch _persistenceState {
        case .notLoaded, .loading:
            return .unreadable
        case .ready, .migrated, .quarantinedCorrupt:
            return nil
        case .readOnlyPreserved(let reason):
            return reason
        }
    }

    private func scheduleSave(resetRetryAttempt: Bool) {
        let workItem: DispatchWorkItem
        let previousWorkItem: DispatchWorkItem?

        persistenceLock.lock()
        if resetRetryAttempt {
            automaticRetryAttempt = 0
        }
        persistenceRevision &+= 1
        let revision = persistenceRevision
        previousWorkItem = pendingSaveWorkItem
        workItem = DispatchWorkItem { [weak self] in
            self?.saveIfCurrent(revision)
        }
        pendingSaveWorkItem = workItem
        persistenceLock.unlock()

        previousWorkItem?.cancel()
        persistenceQueue.asyncAfter(deadline: .now() + persistenceDebounceInterval, execute: workItem)
    }

    private func saveIfCurrent(_ revision: UInt64) {
        persistenceLock.lock()
        let isCurrent = persistenceRevision == revision
        if isCurrent {
            pendingSaveWorkItem = nil
        }
        persistenceLock.unlock()

        guard isCurrent else { return }
        let result = saveNow()
        switch result.outcome {
        case .failed(.storageUnavailable), .failed(.writeFailed):
            scheduleRetryIfNeeded(afterFailedRevision: revision)
        case .failed(.capacityExceeded):
            break
        case .persisted, .alreadyCurrent:
            resetRetryAttemptIfCurrent(revision)
        case .rejectedReadOnly:
            break
        }
    }

    private func scheduleRetryIfNeeded(afterFailedRevision failedRevision: UInt64) {
        guard hasPendingPersistence else { return }

        let workItem: DispatchWorkItem
        let delay: TimeInterval
        persistenceLock.lock()
        guard persistenceRevision == failedRevision,
              pendingSaveWorkItem == nil,
              automaticRetryAttempt < maximumAutomaticRetryAttempts
        else {
            persistenceLock.unlock()
            return
        }

        automaticRetryAttempt += 1
        let attempt = automaticRetryAttempt
        persistenceRevision &+= 1
        let retryRevision = persistenceRevision
        workItem = DispatchWorkItem { [weak self] in
            self?.saveIfCurrent(retryRevision)
        }
        pendingSaveWorkItem = workItem
        delay = persistenceRetryBaseInterval * pow(2.0, Double(attempt - 1))
        persistenceLock.unlock()

        persistenceQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resetRetryAttemptIfCurrent(_ revision: UInt64) {
        persistenceLock.lock()
        if persistenceRevision == revision {
            automaticRetryAttempt = 0
        }
        persistenceLock.unlock()
    }

    @discardableResult
    private func invalidateScheduledSave() -> UInt64 {
        persistenceLock.lock()
        persistenceRevision &+= 1
        automaticRetryAttempt = 0
        let revision = persistenceRevision
        let pending = pendingSaveWorkItem
        pendingSaveWorkItem = nil
        persistenceLock.unlock()
        pending?.cancel()
        return revision
    }

    /// Reliably persists the latest in-memory snapshot before returning.
    ///
    /// Invalidating the debounce generation prevents an already-cancelled work
    /// item from writing again after this synchronous flush completes.
    @discardableResult
    func flushPersistence() -> PersistenceFlushResult {
        loadIfNeeded()

        let revision = invalidateScheduledSave()
        let operation = { [self] in saveNow() }
        let result: PersistenceFlushResult
        if DispatchQueue.getSpecific(key: persistenceQueueKey) != nil {
            result = operation()
        } else {
            result = persistenceQueue.sync(execute: operation)
        }

        switch result.outcome {
        case .failed(.storageUnavailable), .failed(.writeFailed):
            scheduleRetryIfNeeded(afterFailedRevision: revision)
        case .failed(.capacityExceeded):
            break
        case .persisted, .alreadyCurrent:
            resetRetryAttemptIfCurrent(revision)
        case .rejectedReadOnly:
            break
        }
        return result
    }

    private func saveNow() -> PersistenceFlushResult {
        lock.lock()
        let attemptedGeneration = dirtyGeneration
        switch _persistenceState {
        case .ready, .migrated, .quarantinedCorrupt:
            break
        case .readOnlyPreserved(let reason):
            let result = makeFlushResultLocked(
                outcome: .rejectedReadOnly(reason),
                attemptedGeneration: attemptedGeneration
            )
            lock.unlock()
            return result
        case .notLoaded, .loading:
            let result = makeFlushResultLocked(
                outcome: .rejectedReadOnly(.unreadable),
                attemptedGeneration: attemptedGeneration
            )
            lock.unlock()
            return result
        }

        guard isPersistenceDirtyLocked else {
            let result = makeFlushResultLocked(
                outcome: .alreadyCurrent,
                attemptedGeneration: attemptedGeneration
            )
            lock.unlock()
            return result
        }

        let snapshotQueue = queueLevels
        let snapshotPlaylists = playlistLevels
        let expectedDatabaseRevision = durableDatabaseRevision
        lock.unlock()

        let payload = CacheFile(
            version: formatVersion,
            queueLevels: snapshotQueue,
            playlistLevels: snapshotPlaylists
        )
        guard Self.validate(payload, requireCanonicalSparseForm: true) else {
            PersistenceLogger.log("保存随机权重失败: 数据超过安全边界或不满足格式约束")
            return failedFlushResult(
                generation: attemptedGeneration,
                failure: .capacityExceeded
            )
        }

        if let libraryDatabase {
            guard let librarySnapshot = makeLibrarySnapshot(
                generation: attemptedGeneration,
                queueLevels: snapshotQueue,
                playlistLevels: snapshotPlaylists
            ) else {
                return failedFlushResult(
                    generation: attemptedGeneration,
                    failure: .capacityExceeded
                )
            }
            do {
                let result = try libraryDatabase.replaceWeights(
                    librarySnapshot,
                    expectedRevision: expectedDatabaseRevision
                )
                switch result {
                case .committed(let revision):
                    return completedFlushResult(
                        generation: attemptedGeneration,
                        databaseRevision: revision,
                        outcome: .persisted
                    )
                case .alreadyCurrent(let revision):
                    return completedFlushResult(
                        generation: attemptedGeneration,
                        databaseRevision: revision,
                        outcome: .alreadyCurrent
                    )
                case .stale(let storedRevision):
                    return databaseConflictFlushResult(
                        generation: attemptedGeneration,
                        storedRevision: storedRevision
                    )
                case .conflict(let revision):
                    return databaseConflictFlushResult(
                        generation: attemptedGeneration,
                        storedRevision: revision
                    )
                }
            } catch {
                PersistenceLogger.log("保存随机权重到音乐库数据库失败: \(error.localizedDescription)")
                if shouldNotifyWriteFailure(for: attemptedGeneration) {
                    DispatchQueue.main.async {
                        PersistenceLogger.notifyUser(
                            title: "随机权重保存失败",
                            subtitle: "请检查磁盘权限或空间"
                        )
                    }
                }
                return failedFlushResult(
                    generation: attemptedGeneration,
                    failure: .writeFailed
                )
            }
        }

        guard let url = cacheFileURL() else {
            PersistenceLogger.log("随机权重缓存目录不可访问，无法保存")
            return failedFlushResult(
                generation: attemptedGeneration,
                failure: .storageUnavailable
            )
        }

        do {
            let data = try JSONEncoder().encode(payload)
            guard data.count <= Self.maximumFileBytes else {
                return failedFlushResult(
                    generation: attemptedGeneration,
                    failure: .capacityExceeded
                )
            }
            if let fileWriter {
                try fileWriter(data, url)
            } else {
                try DerivedCacheFileIO.atomicWrite(data, to: url)
            }
            return completedFlushResult(generation: attemptedGeneration)
        } catch {
            PersistenceLogger.log("保存随机权重失败: 写入错误")
            if shouldNotifyWriteFailure(for: attemptedGeneration) {
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(title: "随机权重保存失败", subtitle: "请检查磁盘权限或空间")
                }
            }
            return failedFlushResult(
                generation: attemptedGeneration,
                failure: .writeFailed
            )
        }
    }

    private func makeLibrarySnapshot(
        generation: UInt64,
        queueLevels: [String: Int],
        playlistLevels: [String: [String: Int]]
    ) -> LibraryWeightsSnapshot? {
        var convertedPlaylists: [UUID: [String: Int]] = [:]
        convertedPlaylists.reserveCapacity(playlistLevels.count)
        for (rawPlaylistID, levels) in playlistLevels {
            guard let playlistID = UUID(uuidString: rawPlaylistID),
                  convertedPlaylists[playlistID] == nil else { return nil }
            convertedPlaylists[playlistID] = levels
        }
        return LibraryWeightsSnapshot(
            revision: generation,
            queueLevels: queueLevels,
            playlistLevels: convertedPlaylists
        )
    }

    private func completedFlushResult(
        generation: UInt64,
        databaseRevision: UInt64? = nil,
        outcome: PersistenceFlushResult.Outcome = .persisted
    ) -> PersistenceFlushResult {
        lock.lock()
        durableGeneration = generation
        if let databaseRevision {
            durableDatabaseRevision = max(durableDatabaseRevision, databaseRevision)
        }
        if dirtyGeneration == generation {
            needsReplacementWrite = false
        }
        let result = makeFlushResultLocked(
            outcome: outcome,
            attemptedGeneration: generation
        )
        lock.unlock()
        return result
    }

    private func databaseConflictFlushResult(
        generation: UInt64,
        storedRevision: UInt64
    ) -> PersistenceFlushResult {
        lock.lock()
        let reason = ReadOnlyReason.databaseConflict(storedRevision: storedRevision)
        _persistenceState = .readOnlyPreserved(reason)
        let result = makeFlushResultLocked(
            outcome: .rejectedReadOnly(reason),
            attemptedGeneration: generation
        )
        lock.unlock()
        PersistenceLogger.log(reason.diagnosticMessage)
        return result
    }

    /// Must be called while `lock` is held.
    private func makeFlushResultLocked(
        outcome: PersistenceFlushResult.Outcome,
        attemptedGeneration: UInt64
    ) -> PersistenceFlushResult {
        PersistenceFlushResult(
            outcome: outcome,
            attemptedGeneration: attemptedGeneration,
            durableGeneration: durableGeneration,
            hasPendingChanges: isPersistenceDirtyLocked
        )
    }

    private func failedFlushResult(
        generation: UInt64,
        failure: PersistenceFailure
    ) -> PersistenceFlushResult {
        lock.lock()
        let result = makeFlushResultLocked(
            outcome: .failed(failure),
            attemptedGeneration: generation
        )
        lock.unlock()
        return result
    }

    private func shouldNotifyWriteFailure(for generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lastFailureNotificationGeneration != generation else { return false }
        lastFailureNotificationGeneration = generation
        return true
    }

    private func cacheFileURL() -> URL? {
        if let cacheFileURLOverride {
            guard (try? DerivedCacheFileIO.ensureParentDirectory(
                for: cacheFileURLOverride
            )) != nil else { return nil }
            return cacheFileURLOverride
        }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        let url = dir.appendingPathComponent(cacheFileName, isDirectory: false)
        guard (try? DerivedCacheFileIO.ensureParentDirectory(for: url)) != nil else {
            return nil
        }
        return url
    }

    private struct ResourceFootprint {
        let entries: Int
        let pathBytes: Int
    }

    private struct StoredLevelMutationProjection {
        let changed: Bool
        let entryDelta: Int
        let pathByteDelta: Int
    }

    private static func isValidRuntimePath(_ path: String) -> Bool {
        let bytes = path.utf8.count
        guard !path.isEmpty,
              path.hasPrefix("/"),
              !path.utf8.contains(0),
              bytes <= maximumPathBytes else {
            return false
        }
        let canonical = PathKey.canonical(path: path)
        return canonical.hasPrefix("/") && canonical.utf8.count <= maximumPathBytes
    }

    private static func projectStoredLevelMutation(
        _ rawValue: Int,
        canonicalKey: String,
        in map: [String: Int]
    ) -> StoredLevelMutationProjection {
        let variants = Set([canonicalKey, PathKey.legacy(path: canonicalKey)])
        let existingKeys = variants.filter { map[$0] != nil }
        let storesValue = rawValue != Level.defaultLevel.rawValue
        let entryDelta = (storesValue ? 1 : 0) - existingKeys.count
        let removedBytes = existingKeys.reduce(into: 0) { partial, key in
            partial += key.utf8.count
        }
        let pathByteDelta = (storesValue ? canonicalKey.utf8.count : 0) - removedBytes
        let alreadyCanonical = existingKeys.count == 1
            && existingKeys.first == canonicalKey
            && map[canonicalKey] == rawValue
        return StoredLevelMutationProjection(
            changed: storesValue ? !alreadyCanonical : !existingKeys.isEmpty,
            entryDelta: entryDelta,
            pathByteDelta: pathByteDelta
        )
    }

    private static func applyStoredLevelMutation(
        _ rawValue: Int,
        canonicalKey: String,
        to map: inout [String: Int]
    ) {
        map.removeValue(forKey: canonicalKey)
        let legacyKey = PathKey.legacy(path: canonicalKey)
        if legacyKey != canonicalKey {
            map.removeValue(forKey: legacyKey)
        }
        if rawValue != Level.defaultLevel.rawValue {
            map[canonicalKey] = rawValue
        }
    }

    /// Must be called with `lock` held.
    private func capacityAllowsLocked(
        _ projection: StoredLevelMutationProjection,
        currentMapCount: Int,
        maximumMapEntries: Int,
        createsPlaylist: Bool
    ) -> Bool {
        guard projection.changed else { return true }
        let nextMapCount = currentMapCount + projection.entryDelta
        let nextTotalEntries = storedEntryCount + projection.entryDelta
        let nextPathBytes = storedPathByteCount + projection.pathByteDelta
        let nextPlaylistCount = playlistLevels.count + (createsPlaylist ? 1 : 0)
        return nextMapCount >= 0
            && nextMapCount <= maximumMapEntries
            && nextTotalEntries >= 0
            && nextTotalEntries <= Self.maximumTotalEntries
            && nextPathBytes >= 0
            && nextPathBytes <= Self.maximumAggregatePathBytes
            && nextPlaylistCount <= Self.maximumPlaylistCount
    }

    /// Must be called with `lock` held after the corresponding map mutation.
    private func applyResourceDeltaLocked(_ projection: StoredLevelMutationProjection) {
        storedEntryCount += projection.entryDelta
        storedPathByteCount += projection.pathByteDelta
        assert(storedEntryCount >= 0 && storedPathByteCount >= 0)
    }

    private static func resourceFootprint(of map: [String: Int]) -> ResourceFootprint {
        ResourceFootprint(
            entries: map.count,
            pathBytes: map.keys.reduce(into: 0) { partial, key in
                partial += key.utf8.count
            }
        )
    }

    /// Must be called with `lock` held.
    private func refreshResourceCountersLocked() {
        var entries = queueLevels.count
        var pathBytes = Self.resourceFootprint(of: queueLevels).pathBytes
        for levels in playlistLevels.values {
            let footprint = Self.resourceFootprint(of: levels)
            entries += footprint.entries
            pathBytes += footprint.pathBytes
        }
        storedEntryCount = entries
        storedPathByteCount = pathBytes
    }

    /// Validates both resource limits and semantic invariants before a decoded
    /// document can influence memory state or an in-memory snapshot can reach disk.
    private static func validate(
        _ file: CacheFile,
        requireCanonicalSparseForm: Bool
    ) -> Bool {
        guard supportedFormatVersions.contains(file.version),
              !requireCanonicalSparseForm || file.version == 3,
              file.queueLevels.count <= maximumQueueEntries,
              file.playlistLevels.count <= maximumPlaylistCount else {
            return false
        }

        let permittedRawValues: ClosedRange<Int> = file.version == 1
            ? -1 ... 4
            : Level.minimumStoredRawValue ... Level.maximumStoredRawValue
        var totalEntries = 0
        var aggregatePathBytes = 0

        func validateLevelMap(_ levels: [String: Int], maximumEntries: Int) -> Bool {
            guard levels.count <= maximumEntries else { return false }
            var canonicalKeys = Set<String>()
            canonicalKeys.reserveCapacity(levels.count)
            for (path, rawValue) in levels {
                let pathBytes = path.utf8.count
                guard !path.isEmpty,
                      path.hasPrefix("/"),
                      !path.utf8.contains(0),
                      pathBytes <= PlaybackWeights.maximumPathBytes,
                      permittedRawValues.contains(rawValue) else {
                    return false
                }

                let canonicalPath = PathKey.canonical(path: path)
                guard canonicalPath.hasPrefix("/"),
                      canonicalPath.utf8.count <= PlaybackWeights.maximumPathBytes,
                      canonicalKeys.insert(canonicalPath).inserted else {
                    return false
                }
                if requireCanonicalSparseForm {
                    guard path == canonicalPath,
                          rawValue != Level.defaultLevel.rawValue else {
                        return false
                    }
                }

                let (nextPathBytes, pathOverflow) = aggregatePathBytes.addingReportingOverflow(pathBytes)
                let (nextEntryCount, entryOverflow) = totalEntries.addingReportingOverflow(1)
                guard !pathOverflow,
                      !entryOverflow,
                      nextPathBytes <= PlaybackWeights.maximumAggregatePathBytes,
                      nextEntryCount <= PlaybackWeights.maximumTotalEntries else {
                    return false
                }
                aggregatePathBytes = nextPathBytes
                totalEntries = nextEntryCount
            }
            return true
        }

        guard validateLevelMap(file.queueLevels, maximumEntries: maximumQueueEntries) else {
            return false
        }

        var canonicalPlaylistIDs = Set<String>()
        canonicalPlaylistIDs.reserveCapacity(file.playlistLevels.count)
        for (playlistID, levels) in file.playlistLevels {
            guard let uuid = UUID(uuidString: playlistID),
                  canonicalPlaylistIDs.insert(uuid.uuidString).inserted,
                  (!requireCanonicalSparseForm || playlistID == uuid.uuidString),
                  (!requireCanonicalSparseForm || !levels.isEmpty),
                  validateLevelMap(levels, maximumEntries: maximumEntriesPerPlaylist) else {
                return false
            }
        }
        return true
    }

    private func normalizePlaylistLevelMaps(
        _ raw: [String: [String: Int]],
        transform: (Int) -> Int = { $0 }
    ) -> [String: [String: Int]] {
        guard !raw.isEmpty else { return [:] }
        var normalized: [String: [String: Int]] = [:]
        normalized.reserveCapacity(raw.count)
        for playlistID in raw.keys.sorted() {
            guard let levels = raw[playlistID],
                  let canonicalPlaylistID = UUID(uuidString: playlistID)?.uuidString else {
                continue
            }
            let normalizedLevels = normalizeLevelMap(levels, transform: transform)
            if !normalizedLevels.isEmpty {
                normalized[canonicalPlaylistID] = normalizedLevels
            }
        }
        return normalized
    }

    private func normalizeLevelMap(
        _ raw: [String: Int],
        transform: (Int) -> Int = { $0 }
    ) -> [String: Int] {
        guard !raw.isEmpty else { return [:] }
        var normalized: [String: Int] = [:]
        normalized.reserveCapacity(raw.count)
        for path in raw.keys.sorted() {
            guard let level = raw[path] else { continue }
            let key = PathKey.canonical(path: path)
            let clamped = normalizedStoredRaw(transform(level))
            if clamped != Level.defaultLevel.rawValue {
                normalized[key] = clamped
            }
        }
        return normalized
    }

    private func migrateV1RawValue(_ raw: Int) -> Int {
        let legacyRaw = max(-1, min(4, raw))
        return legacyRaw + 1
    }

    private func normalizedStoredRaw(_ raw: Int) -> Int {
        max(Level.minimumStoredRawValue, min(Level.maximumStoredRawValue, raw))
    }

    nonisolated static func key(for url: URL) -> String {
        PathKey.canonical(for: url)
    }

    nonisolated static func lookupKeys(for url: URL) -> [String] {
        PathKey.lookupKeys(for: url)
    }

    private func applyRekeys(_ changes: [TrackRekey], to map: inout [String: Int]) -> Bool {
        var changed = false
        for change in changes {
            let oldCanonical = Self.key(for: change.oldURL)
            let newCanonical = Self.key(for: change.newURL)
            let oldKeys = Self.lookupKeys(for: change.oldURL)
            let newKeys = Self.lookupKeys(for: change.newURL)

            if oldCanonical == newCanonical {
                guard let value = oldKeys.compactMap({ map[$0] }).first else { continue }
                for key in oldKeys where key != newCanonical {
                    if map.removeValue(forKey: key) != nil { changed = true }
                }
                if map[newCanonical] != value {
                    map[newCanonical] = value
                    changed = true
                }
                continue
            }

            guard let sourceValue = oldKeys.compactMap({ map[$0] }).first else { continue }
            let destinationValue = newKeys.compactMap({ map[$0] }).first

            for key in oldKeys {
                if map.removeValue(forKey: key) != nil { changed = true }
            }
            for key in newKeys where key != newCanonical {
                if map.removeValue(forKey: key) != nil { changed = true }
            }

            let finalValue = destinationValue ?? sourceValue
            if map[newCanonical] != finalValue {
                map[newCanonical] = finalValue
                changed = true
            }
        }
        return changed
    }

    private func valueWithMigration(in map: inout [String: Int], lookupKeys: [String], canonicalKey: String) -> Int? {
        if let value = map[canonicalKey] {
            return value
        }
        for key in lookupKeys where key != canonicalKey {
            if let value = map[key] {
                let projection = Self.projectStoredLevelMutation(
                    value,
                    canonicalKey: canonicalKey,
                    in: map
                )
                Self.applyStoredLevelMutation(
                    value,
                    canonicalKey: canonicalKey,
                    to: &map
                )
                applyResourceDeltaLocked(projection)
                markDirtyLocked()
                scheduleSave(resetRetryAttempt: true)
                return value
            }
        }
        return nil
    }
}
