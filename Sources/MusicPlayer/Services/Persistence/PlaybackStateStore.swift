import Foundation

/// Persists the last durable playback selection as one coherent value.
///
/// The path and position intentionally share a single versioned envelope. This
/// prevents a crash between two UserDefaults writes from pairing one track with
/// another track's progress.
final class PlaybackStateStore {
    struct State: Codable, Equatable, Sendable {
        let filePath: String
        let lastPlayedTime: TimeInterval
    }

    enum PersistenceState: Equatable {
        case writable
        case protectedFuture(version: Int)
        case protectedCorrupt
    }

    enum RekeyResult: Equatable, Sendable {
        case unchanged
        case durable
        case protected
        case failed

        var permitsIntentAcknowledgement: Bool {
            self == .unchanged || self == .durable
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let state: State
    }

    private struct VersionProbe: Codable {
        let version: Int?
    }

    static let envelopeKey = "playbackStateEnvelope"
    static let legacyFilePathKey = "lastPlayedFilePath"
    static let legacyFileTimeKey = "lastPlayedFileTime"
    static let formatVersion = 1
    static let corruptQuarantineKeys = [
        "playbackStateEnvelope.quarantine.0",
        "playbackStateEnvelope.quarantine.1",
    ]
    private static let maximumEnvelopeBytes = 64 * 1_024
    private static let maximumPathBytes = 16 * 1_024

    private let userDefaults: UserDefaults
    private let disablesPersistence: Bool
    private let lock = NSLock()
    private var didLoad = false
    private var cachedState: State?
    private var storedPersistenceState: PersistenceState = .writable
    private var storedLastFlushSucceeded: Bool?
    /// A successful `UserDefaults.set` only updates the process-local domain.
    /// Generations let lifecycle flushes distinguish that accepted mutation from
    /// one that has crossed an explicit synchronization boundary.
    private var mutationGeneration: UInt64 = 0
    private var durableGeneration: UInt64 = 0
    /// Legacy keys may only be removed after the replacement envelope is known
    /// durable. If that first synchronization fails, a later `flush()` resumes
    /// the migration instead of abandoning the cleanup forever.
    private var needsLegacyCleanupAfterEnvelopeSync = false

    init(
        userDefaults: UserDefaults = .standard,
        disablesPersistence: Bool = false
    ) {
        self.userDefaults = userDefaults
        self.disablesPersistence = disablesPersistence
    }

    var persistenceState: PersistenceState {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return storedPersistenceState
    }

    var lastFlushSucceeded: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastFlushSucceeded
    }

    var hasUnpersistedChanges: Bool {
        guard !disablesPersistence else { return false }
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return mutationGeneration > durableGeneration
            || needsLegacyCleanupAfterEnvelopeSync
    }

    // MARK: - Read

    func loadState() -> State? {
        guard !disablesPersistence else { return nil }
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return cachedState
    }

    // MARK: - Write

    /// Saves path and progress through one UserDefaults value.
    func saveState(fileURL: URL, time: TimeInterval) {
        guard !disablesPersistence else { return }
        ensureLoaded()

        let path = fileURL.path
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.utf8.count <= Self.maximumPathBytes else { return }
        let state = State(filePath: path, lastPlayedTime: Self.sanitizedTime(time))

        lock.lock()
        defer { lock.unlock() }
        guard storedPersistenceState == .writable else { return }
        persistLocked(state)
    }

    /// Compatibility wrapper for callers being migrated to `saveState`.
    /// A different file without an explicit time starts at zero; it never
    /// inherits progress from the previously persisted track.
    func saveFile(_ url: URL, initialTime: TimeInterval? = nil) {
        guard !disablesPersistence else { return }
        let previous = loadState()
        let time: TimeInterval
        if let initialTime {
            time = initialTime
        } else if let previous,
                  PathKey.canonical(path: previous.filePath) == PathKey.canonical(for: url) {
            time = previous.lastPlayedTime
        } else {
            time = 0
        }
        saveState(fileURL: url, time: time)
    }

