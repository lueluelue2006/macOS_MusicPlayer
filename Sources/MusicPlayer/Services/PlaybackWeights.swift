import Foundation

/// Persistent, lightweight per-track playback weight settings.
///
/// Design:
/// - Scoped: queue weights and per-playlist weights are isolated.
/// - Keyed by normalized file path (no bookmarks).
/// - Best-effort disk persistence (JSON, debounced).
final class PlaybackWeights: ObservableObject {
    static let shared = PlaybackWeights()

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
        let key = Self.key(for: url)
        return level(forKey: key, scope: scope)
    }

    func level(forKey key: String, scope: Scope) -> Level {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        let raw: Int? = {
            switch scope {
            case .queue:
                return queueLevels[key]
            case .playlist(let id):
                return playlistLevels[id.uuidString]?[key]
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
                if queueLevels.removeValue(forKey: key) != nil { changed = true }
            } else if queueLevels[key] != clamped {
                queueLevels[key] = clamped
                changed = true
            }

        case .playlist(let id):
            let pid = id.uuidString
            if playlistLevels[pid] == nil { playlistLevels[pid] = [:] }
            if clamped == 0 {
                if playlistLevels[pid]?.removeValue(forKey: key) != nil { changed = true }
                if playlistLevels[pid]?.isEmpty == true { playlistLevels.removeValue(forKey: pid) }
            } else if playlistLevels[pid]?[key] != clamped {
                playlistLevels[pid]?[key] = clamped
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
        if playlistLevels[pid]?.removeValue(forKey: key) != nil {
            removed = true
            if playlistLevels[pid]?.isEmpty == true { playlistLevels.removeValue(forKey: pid) }
        }
        lock.unlock()
        if removed { bumpAndSave() }
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
            // Best-effort only.
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
            let key = URL(fileURLWithPath: path)
                .standardizedFileURL.path
                .precomposedStringWithCanonicalMapping
                .lowercased()
            let clamped = max(0, min(4, level))
            if clamped != 0 {
                normalized[key] = clamped
            }
        }
        return normalized
    }

    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
