import Foundation

/// Persistent, lightweight per-track playback weight settings.
///
/// Design:
/// - Scoped: queue weights and per-playlist weights are isolated.
/// - Keyed by canonical file path (no bookmarks), with legacy lowercased key compatibility.
/// - Best-effort disk persistence (JSON, debounced).
final class PlaybackWeights: ObservableObject {
    static let shared = PlaybackWeights()

    struct SyncResult: Sendable {
        let total: Int
        let changed: Int
    }

    enum Scope: Equatable, Sendable {
        case queue
        case playlist(UserPlaylist.ID)
    }

    enum Level: Int, CaseIterable, Sendable {
        case white = 0
        case green = 1
        case blue = 2
        case purple = 3
        case gold = 4
        case red = 5

        static let defaultLevel: Level = .blue
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

    private let cacheFileName = "playback-weights.json"
    private let formatVersion = 2
    private let cacheFileURLOverride: URL?
    private let lock = NSLock()
    private let persistenceLock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "MusicPlayer.PlaybackWeights.Persistence",
        qos: .utility
    )

    private struct CacheFile: Codable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    private struct CacheVersionEnvelope: Decodable {
        let version: Int
    }

    private var isLoaded = false
    private var hasUnsupportedPersistedFormat = false
    private var queueLevels: [String: Int] = [:]
    private var playlistLevels: [String: [String: Int]] = [:] // playlistID.uuidString -> (pathKey -> level)
    private var persistenceRevision: UInt64 = 0
    private var pendingSaveWorkItem: DispatchWorkItem?

    init(cacheFileURLOverride: URL? = nil) {
        self.cacheFileURLOverride = cacheFileURLOverride
        loadIfNeeded()
    }

    func level(for url: URL, scope: Scope) -> Level {
        let keys = Self.lookupKeys(for: url)
        if let first = keys.first {
            return level(forLookupKeys: keys, canonicalKey: first, scope: scope)
        }
        return .defaultLevel
    }