    /// Compatibility wrapper that keeps the existing path and updates the same
    /// envelope. A progress-only value is never created.
    func saveProgress(_ time: TimeInterval) {
        guard let state = loadState() else { return }
        saveState(fileURL: URL(fileURLWithPath: state.filePath), time: time)
    }

    /// Moves the persisted playback identity while preserving progress. The
    /// operation is idempotent and leaves future-schema data untouched.
    @discardableResult
    func rekeyIfMatching(from oldURL: URL, to newURL: URL) -> RekeyResult {
        guard !disablesPersistence else { return .unchanged }
        ensureLoaded()
        let newPath = newURL.path
        guard !newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newPath.utf8.count <= Self.maximumPathBytes else { return .failed }
        lock.lock()
        guard storedPersistenceState == .writable else {
            lock.unlock()
            return .protected
        }
        guard let cachedState else {
            lock.unlock()
            return .unchanged
        }
        let currentKey = PathKey.canonical(path: cachedState.filePath)
        let oldKey = PathKey.canonical(for: oldURL)
        let newKey = PathKey.canonical(for: newURL)
        if currentKey == newKey {
            lock.unlock()
            return flush() ? .durable : .failed
        }
        guard currentKey == oldKey else {
            lock.unlock()
            return .unchanged
        }
        let didPersist = persistLocked(
            State(
                filePath: newPath,
                lastPlayedTime: cachedState.lastPlayedTime
            )
        )
        lock.unlock()
        guard didPersist else { return .failed }
        return flush() ? .durable : .failed
    }

    // MARK: - Clear

    func clearIfMatching(_ url: URL) {
        guard !disablesPersistence else { return }
        ensureLoaded()

        lock.lock()
        defer { lock.unlock() }
        guard storedPersistenceState == .writable,
              let cachedState,
              PathKey.canonical(path: cachedState.filePath) == PathKey.canonical(for: url) else {
            return
        }
        clearLocked()
    }

    func clearAll() {
        guard !disablesPersistence else { return }
        ensureLoaded()

        lock.lock()
        defer { lock.unlock() }
        guard storedPersistenceState == .writable else { return }
        clearLocked()
    }

    /// Lifecycle-only durability boundary. Routine checkpoints should rely on
    /// normal UserDefaults batching and avoid forcing a preferences sync.
    @discardableResult
    func flush() -> Bool {
        guard !disablesPersistence else { return true }
        ensureLoaded()

        lock.lock()
        let firstTarget = mutationGeneration
        lock.unlock()

        let firstSynchronizationSucceeded = userDefaults.synchronize()

        lock.lock()
        if firstSynchronizationSucceeded {
            durableGeneration = max(durableGeneration, firstTarget)
        }

        // A legacy migration deliberately retains the source keys until the
        // replacement envelope has crossed a durability boundary. Removing the
        // keys is itself a new mutation and therefore needs a second receipt.
        var secondTarget: UInt64?
        if firstSynchronizationSucceeded,
           needsLegacyCleanupAfterEnvelopeSync,
           durableGeneration >= firstTarget,
           removeLegacyKeysLocked() {
            if mutationGeneration > durableGeneration {
                secondTarget = mutationGeneration
            }
        }

        if secondTarget == nil {
            let isLatestDurable = firstSynchronizationSucceeded
                && durableGeneration >= mutationGeneration
                && !needsLegacyCleanupAfterEnvelopeSync
            storedLastFlushSucceeded = isLatestDurable
            lock.unlock()
            return isLatestDurable
        }
        lock.unlock()

        let secondSynchronizationSucceeded = userDefaults.synchronize()
        lock.lock()
        if secondSynchronizationSucceeded, let secondTarget {
            durableGeneration = max(durableGeneration, secondTarget)
        }
        let isLatestDurable = secondSynchronizationSucceeded
            && durableGeneration >= mutationGeneration
            && !needsLegacyCleanupAfterEnvelopeSync
        storedLastFlushSucceeded = isLatestDurable
        lock.unlock()
        return isLatestDurable
    }

    // MARK: - Load and migration

    private func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLoad else { return }
        didLoad = true
        guard !disablesPersistence else { return }

