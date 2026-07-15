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
        case unreadable
        case quarantineFailed

        var diagnosticMessage: String {
            switch self {
            case .unsupportedVersion(let version):
                return "权重文件版本 v\(version) 不受支持"
            case .unreadable:
                return "权重文件不可读"
            case .quarantineFailed:
                return "权重文件损坏且隔离失败"
            }
        }
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
    private let cacheFileURLOverride: URL?
    private let fileMover: (URL, URL) throws -> Void
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
    private var _persistenceState: PersistenceState = .notLoaded
    private var needsReplacementWrite = false
    private var queueLevels: [String: Int] = [:]
    private var playlistLevels: [String: [String: Int]] = [:] // playlistID.uuidString -> (pathKey -> level)
    private var persistenceRevision: UInt64 = 0
    private var pendingSaveWorkItem: DispatchWorkItem?

    init(
        cacheFileURLOverride: URL? = nil,
        fileMover: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.cacheFileURLOverride = cacheFileURLOverride
        self.fileMover = fileMover
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

    func setLevel(_ level: Level, for url: URL, scope: Scope) -> MutationResult {
        let key = Self.key(for: url)
        return setLevelRaw(level.rawValue, forKey: key, scope: scope)
    }

    func setLevelRaw(_ raw: Int, forKey key: String, scope: Scope) -> MutationResult {
        loadIfNeeded()

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

        shouldSave = changed || needsReplacementWrite
        lock.unlock()

        if shouldSave {
            bumpAndSave()
            return .applied
        } else {
            return .unchanged
        }
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

        shouldSave = changed || needsReplacementWrite
        lock.unlock()

        if shouldSave {
            bumpAndSave()
            return .applied
        } else {
            return .unchanged
        }
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
            changed = true
        }

        shouldSave = changed || needsReplacementWrite
        lock.unlock()

        if shouldSave {
            bumpAndSave()
            return .applied
        } else {
            return .unchanged
        }
    }

    func removePlaylist(_ id: UserPlaylist.ID) -> MutationResult {
        loadIfNeeded()

        let pid = id.uuidString
        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        if playlistLevels.removeValue(forKey: pid) != nil {
            changed = true
        }

        shouldSave = changed || needsReplacementWrite
        lock.unlock()

        if shouldSave {
            bumpAndSave()
            return .applied
        } else {
            return .unchanged
        }
    }

    func removeTrack(_ url: URL, fromPlaylist id: UserPlaylist.ID) -> MutationResult {
        loadIfNeeded()

        let key = Self.key(for: url)
        let pid = id.uuidString
        var changed = false
        var shouldSave = false

        lock.lock()
        if let reason = checkMutationRejection() {
            lock.unlock()
            return .rejectedReadOnly(reason)
        }

        if playlistLevels[pid] != nil, removeKeyVariants(key, from: &playlistLevels[pid]!) {
            changed = true
            if playlistLevels[pid]?.isEmpty == true { playlistLevels.removeValue(forKey: pid) }
        }

        shouldSave = changed || needsReplacementWrite
        lock.unlock()

        if shouldSave {
            bumpAndSave()
            return .applied
        } else {
            return .unchanged
        }
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
            shouldSave = needsReplacementWrite
            lock.unlock()
            if shouldSave {
                bumpAndSave()
                return SyncResult(total: 0, changed: 0, mutationResult: .applied)
            } else {
                return SyncResult(total: 0, changed: 0, mutationResult: .unchanged)
            }
        }

        for (key, raw) in source {
            let clamped = normalizedStoredRaw(raw)
            guard clamped != Level.defaultLevel.rawValue else { continue }
            if queueLevels[key] != clamped {
                queueLevels[key] = clamped
                changed += 1
            }
        }

        shouldSave = changed > 0 || needsReplacementWrite
        lock.unlock()

        if shouldSave {
            bumpAndSave()
            return SyncResult(total: source.count, changed: changed, mutationResult: .applied)
        } else {
            return SyncResult(total: source.count, changed: 0, mutationResult: .unchanged)
        }
    }

    private func bumpAndSave() {
        revision &+= 1
        NotificationCenter.default.post(name: .playbackWeightsDidChange, object: nil)
        scheduleSave()
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

        guard let url = cacheFileURL() else {
            PersistenceLogger.log("随机权重缓存目录不可访问")
            lock.lock()
            _persistenceState = .readOnlyPreserved(.unreadable)
            lock.unlock()
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            lock.lock()
            _persistenceState = .ready
            lock.unlock()
            return
        }

        guard let data = try? Data(contentsOf: url) else {
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
        guard envelope.version == 1 || envelope.version == 2 || envelope.version == formatVersion else {
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
        _persistenceState = finalState
        lock.unlock()

        if needsPersistence {
            flushPersistence()
        }
    }

    private func quarantineCorruptedFile(url: URL) {
        let directory = url.deletingLastPathComponent()
        let quarantineName = "playback-weights.quarantined-\(UUID().uuidString).json"
        let quarantineURL = directory.appendingPathComponent(quarantineName)

        do {
            // Attempt to move the corrupted file (only once)
            try fileMover(url, quarantineURL)
            PersistenceLogger.log("随机权重损坏文件已隔离: \(quarantineURL.lastPathComponent)")

            lock.lock()
            _persistenceState = .quarantinedCorrupt(backupURL: quarantineURL)
            needsReplacementWrite = true
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
        let canWrite: Bool
        switch _persistenceState {
        case .ready, .migrated, .quarantinedCorrupt:
            canWrite = true
        case .notLoaded, .loading, .readOnlyPreserved:
            canWrite = false
        }
        lock.unlock()

        guard canWrite else { return }

        invalidateScheduledSave()
        persistenceQueue.sync { [self] in
            saveNow()
        }
    }

    private func saveNow() {
        guard let url = cacheFileURL() else {
            PersistenceLogger.log("随机权重缓存目录不可访问，无法保存")
            return
        }

        lock.lock()
        // Re-check state in case it changed
        let canWrite: Bool
        switch _persistenceState {
        case .ready, .migrated, .quarantinedCorrupt:
            canWrite = true
        case .notLoaded, .loading, .readOnlyPreserved:
            canWrite = false
        }
        guard canWrite else {
            lock.unlock()
            return
        }

        let snapshotQueue = queueLevels
        let snapshotPlaylists = playlistLevels
        lock.unlock()

        let payload = CacheFile(version: formatVersion, queueLevels: snapshotQueue, playlistLevels: snapshotPlaylists)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)

            // Only clear replacement flag after successful write
            lock.lock()
            needsReplacementWrite = false
            lock.unlock()
        } catch {
            PersistenceLogger.log("保存随机权重失败: 写入错误")
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
