import Foundation
import Combine

@MainActor
final class PlaylistsStore: ObservableObject {
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published var selectedPlaylistID: UserPlaylist.ID?

    private let playlistsFileName = "user-playlists.json"
    private let formatVersion = 1

    private struct StoreFile: Codable {
        let version: Int
        let playlists: [UserPlaylist]
    }

    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "playlists.persistence", qos: .utility)
    private let ioQueueKey = DispatchSpecificKey<Void>()

    init() {
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        loadTask = Task { [weak self] in
            await self?.loadFromDisk()
        }
    }

    func ensureLoaded() async {
        loadIfNeeded()
        await loadTask?.value
    }

    private func loadFromDisk() async {
        guard let url = playlistsFileURL() else {
            loadTask = nil
            return
        }

        let decoded: StoreFile? = await withCheckedContinuation { continuation in
            ioQueue.async {
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let store = try? JSONDecoder().decode(StoreFile.self, from: data), store.version == self.formatVersion else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: store)
            }
        }

        if let decoded {
            playlists = decoded.playlists
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlists.first?.id
            }
        }

        loadTask = nil
    }

    func createPlaylist(name: String, trackURLs: [URL] = []) {
        loadIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名歌单" : trimmed

        let tracks = normalizeTracks(from: trackURLs)
        let playlist = UserPlaylist(name: finalName, tracks: tracks)
        playlists.insert(playlist, at: 0)
        selectedPlaylistID = playlist.id
        saveNow()
    }

    func deletePlaylist(_ playlist: UserPlaylist) {
        loadIfNeeded()
        playlists.removeAll { $0.id == playlist.id }
        if selectedPlaylistID == playlist.id {
            selectedPlaylistID = playlists.first?.id
        }
        PlaybackWeights.shared.removePlaylist(playlist.id)
        saveNow()
    }

    func renamePlaylist(_ playlist: UserPlaylist, to newName: String) {
        loadIfNeeded()
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[idx].name = trimmed.isEmpty ? playlists[idx].name : trimmed
        playlists[idx].updatedAt = Date()
        saveNow()
    }

    func addTracks(_ urls: [URL], to playlistID: UserPlaylist.ID) {
        loadIfNeeded()
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let newTracks = normalizeTracks(from: urls)
        guard !newTracks.isEmpty else { return }

        var existingKeys = Set(playlists[idx].tracks.map { pathKey($0.path) })
        var existingLegacyKeys = Set(playlists[idx].tracks.map { PathKey.legacy(path: $0.path) })
        var appended: [UserPlaylist.Track] = []
        appended.reserveCapacity(newTracks.count)
        for t in newTracks {
            let k = pathKey(t.path)
            let legacy = PathKey.legacy(path: t.path)
            if existingKeys.contains(k) || existingLegacyKeys.contains(legacy) { continue }
            existingKeys.insert(k)
            existingLegacyKeys.insert(legacy)
            appended.append(t)
        }
        guard !appended.isEmpty else { return }

        playlists[idx].tracks.append(contentsOf: appended)
        playlists[idx].updatedAt = Date()
        saveNow()
    }

    func removeTrack(path: String, from playlistID: UserPlaylist.ID) {
        loadIfNeeded()
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let targetKeys = Set(pathLookupKeys(path))
        let before = playlists[idx].tracks.count
        playlists[idx].tracks.removeAll {
            let keys = pathLookupKeys($0.path)
            return keys.contains(where: targetKeys.contains)
        }
        if playlists[idx].tracks.count != before {
            playlists[idx].updatedAt = Date()
            PlaybackWeights.shared.removeTrack(URL(fileURLWithPath: path), fromPlaylist: playlistID)
            saveNow()
        }
    }

    func playlist(for id: UserPlaylist.ID?) -> UserPlaylist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    // MARK: - Persistence

    private func saveNow() {
        guard let url = playlistsFileURL() else { return }
        let payload = StoreFile(version: formatVersion, playlists: playlists)
        ioQueue.async { [payload] in
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                PersistenceLogger.log("保存歌单失败: \(error)")
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(title: "歌单保存失败", subtitle: "请检查磁盘权限或空间")
                }
            }
        }
    }

    private func playlistsFileURL() -> URL? {
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
        return dir.appendingPathComponent(playlistsFileName, isDirectory: false)
    }

    // MARK: - Normalization

    private func normalizeTracks(from urls: [URL]) -> [UserPlaylist.Track] {
        guard !urls.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [UserPlaylist.Track] = []
        results.reserveCapacity(urls.count)
        for url in urls {
            let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
            let key = pathKey(path)
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(UserPlaylist.Track(path: path))
        }
        return results
    }

    private func pathKey(_ path: String) -> String {
        PathKey.canonical(path: path)
    }

    private func pathLookupKeys(_ path: String) -> [String] {
        PathKey.lookupKeys(forPath: path)
    }
}

extension PlaylistsStore {
    func debugSetPlaylistsForTesting(_ items: [UserPlaylist], selectedID: UserPlaylist.ID? = nil) {
        playlists = items
        selectedPlaylistID = selectedID ?? items.first?.id
        isLoaded = true
        loadTask = nil
    }
}