        if let data = userDefaults.data(forKey: Self.envelopeKey) {
            guard data.count <= Self.maximumEnvelopeBytes else {
                storedPersistenceState = .protectedCorrupt
                cachedState = nil
                PersistenceLogger.log("播放状态 envelope 超过安全上限，保留原数据并进入只读")
                return
            }
            guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
                  let version = probe.version else {
                recoverCorruptEnvelopeLocked(data: data, reason: "missing or invalid version")
                return
            }

            if version > Self.formatVersion {
                storedPersistenceState = .protectedFuture(version: version)
                cachedState = nil
                PersistenceLogger.log(
                    "检测到未来播放状态版本 \(version)（当前支持 \(Self.formatVersion)），进入只读保护"
                )
                return
            }

            guard version == Self.formatVersion,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  !envelope.state.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  envelope.state.filePath.utf8.count <= Self.maximumPathBytes else {
                recoverCorruptEnvelopeLocked(data: data, reason: "decode failed")
                return
            }

            let sanitized = State(
                filePath: envelope.state.filePath,
                lastPlayedTime: Self.sanitizedTime(envelope.state.lastPlayedTime)
            )
            cachedState = sanitized
            if sanitized != envelope.state {
                persistLocked(sanitized)
            }
            if userDefaults.object(forKey: Self.legacyFilePathKey) != nil
                || userDefaults.object(forKey: Self.legacyFileTimeKey) != nil {
                needsLegacyCleanupAfterEnvelopeSync = true
                completeLegacyMigrationWhileLocked()
            }
            return
        }

