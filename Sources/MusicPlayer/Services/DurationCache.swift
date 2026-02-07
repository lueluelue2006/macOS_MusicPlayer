import Foundation

/// Disk-backed cache for audio duration (seconds).
///
/// Design goals:
/// - Keep UI responsive: durations are computed lazily in background.
    /// - Avoid stale durations: cache invalidates by (mtime + size + inode).
/// - Keep memory usage low: store only numbers + small signatures.
actor DurationCache {
    static let shared = DurationCache()

    private init() {}

    private let cacheFileName = "duration-cache.json"
    private let formatVersion = 2

    private struct CacheFile: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        let durationSeconds: Double
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
    }

    private struct FileSignature: Equatable {
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
    }

    private var isLoaded = false
    private var entries: [String: Entry] = [:]
    private var pendingSaveTask: Task<Void, Never>?

    nonisolated static func key(for url: URL) -> String {
        PathKey.canonical(for: url)
    }

    nonisolated static func legacyKey(for url: URL) -> String {
        PathKey.legacy(for: url)
    }

    func cachedDurationIfValid(for url: URL) -> TimeInterval? {
        loadIfNeeded()

        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        var matchedKey = key
        guard let entry: Entry = {
            if let exact = entries[key] {
                return exact
            }
            guard legacyKey != key, let legacy = entries[legacyKey] else {
                return nil
            }
            entries[key] = legacy
            entries.removeValue(forKey: legacyKey)
            scheduleSave()
            matchedKey = key
            return legacy
        }() else { return nil }
        guard let current = fileSignature(for: url) else {
            // File missing/unreadable -> drop cache entry.
            entries.removeValue(forKey: matchedKey)
            scheduleSave()
            return nil
        }

        let expected = FileSignature(fileSize: entry.fileSize, mtimeNs: entry.mtimeNs, inode: entry.inode)
        guard current == expected else {
            // File changed -> invalidate.
            entries.removeValue(forKey: matchedKey)
            scheduleSave()
            return nil
        }

        guard entry.durationSeconds.isFinite, entry.durationSeconds > 0 else { return nil }
        return entry.durationSeconds
    }

    func storeDuration(_ duration: TimeInterval, for url: URL) {
        loadIfNeeded()

        guard duration.isFinite, duration > 0 else { return }
        guard let sig = fileSignature(for: url) else { return }

        let key = Self.key(for: url)
        let entry = Entry(
            durationSeconds: duration,
            fileSize: sig.fileSize,
            mtimeNs: sig.mtimeNs,
            inode: sig.inode
        )

        if entries[key] != entry {
            entries[key] = entry
            let legacyKey = Self.legacyKey(for: url)
            if legacyKey != key {
                entries.removeValue(forKey: legacyKey)
            }
            scheduleSave()
        }
    }

    func remove(for url: URL) {
        loadIfNeeded()
        let keys = [Self.key(for: url), Self.legacyKey(for: url)]
        var removed = false
        for key in keys {
            if entries.removeValue(forKey: key) != nil {
                removed = true
            }
        }
        if removed {
            scheduleSave()
        }
    }

    func removeAll() {
        loadIfNeeded()
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - IO

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let url = cacheFileURL(), let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode(CacheFile.self, from: data), decoded.version == formatVersion else { return }

        let normalized = normalizeKeys(decoded.entries)
        entries = normalized

        if normalized != decoded.entries {
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
            await self.saveNow()
        }
    }

    private func saveNow() {
        guard let url = cacheFileURL() else { return }
        let payload = CacheFile(version: formatVersion, entries: entries)
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

    private func fileSignature(for url: URL) -> FileSignature? {
        do {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let values = try url.resourceValues(forKeys: keys)
            guard let size = values.fileSize, let mtime = values.contentModificationDate else { return nil }

            let mtimeNs = Int64((mtime.timeIntervalSince1970 * 1_000_000_000.0).rounded())
            let inode: Int64? = {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let n = attrs?[.systemFileNumber] as? NSNumber {
                    return n.int64Value
                }
                if let n = attrs?[.systemFileNumber] as? Int {
                    return Int64(n)
                }
                return nil
            }()

            return FileSignature(fileSize: Int64(size), mtimeNs: mtimeNs, inode: inode)
        } catch {
            return nil
        }
    }

    private func normalizeKeys(_ raw: [String: Entry]) -> [String: Entry] {
        guard !raw.isEmpty else { return [:] }
        var normalized: [String: Entry] = [:]
        normalized.reserveCapacity(raw.count)
        for (path, entry) in raw {
            let key = PathKey.canonical(path: path)
            normalized[key] = entry
        }
        return normalized
    }
}
