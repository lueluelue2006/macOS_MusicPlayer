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
        case green = 0
        case blue = 1
        case purple = 2
        case gold = 3
        case red = 4

        var multiplier: Double {
            switch self {
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
    private let formatVersion = 1
    private let lock = NSLock()

    private struct CacheFile: Codable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    private var isLoaded = false
    private var queueLevels: [String: Int] = [:]
    private var playlistLevels: [String: [String: Int]] = [:] // playlistID.uuidString -> (pathKey -> level)
    private var pendingSaveTask: Task<Void, Never>?

    private init() {
        loadIfNeeded()
    }

    func level(for url: URL, scope: Scope) -> Level {
        let keys = Self.lookupKeys(for: url)
        if let first = keys.first {
            return level(forLookupKeys: keys, canonicalKey: first, scope: scope)
        }
        return .green
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
                if playlistLevels[pid] == nil {
                    playlistLevels[pid] = [:]
                }
                return valueWithMigration(in: &playlistLevels[pid]!, lookupKeys: lookupKeys, canonicalKey: canonicalKey)
            }
        }()
        return Level(rawValue: raw ?? 0) ?? .green
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
        let clamped = max(0, min(4, raw))
        var changed = false
        lock.lock()
        switch scope {
        case .queue:
            if clamped == 0 {
                if removeKeyVariants(key, from: &queueLevels) { changed = true }
            } else if queueLevels[key] != clamped {
                queueLevels[key] = clamped
                removeLegacyVariant(key, from: &queueLevels)
                changed = true
            }

        case .playlist(let id):
            let pid = id.uuidString
            if playlistLevels[pid] == nil { playlistLevels[pid] = [:] }
            if clamped == 0 {
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
        let should = !queueLevels.isEmpty || !playlistLevels.isEmpty
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
        let removed = (playlistLevels.removeValue(forKey: pid) != nil)
        lock.unlock()
        if removed { bumpAndSave() }
    }

    func removeTrack(_ url: URL, fromPlaylist id: UserPlaylist.ID) {
        loadIfNeeded()
        let key = Self.key(for: url)
        let pid = id.uuidString
        var removed = false
        lock.lock()
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
    ///   for tracks that are default (green) in the playlist.
    /// - Returns how many overrides were present and how many actually changed in the queue scope.
    func syncPlaylistOverridesToQueue(from playlistID: UserPlaylist.ID) -> SyncResult {
        loadIfNeeded()
        let pid = playlistID.uuidString

        lock.lock()
        let source = playlistLevels[pid] ?? [:]
        if source.isEmpty {
            lock.unlock()
            return SyncResult(total: 0, changed: 0)
        }

        var changed = 0
        for (key, raw) in source {
            let clamped = max(0, min(4, raw))
            guard clamped != 0 else { continue }
            if queueLevels[key] != clamped {
                queueLevels[key] = clamped
                changed += 1
            }
        }
        lock.unlock()

        if changed > 0 { bumpAndSave() }
        return SyncResult(total: source.count, changed: changed)
    }

    private func bumpAndSave() {
        revision &+= 1
        NotificationCenter.default.post(name: .playbackWeightsDidChange, object: nil)
        scheduleSave()
    }

    // MARK: - IO

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let url = cacheFileURL(), let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode(CacheFile.self, from: data), decoded.version == formatVersion else { return }

        let normalizedQueue = normalizeLevelMap(decoded.queueLevels)
        var normalizedPlaylists: [String: [String: Int]] = [:]
        normalizedPlaylists.reserveCapacity(decoded.playlistLevels.count)
        for (pid, levels) in decoded.playlistLevels {
            normalizedPlaylists[pid] = normalizeLevelMap(levels)
        }

        lock.lock()
        queueLevels = normalizedQueue
        playlistLevels = normalizedPlaylists
        lock.unlock()

        if normalizedQueue != decoded.queueLevels || normalizedPlaylists != decoded.playlistLevels {
            scheduleSave()
        }
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            } catch {
                return
            }
            self.saveNow()
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

    private func normalizeLevelMap(_ raw: [String: Int]) -> [String: Int] {
        guard !raw.isEmpty else { return [:] }
        var normalized: [String: Int] = [:]
        normalized.reserveCapacity(raw.count)
        for (path, level) in raw {
            let key = PathKey.canonical(path: path)
            let clamped = max(0, min(4, level))
            if clamped != 0 {
                normalized[key] = clamped
            }
        }
        return normalized
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
