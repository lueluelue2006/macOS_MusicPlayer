import Foundation

/// Disk-backed cache for basic audio metadata (title/artist/album).
///
/// Goals:
/// - Speed up restoring / re-importing large playlists without re-reading AVAsset metadata every time.
/// - Keep memory usage low (small strings only; no lyrics/artwork cached here).
/// - Ensure correctness via invalidation: (mtime + size) mismatch => treat as cache miss and refresh.
actor MetadataCache {
    static let shared = MetadataCache()

    private init() {}

    private let cacheFileName = "metadata-cache.json"
    private let formatVersion = 1

    private struct CacheFile: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        let title: String
        let artist: String
        let album: String
        let fileSize: Int64
        let mtimeNs: Int64
    }

    private struct FileSignature: Equatable {
        let fileSize: Int64
        let mtimeNs: Int64
    }

    private var isLoaded = false
    private var entries: [String: Entry] = [:]
    private var pendingSaveTask: Task<Void, Never>?

    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    func cachedMetadataIfValid(for url: URL) -> AudioMetadata? {
        loadIfNeeded()

        let key = Self.key(for: url)
        guard let entry = entries[key] else { return nil }
        guard let current = fileSignature(for: url) else {
            // File missing/unreadable -> drop cache entry.
            entries.removeValue(forKey: key)
            scheduleSave()
            return nil
        }

        let expected = FileSignature(fileSize: entry.fileSize, mtimeNs: entry.mtimeNs)
        guard current == expected else {
            // File changed -> invalidate.
            entries.removeValue(forKey: key)
            scheduleSave()
            return nil
        }

        return AudioMetadata(
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            year: nil,
            genre: nil,
            artwork: nil
        )
    }

    func storeBasicMetadata(_ metadata: AudioMetadata, for url: URL) {
        loadIfNeeded()

        guard let sig = fileSignature(for: url) else { return }
        let key = Self.key(for: url)

        let entry = Entry(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            fileSize: sig.fileSize,
            mtimeNs: sig.mtimeNs
        )

        if entries[key] != entry {
            entries[key] = entry
            scheduleSave()
        }
    }

    func remove(for url: URL) {
        loadIfNeeded()
        let key = Self.key(for: url)
        if entries.removeValue(forKey: key) != nil {
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
            // Keep the on-disk format stable to avoid duplicated keys due to path normalization differences.
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
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let size = values.fileSize, let mtime = values.contentModificationDate else { return nil }
            let mtimeNs = Int64((mtime.timeIntervalSince1970 * 1_000_000_000.0).rounded())
            return FileSignature(fileSize: Int64(size), mtimeNs: mtimeNs)
        } catch {
            return nil
        }
    }

    private func normalizeKeys(_ raw: [String: Entry]) -> [String: Entry] {
        guard !raw.isEmpty else { return [:] }
        var normalized: [String: Entry] = [:]
        normalized.reserveCapacity(raw.count)
        for (path, entry) in raw {
            let key = URL(fileURLWithPath: path)
                .standardizedFileURL.path
                .precomposedStringWithCanonicalMapping
                .lowercased()
            normalized[key] = entry
        }
        return normalized
    }
}

