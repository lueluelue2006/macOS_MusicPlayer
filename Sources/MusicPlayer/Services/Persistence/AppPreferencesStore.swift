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
        var normalizationEnabled: Bool
        var immersiveEnabled: Bool
        var analyzeDuringPlayback: Bool
        var autoPreanalyze: Bool
        var targetLUFS: Float
        var immersiveFadeDuration: Double
        var requireAnalysisBeforeTransition: Bool
        var scanSubfolders: Bool
        var notifyOnDeviceSwitch: Bool
        var notifyDeviceSwitchSilent: Bool
        var colorSchemeOverride: Int
        var playlistPanelMode: Int
        var compactRootPane: Int
        var ipcDebugEnabled: Bool

        init(
            volume: Float,
            playbackRate: Float,
            playbackMode: PlaybackMode,
            playbackScope: PlaybackScope,
            normalizationEnabled: Bool = true,
            immersiveEnabled: Bool = false,
            analyzeDuringPlayback: Bool = false,
            autoPreanalyze: Bool = true,
            targetLUFS: Float = -16,
            immersiveFadeDuration: Double = 0.6,
            requireAnalysisBeforeTransition: Bool = false,
            scanSubfolders: Bool = true,
            notifyOnDeviceSwitch: Bool = true,
            notifyDeviceSwitchSilent: Bool = true,
            colorSchemeOverride: Int = 0,
            playlistPanelMode: Int = 0,
            compactRootPane: Int = 0,
            ipcDebugEnabled: Bool = false
        ) {
            self.volume = volume
            self.playbackRate = playbackRate
            self.playbackMode = playbackMode
            self.playbackScope = playbackScope
            self.normalizationEnabled = normalizationEnabled
            self.immersiveEnabled = immersiveEnabled
            self.analyzeDuringPlayback = analyzeDuringPlayback
            self.autoPreanalyze = autoPreanalyze
            self.targetLUFS = targetLUFS
            self.immersiveFadeDuration = immersiveFadeDuration
            self.requireAnalysisBeforeTransition = requireAnalysisBeforeTransition
            self.scanSubfolders = scanSubfolders
            self.notifyOnDeviceSwitch = notifyOnDeviceSwitch
            self.notifyDeviceSwitchSilent = notifyDeviceSwitchSilent
            self.colorSchemeOverride = colorSchemeOverride
            self.playlistPanelMode = playlistPanelMode
            self.compactRootPane = compactRootPane
            self.ipcDebugEnabled = ipcDebugEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case volume
            case playbackRate
            case playbackMode
            case playbackScope
            case normalizationEnabled
            case immersiveEnabled
            case analyzeDuringPlayback
            case autoPreanalyze
            case targetLUFS
            case immersiveFadeDuration
            case requireAnalysisBeforeTransition
            case scanSubfolders
            case notifyOnDeviceSwitch
            case notifyDeviceSwitchSilent
            case colorSchemeOverride
            case playlistPanelMode
            case compactRootPane
            case ipcDebugEnabled
        }

        /// New fields use product defaults when decoding an older partial
        /// payload. Type mismatches still fail decoding so corrupt envelopes
        /// cannot silently become valid preferences.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self.default
            volume = try container.decode(Float.self, forKey: .volume)
            playbackRate = try container.decode(Float.self, forKey: .playbackRate)
            playbackMode = try container.decode(PlaybackMode.self, forKey: .playbackMode)
            // Playback scope is session state in LibraryDatabase as of v2.
            // Keep the runtime field for source compatibility, but never let a
            // v2 preference envelope restore it as an authority.
            playbackScope = .queue
            normalizationEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .normalizationEnabled
            ) ?? defaults.normalizationEnabled
            immersiveEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .immersiveEnabled
            ) ?? defaults.immersiveEnabled
            analyzeDuringPlayback = try container.decodeIfPresent(
                Bool.self,
                forKey: .analyzeDuringPlayback
            ) ?? defaults.analyzeDuringPlayback
            autoPreanalyze = try container.decodeIfPresent(
                Bool.self,
                forKey: .autoPreanalyze
            ) ?? defaults.autoPreanalyze
            targetLUFS = try container.decodeIfPresent(
                Float.self,
                forKey: .targetLUFS
            ) ?? defaults.targetLUFS
            immersiveFadeDuration = try container.decodeIfPresent(
                Double.self,
                forKey: .immersiveFadeDuration
            ) ?? defaults.immersiveFadeDuration
            requireAnalysisBeforeTransition = try container.decodeIfPresent(
                Bool.self,
                forKey: .requireAnalysisBeforeTransition
            ) ?? defaults.requireAnalysisBeforeTransition
            scanSubfolders = try container.decodeIfPresent(
                Bool.self,
                forKey: .scanSubfolders
            ) ?? defaults.scanSubfolders
            notifyOnDeviceSwitch = try container.decodeIfPresent(
                Bool.self,
                forKey: .notifyOnDeviceSwitch
            ) ?? defaults.notifyOnDeviceSwitch
            notifyDeviceSwitchSilent = try container.decodeIfPresent(
                Bool.self,
                forKey: .notifyDeviceSwitchSilent
            ) ?? defaults.notifyDeviceSwitchSilent
            colorSchemeOverride = try container.decodeIfPresent(
                Int.self,
                forKey: .colorSchemeOverride
            ) ?? defaults.colorSchemeOverride
            playlistPanelMode = try container.decodeIfPresent(
                Int.self,
                forKey: .playlistPanelMode
            ) ?? defaults.playlistPanelMode
            compactRootPane = try container.decodeIfPresent(
                Int.self,
                forKey: .compactRootPane
            ) ?? defaults.compactRootPane
            ipcDebugEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .ipcDebugEnabled
            ) ?? defaults.ipcDebugEnabled
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(volume, forKey: .volume)
            try container.encode(playbackRate, forKey: .playbackRate)
            try container.encode(playbackMode, forKey: .playbackMode)
            // playbackScope deliberately belongs to playback_session, not v2.
            try container.encode(normalizationEnabled, forKey: .normalizationEnabled)
            try container.encode(immersiveEnabled, forKey: .immersiveEnabled)
            try container.encode(analyzeDuringPlayback, forKey: .analyzeDuringPlayback)
            try container.encode(autoPreanalyze, forKey: .autoPreanalyze)
            try container.encode(targetLUFS, forKey: .targetLUFS)
            try container.encode(immersiveFadeDuration, forKey: .immersiveFadeDuration)
            try container.encode(
                requireAnalysisBeforeTransition,
                forKey: .requireAnalysisBeforeTransition
            )
            try container.encode(scanSubfolders, forKey: .scanSubfolders)
            try container.encode(notifyOnDeviceSwitch, forKey: .notifyOnDeviceSwitch)
            try container.encode(notifyDeviceSwitchSilent, forKey: .notifyDeviceSwitchSilent)
            try container.encode(colorSchemeOverride, forKey: .colorSchemeOverride)
            try container.encode(playlistPanelMode, forKey: .playlistPanelMode)
            try container.encode(compactRootPane, forKey: .compactRootPane)
            try container.encode(ipcDebugEnabled, forKey: .ipcDebugEnabled)
        }

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

    /// v1 stored only the four preferences that have always been coherent.
    /// Keeping a dedicated decoder makes migration precedence explicit: v1
    /// owns these values while scattered legacy keys fill only v2 additions.
    private struct EnvelopeV1: Decodable {
        struct PreferencesV1: Decodable {
            let volume: Float
            let playbackRate: Float
            let playbackMode: PlaybackMode
            let playbackScope: PlaybackScope
        }

        let version: Int
        let preferences: PreferencesV1
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
        static let normalizationEnabled = "userNormalizationEnabled"
        static let immersiveEnabled = "userImmersivePlaybackEnabled"
        static let analyzeDuringPlayback = "userAnalyzeVolumesDuringPlayback"
        static let autoPreanalyze = "userAutoPreanalyzeVolumesWhenIdle"
        static let targetLUFS = "userNormalizationTargetLUFS"
        static let immersiveFadeDuration = "userNormalizationFadeDuration"
        static let requireAnalysisBeforeTransition = "userRequireVolumeAnalysisBeforePlayback"
        static let scanSubfolders = "userScanSubfoldersEnabled"
        static let notifyOnDeviceSwitch = "userNotifyOnDeviceSwitch"
        static let notifyDeviceSwitchSilent = "userNotifyDeviceSwitchSilent"
        static let colorSchemeOverride = "userColorSchemeOverride"
        static let playlistPanelMode = "userPlaylistPanelMode"
        static let compactRootPane = "compactRootPane"
        static let ipcDebugEnabled = "ipcDebugEnabled"

        static let all = [
            volume,
            playbackRate,
            alternatePlaybackRate,
            playbackMode,
            looping,
            shuffle,
            scopeKind,
            scopePlaylistID,
            normalizationEnabled,
            immersiveEnabled,
            analyzeDuringPlayback,
            autoPreanalyze,
            targetLUFS,
            immersiveFadeDuration,
            requireAnalysisBeforeTransition,
            scanSubfolders,
            notifyOnDeviceSwitch,
            notifyDeviceSwitchSilent,
            colorSchemeOverride,
            playlistPanelMode,
            compactRootPane,
            ipcDebugEnabled,
        ]
    }

    static let envelopeKey = "playerPreferencesEnvelope"
    static let formatVersion = 2
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
    private var needsLegacyCleanup = false
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
        return isDirty || needsLegacyCleanup
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
            lock.lock()
            defer { lock.unlock() }
            return removeLegacyKeysDurablyLocked()
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

            if version == 1 {
                guard let envelope = try? JSONDecoder().decode(EnvelopeV1.self, from: data) else {
                    quarantineCorruptEnvelopeLocked(data)
                    loadLegacyPreferencesLocked()
                    return
                }

                var preferences = Preferences(
                    volume: envelope.preferences.volume,
                    playbackRate: envelope.preferences.playbackRate,
                    playbackMode: envelope.preferences.playbackMode,
                    playbackScope: envelope.preferences.playbackScope
                )
                Self.applyAddedLegacyPreferences(
                    from: userDefaults,
                    to: &preferences
                )
                cachedPreferences = Self.sanitize(preferences)
                needsLegacyCleanup = hasLegacyValuesLocked()
                migrateLoadedPreferencesLocked(previousEnvelopeData: data)
                return
            }

            guard version == Self.formatVersion,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                quarantineCorruptEnvelopeLocked(data)
                loadLegacyPreferencesLocked()
                return
            }

            cachedPreferences = Self.sanitize(envelope.preferences)
            needsLegacyCleanup = hasLegacyValuesLocked()
            isDirty = cachedPreferences != envelope.preferences
                || Self.requiresCanonicalV2Rewrite(data)
            if isDirty {
                migrateLoadedPreferencesLocked(previousEnvelopeData: data)
            } else {
                _ = removeLegacyKeysDurablyLocked()
            }
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
        Self.applyAddedLegacyPreferences(from: userDefaults, to: &preferences)

        cachedPreferences = Self.sanitize(preferences)
        guard hadLegacyValues else {
            isDirty = false
            needsLegacyCleanup = false
            return
        }

        needsLegacyCleanup = true
        migrateLoadedPreferencesLocked(previousEnvelopeData: nil)
    }

    /// Writes the v2 envelope and obtains a durability receipt before removing
    /// any legacy value. If synchronization fails, the previous envelope and
    /// all legacy keys remain available for a later retry.
    private func migrateLoadedPreferencesLocked(previousEnvelopeData: Data?) {
        isDirty = true
        guard case .success = persistLocked(force: false) else { return }
        guard userDefaults.synchronize() else {
            restoreEnvelopeLocked(previousEnvelopeData)
            isDirty = true
            return
        }
        _ = removeLegacyKeysDurablyLocked()
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

    private func hasLegacyValuesLocked() -> Bool {
        LegacyKey.all.contains { userDefaults.object(forKey: $0) != nil }
    }

    private func removeLegacyKeysDurablyLocked() -> Result<Void, PersistenceError> {
        guard needsLegacyCleanup || hasLegacyValuesLocked() else {
            needsLegacyCleanup = false
            return .success(())
        }

        let legacyValues = Dictionary(
            uniqueKeysWithValues: LegacyKey.all.compactMap { key in
                userDefaults.object(forKey: key).map { (key, $0) }
            }
        )
        LegacyKey.all.forEach(userDefaults.removeObject(forKey:))
        guard userDefaults.synchronize() else {
            legacyValues.forEach { userDefaults.set($0.value, forKey: $0.key) }
            _ = userDefaults.synchronize()
            needsLegacyCleanup = true
            isDirty = true
            return .failure(.synchronizationFailed)
        }
        needsLegacyCleanup = false
        return .success(())
    }

    private func restoreEnvelopeLocked(_ data: Data?) {
        if let data {
            userDefaults.set(data, forKey: Self.envelopeKey)
        } else {
            userDefaults.removeObject(forKey: Self.envelopeKey)
        }
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
        sanitized.targetLUFS = preferences.targetLUFS.isFinite
            ? max(-30, min(-8, preferences.targetLUFS))
            : Preferences.default.targetLUFS
        sanitized.immersiveFadeDuration = preferences.immersiveFadeDuration.isFinite
            ? max(0, min(1.5, preferences.immersiveFadeDuration))
            : Preferences.default.immersiveFadeDuration
        sanitized.colorSchemeOverride = max(0, min(2, preferences.colorSchemeOverride))
        sanitized.playlistPanelMode = max(0, min(1, preferences.playlistPanelMode))
        sanitized.compactRootPane = max(0, min(1, preferences.compactRootPane))
        return sanitized
    }

    private static func applyAddedLegacyPreferences(
        from userDefaults: UserDefaults,
        to preferences: inout Preferences
    ) {
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.normalizationEnabled)) {
            preferences.normalizationEnabled = value
        }
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.immersiveEnabled)) {
            preferences.immersiveEnabled = value
        }
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.analyzeDuringPlayback)) {
            preferences.analyzeDuringPlayback = value
        }
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.autoPreanalyze)) {
            preferences.autoPreanalyze = value
        }
        if let value = finiteNumber(userDefaults.object(forKey: LegacyKey.targetLUFS)) {
            preferences.targetLUFS = Float(value)
        }
        if let value = finiteNumber(userDefaults.object(forKey: LegacyKey.immersiveFadeDuration)) {
            preferences.immersiveFadeDuration = value
        }
        if let value = strictBool(
            userDefaults.object(forKey: LegacyKey.requireAnalysisBeforeTransition)
        ) {
            preferences.requireAnalysisBeforeTransition = value
        }
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.scanSubfolders)) {
            preferences.scanSubfolders = value
        }
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.notifyOnDeviceSwitch)) {
            preferences.notifyOnDeviceSwitch = value
        }
        if let value = strictBool(
            userDefaults.object(forKey: LegacyKey.notifyDeviceSwitchSilent)
        ) {
            preferences.notifyDeviceSwitchSilent = value
        }
        if let value = strictInteger(
            userDefaults.object(forKey: LegacyKey.colorSchemeOverride),
            allowed: 0...2
        ) {
            preferences.colorSchemeOverride = value
        }
        if let value = strictInteger(
            userDefaults.object(forKey: LegacyKey.playlistPanelMode),
            allowed: 0...1
        ) {
            preferences.playlistPanelMode = value
        }
        if let value = strictInteger(
            userDefaults.object(forKey: LegacyKey.compactRootPane),
            allowed: 0...1
        ) {
            preferences.compactRootPane = value
        }
        if let value = strictBool(userDefaults.object(forKey: LegacyKey.ipcDebugEnabled)) {
            preferences.ipcDebugEnabled = value
        }
    }

    private static let canonicalV2PreferenceKeys: Set<String> = [
        "volume",
        "playbackRate",
        "playbackMode",
        "normalizationEnabled",
        "immersiveEnabled",
        "analyzeDuringPlayback",
        "autoPreanalyze",
        "targetLUFS",
        "immersiveFadeDuration",
        "requireAnalysisBeforeTransition",
        "scanSubfolders",
        "notifyOnDeviceSwitch",
        "notifyDeviceSwitchSilent",
        "colorSchemeOverride",
        "playlistPanelMode",
        "compactRootPane",
        "ipcDebugEnabled",
    ]

    private static func requiresCanonicalV2Rewrite(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let preferences = root["preferences"] as? [String: Any] else { return false }
        return Set(preferences.keys) != canonicalV2PreferenceKeys
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

    private static func strictInteger(
        _ value: Any?,
        allowed: ClosedRange<Int>
    ) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(allowed.lowerBound),
              double <= Double(allowed.upperBound) else { return nil }
        return Int(double)
    }
}