        migrateLegacyStateLocked()
    }

    private func migrateLegacyStateLocked() {
        guard let rawPath = userDefaults.string(forKey: Self.legacyFilePathKey),
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A time without a path cannot identify a playback state.
            cachedState = nil
            _ = removeLegacyKeysLocked()
            return
        }
        guard rawPath.utf8.count <= Self.maximumPathBytes else {
            storedPersistenceState = .protectedCorrupt
            cachedState = nil
            PersistenceLogger.log("旧播放状态路径超过安全上限，保留原数据并进入只读")
            return
        }

        let rawTime = (userDefaults.object(forKey: Self.legacyFileTimeKey) as? NSNumber)?.doubleValue ?? 0
        let migrated = State(
            filePath: rawPath,
            lastPlayedTime: Self.sanitizedTime(rawTime)
        )
        guard persistLocked(migrated) else { return }
        needsLegacyCleanupAfterEnvelopeSync = true
        completeLegacyMigrationWhileLocked()
    }

    private func recoverCorruptEnvelopeLocked(data: Data, reason: String) {
        PersistenceLogger.log("播放状态 envelope 损坏（\(reason)），尝试迁移旧状态")
        guard mutationGeneration < UInt64.max else {
            storedPersistenceState = .protectedCorrupt
            cachedState = nil
            PersistenceLogger.log("播放状态修订号已达上限，保留损坏数据")
            return
        }
        let previousEnvelope = userDefaults.data(forKey: Self.envelopeKey)
        let previousNewestQuarantine = userDefaults.data(forKey: Self.corruptQuarantineKeys[0])
        let previousOlderQuarantine = userDefaults.data(forKey: Self.corruptQuarantineKeys[1])
        if data.count <= Self.maximumEnvelopeBytes {
            if let previous = userDefaults.data(forKey: Self.corruptQuarantineKeys[0]) {
                userDefaults.set(previous, forKey: Self.corruptQuarantineKeys[1])
            }
            userDefaults.set(data, forKey: Self.corruptQuarantineKeys[0])
        }
        userDefaults.removeObject(forKey: Self.envelopeKey)
        storedPersistenceState = .writable
        cachedState = nil
        if previousEnvelope != userDefaults.data(forKey: Self.envelopeKey)
            || previousNewestQuarantine != userDefaults.data(forKey: Self.corruptQuarantineKeys[0])
            || previousOlderQuarantine != userDefaults.data(forKey: Self.corruptQuarantineKeys[1]) {
            mutationGeneration += 1
        }
        migrateLegacyStateLocked()
    }

    @discardableResult
    private func persistLocked(_ state: State) -> Bool {
        let envelope = Envelope(version: Self.formatVersion, state: state)
        guard let data = try? JSONEncoder().encode(envelope) else {
            PersistenceLogger.log("编码播放状态失败")
            return false
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            PersistenceLogger.log("播放状态 envelope 超过安全上限")
            return false
        }
        if userDefaults.data(forKey: Self.envelopeKey) == data {
            cachedState = state
            return true
        }
        guard mutationGeneration < UInt64.max else {
            PersistenceLogger.log("播放状态修订号已达上限")
            return false
        }
        userDefaults.set(data, forKey: Self.envelopeKey)
        guard userDefaults.data(forKey: Self.envelopeKey) == data else {
            PersistenceLogger.log("播放状态 envelope 写入校验失败")
            return false
        }
        cachedState = state
        mutationGeneration += 1
        return true
    }

    private func clearLocked() {
        let hadPersistedValues = userDefaults.object(forKey: Self.envelopeKey) != nil
            || userDefaults.object(forKey: Self.legacyFilePathKey) != nil
            || userDefaults.object(forKey: Self.legacyFileTimeKey) != nil
        guard cachedState != nil || hadPersistedValues else { return }
        guard mutationGeneration < UInt64.max else {
            PersistenceLogger.log("播放状态修订号已达上限，未清除状态")
            return
        }
        userDefaults.removeObject(forKey: Self.envelopeKey)
        userDefaults.removeObject(forKey: Self.legacyFilePathKey)
        userDefaults.removeObject(forKey: Self.legacyFileTimeKey)
        guard userDefaults.object(forKey: Self.envelopeKey) == nil,
              userDefaults.object(forKey: Self.legacyFilePathKey) == nil,
              userDefaults.object(forKey: Self.legacyFileTimeKey) == nil else {
            PersistenceLogger.log("播放状态清除校验失败")
            return
        }
        cachedState = nil
        needsLegacyCleanupAfterEnvelopeSync = false
        mutationGeneration += 1
    }

    /// Removes migration source keys as one tracked mutation. Returning `true`
    /// means either no cleanup remained or the removal was accepted by the
    /// process-local defaults domain; durability is established separately.
    @discardableResult
    private func removeLegacyKeysLocked() -> Bool {
        let hasLegacyKeys = userDefaults.object(forKey: Self.legacyFilePathKey) != nil
            || userDefaults.object(forKey: Self.legacyFileTimeKey) != nil
        guard hasLegacyKeys else {
            needsLegacyCleanupAfterEnvelopeSync = false
            return true
        }
        guard mutationGeneration < UInt64.max else {
            PersistenceLogger.log("播放状态修订号已达上限，未清理旧键")
            return false
        }
        userDefaults.removeObject(forKey: Self.legacyFilePathKey)
        userDefaults.removeObject(forKey: Self.legacyFileTimeKey)
        guard userDefaults.object(forKey: Self.legacyFilePathKey) == nil,
              userDefaults.object(forKey: Self.legacyFileTimeKey) == nil else {
            PersistenceLogger.log("播放状态旧键清理校验失败")
            return false
        }
        mutationGeneration += 1
        needsLegacyCleanupAfterEnvelopeSync = false
        return true
    }

    /// Initialization already owns `lock`, so migration can establish both
    /// durability boundaries synchronously without exposing a half-migrated
    /// state to another caller.
    private func completeLegacyMigrationWhileLocked() {
        let envelopeTarget = mutationGeneration
        guard userDefaults.synchronize() else {
            storedLastFlushSucceeded = false
            return
        }
        durableGeneration = max(durableGeneration, envelopeTarget)
        guard removeLegacyKeysLocked() else {
            storedLastFlushSucceeded = false
            return
        }
        guard mutationGeneration > durableGeneration else {
            storedLastFlushSucceeded = true
            return
        }
        let cleanupTarget = mutationGeneration
        let cleanupSucceeded = userDefaults.synchronize()
        if cleanupSucceeded {
            durableGeneration = max(durableGeneration, cleanupTarget)
        }
        storedLastFlushSucceeded = cleanupSucceeded
            && durableGeneration >= mutationGeneration
    }

    private static func sanitizedTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return max(0, time)
    }
}