    func level(forKey key: String, scope: Scope) -> Level {
        level(forLookupKeys: [PathKey.canonical(path: key), PathKey.legacy(path: key)], canonicalKey: PathKey.canonical(path: key), scope: scope)
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

    func setLevel(_ level: Level, for url: URL, scope: Scope) {
        let key = Self.key(for: url)
        setLevelRaw(level.rawValue, forKey: key, scope: scope)
    }

    func setLevelRaw(_ raw: Int, forKey key: String, scope: Scope) {
        loadIfNeeded()
        let clamped = normalizedStoredRaw(raw)
        var changed = false
        lock.lock()
        changed = claimPreservedCacheForMutationLocked()
        switch scope {
        case .queue:
            if clamped == Level.defaultLevel.rawValue {
                if removeKeyVariants(key, from: &queueLevels) { changed = true }
            } else if queueLevels[key] != clamped {
                queueLevels[key] = clamped
                removeLegacyVariant(key, from: &queueLevels)
                changed = true
            }

        case .playlist(let id):
            let pid = id.uuidString
            if playlistLevels[pid] == nil { playlistLevels[pid] = [:] }
            if clamped == Level.defaultLevel.rawValue {
                if removeKeyVariants(key, from: &playlistLevels[pid]!) { changed = true }
                if playlistLevels[pid]?.isEmpty == true { playlistLevels.removeValue(forKey: pid) }
            } else if playlistLevels[pid]?[key] != clamped {
                playlistLevels[pid]?[key] = clamped
                removeLegacyVariant(key, from: &playlistLevels[pid]!)
                changed = true
            }
        }
        lock.unlock()

        if changed { bumpAndSave() }
    }

    func clear(scope: Scope) {
        loadIfNeeded()
        var changed = false
        lock.lock()
        changed = claimPreservedCacheForMutationLocked()
        switch scope {
        case .queue:
            if !queueLevels.isEmpty {
                queueLevels.removeAll()
                changed = true
            }
        case .playlist(let id):
            let pid = id.uuidString
            if playlistLevels[pid]?.isEmpty == false {
                playlistLevels.removeValue(forKey: pid)
                changed = true
            }
        }
        lock.unlock()
        if changed { bumpAndSave() }
    }

    func clearAll() {
        loadIfNeeded()
        lock.lock()
        let should = claimPreservedCacheForMutationLocked()
            || !queueLevels.isEmpty
            || !playlistLevels.isEmpty
        if should {
            queueLevels.removeAll()
            playlistLevels.removeAll()
        }
        lock.unlock()
        if should { bumpAndSave() }
    }

    func removePlaylist(_ id: UserPlaylist.ID) {
        loadIfNeeded()
        let pid = id.uuidString
        lock.lock()
        let removed = claimPreservedCacheForMutationLocked()
            || playlistLevels.removeValue(forKey: pid) != nil
        lock.unlock()
        if removed { bumpAndSave() }
    }

    func removeTrack(_ url: URL, fromPlaylist id: UserPlaylist.ID) {
        loadIfNeeded()
        let key = Self.key(for: url)
        let pid = id.uuidString
        var removed = false
        lock.lock()
        removed = claimPreservedCacheForMutationLocked()
        if playlistLevels[pid] != nil, removeKeyVariants(key, from: &playlistLevels[pid]!) {
            removed = true
            if playlistLevels[pid]?.isEmpty == true { playlistLevels.removeValue(forKey: pid) }
        }
        lock.unlock()
        if removed { bumpAndSave() }
    }

    /// Copy weight overrides from a playlist scope into the queue scope.
    ///
    /// Notes:
    /// - Only non-default levels are stored, so this copies *overrides* and will not wipe queue weights
    ///   for tracks that are default (blue) in the playlist.
    /// - Returns how many overrides were present and how many actually changed in the queue scope.
    func syncPlaylistOverridesToQueue(from playlistID: UserPlaylist.ID) -> SyncResult {
        loadIfNeeded()
        let pid = playlistID.uuidString

        lock.lock()
        let claimedPreservedCache = claimPreservedCacheForMutationLocked()
        let source = playlistLevels[pid] ?? [:]
        if source.isEmpty {
            lock.unlock()
            if claimedPreservedCache { bumpAndSave() }
            return SyncResult(total: 0, changed: 0)
        }

        var changed = 0
        for (key, raw) in source {
            let clamped = normalizedStoredRaw(raw)
            guard clamped != Level.defaultLevel.rawValue else { continue }
            if queueLevels[key] != clamped {
                queueLevels[key] = clamped
                changed += 1
            }
        }
        lock.unlock()

        if claimedPreservedCache || changed > 0 { bumpAndSave() }
        return SyncResult(total: source.count, changed: changed)
    }

    private func bumpAndSave() {
        lock.lock()
        hasUnsupportedPersistedFormat = false
        lock.unlock()
        revision &+= 1
        NotificationCenter.default.post(name: .playbackWeightsDidChange, object: nil)
        scheduleSave()
    }

    // MARK: - IO

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let url = cacheFileURL() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CacheVersionEnvelope.self, from: data),
              envelope.version == 1 || envelope.version == formatVersion,
              let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            preserveExistingCache()
            return
        }

        let normalizedQueue: [String: Int]
        let normalizedPlaylists: [String: [String: Int]]
        let needsPersistence: Bool
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
        case formatVersion:
            normalizedQueue = normalizeLevelMap(decoded.queueLevels)
            normalizedPlaylists = normalizePlaylistLevelMaps(decoded.playlistLevels)
            needsPersistence = normalizedQueue != decoded.queueLevels
                || normalizedPlaylists != decoded.playlistLevels
        default:
            // A newer or otherwise unknown envelope may contain semantics this
            // build cannot safely interpret. Leave it untouched and use defaults.
            preserveExistingCache()
            return
        }

        lock.lock()
        queueLevels = normalizedQueue
        playlistLevels = normalizedPlaylists
        lock.unlock()

        if needsPersistence {
            flushPersistence()
        }
    }

    private func scheduleSave() {
        let workItem: DispatchWorkItem
        let previousWorkItem: DispatchWorkItem?

        persistenceLock.lock()
        persistenceRevision &+= 1
        let revision = persistenceRevision
        previousWorkItem = pendingSaveWorkItem
        workItem = DispatchWorkItem { [weak self] in
            self?.saveIfCurrent(revision)
        }
        pendingSaveWorkItem = workItem
        persistenceLock.unlock()

        previousWorkItem?.cancel()
        persistenceQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func saveIfCurrent(_ revision: UInt64) {
        persistenceLock.lock()
        let isCurrent = persistenceRevision == revision
        if isCurrent {
            pendingSaveWorkItem = nil
        }
        persistenceLock.unlock()

        guard isCurrent else { return }
        saveNow()
    }

    private func invalidateScheduledSave() {
        persistenceLock.lock()
        persistenceRevision &+= 1
        let pending = pendingSaveWorkItem
        pendingSaveWorkItem = nil
        persistenceLock.unlock()
        pending?.cancel()
    }

    /// Reliably persists the latest in-memory snapshot before returning.
    ///
    /// Invalidating the debounce generation prevents an already-cancelled work
    /// item from writing again after this synchronous flush completes.
    func flushPersistence() {
        loadIfNeeded()
        lock.lock()
        let shouldPreserveExistingFile = hasUnsupportedPersistedFormat
        lock.unlock()
        guard !shouldPreserveExistingFile else { return }
        invalidateScheduledSave()
        persistenceQueue.sync { [self] in
            saveNow()
        }
    }

    private func saveNow() {
        guard let url = cacheFileURL() else { return }
        lock.lock()
        let snapshotQueue = queueLevels
        let snapshotPlaylists = playlistLevels
        lock.unlock()
        let payload = CacheFile(version: formatVersion, queueLevels: snapshotQueue, playlistLevels: snapshotPlaylists)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            PersistenceLogger.log("保存随机权重失败: \(error)")
            DispatchQueue.main.async {
                PersistenceLogger.notifyUser(title: "随机权重保存失败", subtitle: "请检查磁盘权限或空间")
            }
        }
    }

    private func cacheFileURL() -> URL? {
        if let cacheFileURLOverride {
            let dir = cacheFileURLOverride.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    return nil
                }
            }
            return cacheFileURLOverride
        }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return dir.appendingPathComponent(cacheFileName, isDirectory: false)
    }

    private func normalizePlaylistLevelMaps(
        _ raw: [String: [String: Int]],
        transform: (Int) -> Int = { $0 }
    ) -> [String: [String: Int]] {
        guard !raw.isEmpty else { return [:] }
        var normalized: [String: [String: Int]] = [:]
        normalized.reserveCapacity(raw.count)
        for (playlistID, levels) in raw {
            let normalizedLevels = normalizeLevelMap(levels, transform: transform)
            if !normalizedLevels.isEmpty {
                normalized[playlistID] = normalizedLevels
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
        for (path, level) in raw {
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

    private func preserveExistingCache() {
        lock.lock()
        hasUnsupportedPersistedFormat = true
        lock.unlock()
    }

    /// A user-visible mutation intentionally takes ownership of a cache that
    /// this build could not decode. This keeps commands truthful: a reported
    /// clear/default/removal cannot silently reappear in a newer build later.
    /// Ordinary reads and shutdown flushes never claim or overwrite that file.
    private func claimPreservedCacheForMutationLocked() -> Bool {
        guard hasUnsupportedPersistedFormat else { return false }
        hasUnsupportedPersistedFormat = false
        queueLevels.removeAll()
        playlistLevels.removeAll()
        return true
    }

    nonisolated static func key(for url: URL) -> String {
        PathKey.canonical(for: url)
    }

    nonisolated static func lookupKeys(for url: URL) -> [String] {
        PathKey.lookupKeys(for: url)
    }

    private func removeKeyVariants(_ key: String, from map: inout [String: Int]) -> Bool {
        let variants = [PathKey.canonical(path: key), PathKey.legacy(path: key)]
        var removed = false
        for variant in variants {
            if map.removeValue(forKey: variant) != nil {
                removed = true
            }
        }
        return removed
    }

    private func removeLegacyVariant(_ key: String, from map: inout [String: Int]) {
        let canonical = PathKey.canonical(path: key)
        let legacy = PathKey.legacy(path: key)
        guard canonical != legacy else { return }
        map.removeValue(forKey: legacy)
    }

    private func valueWithMigration(in map: inout [String: Int], lookupKeys: [String], canonicalKey: String) -> Int? {
        if let value = map[canonicalKey] {
            return value
        }
        for key in lookupKeys where key != canonicalKey {
            if let value = map[key] {
                map[canonicalKey] = value
                map.removeValue(forKey: key)
                scheduleSave()
                return value
            }
        }
        return nil
    }
}
