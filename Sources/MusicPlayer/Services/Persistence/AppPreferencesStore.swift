import Foundation

/// Coherent, versioned persistence for the player preferences that must agree
/// across launch boundaries.
///
/// `update` only changes the in-memory snapshot. Callers may coalesce frequent
/// slider events with `schedulePersistence()` and use `persist()` for discrete
/// controls. `flush()` is the lifecycle durability boundary.
final class AppPreferencesStore: @unchecked Sendable {
    static let shared = AppPreferencesStore()

    enum PlaybackMode: String, Codable, CaseIterable, Sendable {
        case shuffle
        case repeatOne
    }

    enum PlaybackScope: Equatable, Sendable, Codable {
        case queue
        case playlist(UUID)

        private enum CodingKeys: String, CodingKey {
            case kind
            case playlistID
        }

        private enum Kind: String, Codable {
            case queue
            case playlist
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .queue:
                self = .queue
            case .playlist:
                self = .playlist(try container.decode(UUID.self, forKey: .playlistID))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .queue:
                try container.encode(Kind.queue, forKey: .kind)
            case .playlist(let id):
                try container.encode(Kind.playlist, forKey: .kind)
                try container.encode(id, forKey: .playlistID)
            }
        }
    }

    struct Preferences: Codable, Equatable, Sendable {
        var volume: Float
        var playbackRate: Float
        var playbackMode: PlaybackMode
        var playbackScope: PlaybackScope

        static let `default` = Preferences(
            volume: 0.5,
            playbackRate: 1,
            playbackMode: .shuffle,
            playbackScope: .queue
        )
    }

    enum PersistenceState: Equatable, Sendable {
        case writable
        case protectedFuture(version: Int)
        case protectedCorrupt
    }

    enum PersistenceError: Error, Equatable, Sendable {
        case protectedFuture(version: Int)
        case encodingFailed
        case synchronizationFailed
        case corruptEnvelope
    }

    private struct Envelope: Codable {
        let version: Int
        let preferences: Preferences
    }

    private struct VersionProbe: Decodable {
        let version: Int?
    }

    enum LegacyKey {
        static let volume = "userPreferredVolume"
        static let playbackRate = "userPlaybackRate"
        static let alternatePlaybackRate = "userPreferredPlaybackRate"
        static let playbackMode = "userPlaybackMode"
        static let looping = "userLoopingEnabled"
        static let shuffle = "userShuffleEnabled"
        static let scopeKind = "userPlaybackScopeKind"
        static let scopePlaylistID = "userPlaybackScopePlaylistID"

        static let all = [
            volume,
            playbackRate,
            alternatePlaybackRate,
            playbackMode,
            looping,
            shuffle,
            scopeKind,
            scopePlaylistID,
        ]
    }

    static let envelopeKey = "playerPreferencesEnvelope"
    static let formatVersion = 1
    static let corruptQuarantineKeys = [
        "playerPreferencesEnvelope.quarantine.0",
        "playerPreferencesEnvelope.quarantine.1",
    ]
    private static let maximumEnvelopeBytes = 64 * 1_024

    private let userDefaults: UserDefaults
    private let persistenceQueue: DispatchQueue
    private let lock = NSLock()
    private var didLoad = false
    private var cachedPreferences = Preferences.default
    private var storedPersistenceState: PersistenceState = .writable
    private var isDirty = false
    private var pendingPersistence: DispatchWorkItem?

    init(
        userDefaults: UserDefaults = .standard,
        persistenceQueue: DispatchQueue = DispatchQueue(
            label: "app.preferences.persistence",
            qos: .utility
        )
    ) {
        self.userDefaults = userDefaults
        self.persistenceQueue = persistenceQueue
    }

    var persistenceState: PersistenceState {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return storedPersistenceState
    }

    var hasUnpersistedChanges: Bool {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return isDirty
    }

    func load() -> Preferences {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return cachedPreferences
    }

    /// Updates only the in-memory snapshot. Invalid floating-point values are
    /// replaced by the product defaults and finite values are clamped.
    @discardableResult
    func update(_ mutation: (inout Preferences) -> Void) -> Bool {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard storedPersistenceState == .writable else { return false }

        var updated = cachedPreferences
        mutation(&updated)
        updated = Self.sanitize(updated)
        guard updated != cachedPreferences else { return false }
        cachedPreferences = updated
        isDirty = true
        return true
    }

    /// Debounces high-frequency callers such as volume and rate sliders. This
    /// method never blocks the caller on preferences I/O.
    func schedulePersistence(after delay: TimeInterval = 0.35) {
        ensureLoaded()
        let boundedDelay = max(0, min(delay.isFinite ? delay : 0.35, 5))

        lock.lock()
        guard storedPersistenceState == .writable, isDirty else {
            lock.unlock()
            return
        }
        pendingPersistence?.cancel()
        let work = DispatchWorkItem { [weak self] in
            _ = self?.persist()
        }
        pendingPersistence = work
        lock.unlock()

        persistenceQueue.asyncAfter(deadline: .now() + boundedDelay, execute: work)
    }

    /// Persists the latest merged snapshot as one UserDefaults value.
    @discardableResult
    func persist() -> Result<Void, PersistenceError> {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        pendingPersistence?.cancel()
        pendingPersistence = nil
        return persistLocked(force: false)
    }

    /// Cancels any pending debounce, writes the current snapshot, then asks the
    /// preferences daemon to synchronize at an app lifecycle boundary.
    @discardableResult
    func flush() -> Result<Void, PersistenceError> {
        switch persist() {
        case .success:
            guard userDefaults.synchronize() else {
                // Keep the latest in-memory snapshot retryable. A failed
                // lifecycle receipt must never be mistaken for durable state.
                lock.lock()
                if storedPersistenceState == .writable {
                    isDirty = true
                }
                lock.unlock()
                return .failure(.synchronizationFailed)
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLoad else { return }
        didLoad = true

        if let data = userDefaults.data(forKey: Self.envelopeKey) {
            guard data.count <= Self.maximumEnvelopeBytes else {
                storedPersistenceState = .protectedCorrupt
                cachedPreferences = .default
                isDirty = false
                PersistenceLogger.log("播放器偏好 envelope 超过安全上限，保留原数据并进入只读")
                return
            }
            guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
                  let version = probe.version else {
                quarantineCorruptEnvelopeLocked(data)
                loadLegacyPreferencesLocked()
                return
            }

            if version > Self.formatVersion {
                storedPersistenceState = .protectedFuture(version: version)
                cachedPreferences = .default
                isDirty = false
                PersistenceLogger.log(
                    "检测到未来播放器偏好版本 \(version)，进入只读保护"
                )
                return
            }

            guard version == Self.formatVersion,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                quarantineCorruptEnvelopeLocked(data)
                loadLegacyPreferencesLocked()
                return
            }

            cachedPreferences = Self.sanitize(envelope.preferences)
            isDirty = cachedPreferences != envelope.preferences
            if isDirty {
                guard case .success = persistLocked(force: false) else {
                    return
                }
            }
            removeLegacyKeysAfterVerifiedEnvelopeLocked()
            return
        }

        loadLegacyPreferencesLocked()
    }

    private func loadLegacyPreferencesLocked() {
        let hadLegacyValues = LegacyKey.all.contains {
            userDefaults.object(forKey: $0) != nil
        }
        var preferences = Preferences.default

        if let value = Self.finiteNumber(
            userDefaults.object(forKey: LegacyKey.volume)
        ) {
            preferences.volume = Float(value)
        }
        let legacyRate = Self.finiteNumber(
            userDefaults.object(forKey: LegacyKey.playbackRate)
        ) ?? Self.finiteNumber(
            userDefaults.object(forKey: LegacyKey.alternatePlaybackRate)
        )
        if let legacyRate {
            preferences.playbackRate = Float(legacyRate)
        }

        let storedMode = (userDefaults.object(forKey: LegacyKey.playbackMode) as? String)
            .flatMap(PlaybackMode.init(rawValue:))
        if let storedMode {
            preferences.playbackMode = storedMode
        } else if Self.strictBool(userDefaults.object(forKey: LegacyKey.looping)) == true {
            preferences.playbackMode = .repeatOne
        } else {
            preferences.playbackMode = .shuffle
        }

        if userDefaults.string(forKey: LegacyKey.scopeKind) == "playlist",
           let rawID = userDefaults.string(forKey: LegacyKey.scopePlaylistID),
           let id = UUID(uuidString: rawID) {
            preferences.playbackScope = .playlist(id)
        } else {
            preferences.playbackScope = .queue
        }

        cachedPreferences = Self.sanitize(preferences)
        guard hadLegacyValues else {
            isDirty = false
            return
        }

        isDirty = true
        guard case .success = persistLocked(force: false),
              userDefaults.data(forKey: Self.envelopeKey) != nil,
              userDefaults.synchronize() else {
            return
        }
        LegacyKey.all.forEach(userDefaults.removeObject(forKey:))
        _ = userDefaults.synchronize()
    }

    private func persistLocked(force: Bool) -> Result<Void, PersistenceError> {
        if case .protectedFuture(let version) = storedPersistenceState {
            return .failure(.protectedFuture(version: version))
        }
        if storedPersistenceState == .protectedCorrupt {
            return .failure(.corruptEnvelope)
        }
        guard force || isDirty else { return .success(()) }

        let envelope = Envelope(
            version: Self.formatVersion,
            preferences: Self.sanitize(cachedPreferences)
        )
        guard let data = try? JSONEncoder().encode(envelope) else {
            return .failure(.encodingFailed)
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            return .failure(.encodingFailed)
        }
        let previousData = userDefaults.data(forKey: Self.envelopeKey)
        userDefaults.set(data, forKey: Self.envelopeKey)
        guard userDefaults.data(forKey: Self.envelopeKey) == data else {
            if let previousData {
                userDefaults.set(previousData, forKey: Self.envelopeKey)
            } else {
                userDefaults.removeObject(forKey: Self.envelopeKey)
            }
            return .failure(.synchronizationFailed)
        }
        cachedPreferences = envelope.preferences
        isDirty = false
        return .success(())
    }

    private func quarantineCorruptEnvelopeLocked(_ data: Data) {
        let keys = Self.corruptQuarantineKeys
        if let previous = userDefaults.data(forKey: keys[0]) {
            userDefaults.set(previous, forKey: keys[1])
        }
        userDefaults.set(data, forKey: keys[0])
        userDefaults.removeObject(forKey: Self.envelopeKey)
        storedPersistenceState = .writable
        cachedPreferences = .default
        isDirty = false
        PersistenceLogger.log("播放器偏好 envelope 损坏，已隔离并使用安全默认值")
    }

    private func removeLegacyKeysAfterVerifiedEnvelopeLocked() {
        guard LegacyKey.all.contains(where: { userDefaults.object(forKey: $0) != nil }) else {
            return
        }
        LegacyKey.all.forEach(userDefaults.removeObject(forKey:))
        _ = userDefaults.synchronize()
    }

    private static func sanitize(_ preferences: Preferences) -> Preferences {
        var sanitized = preferences
        sanitized.volume = preferences.volume.isFinite
            ? max(0, min(1, preferences.volume))
            : Preferences.default.volume
        sanitized.playbackRate = preferences.playbackRate.isFinite
            ? max(0.5, min(2, preferences.playbackRate))
            : Preferences.default.playbackRate
        return sanitized
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
