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
    private let ioQueue = DispatchQueue(label: "playlists.persistence", qos: .utility)
    private let ioQueueKey = DispatchSpecificKey<Void>()

    init() {
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let url = playlistsFileURL() else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url) else { return }
            guard let decoded = try? JSONDecoder().decode(StoreFile.self, from: data), decoded.version == self.formatVersion else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playlists = decoded.playlists
                if self.selectedPlaylistID == nil {
                    self.selectedPlaylistID = self.playlists.first?.id
                }
            }
        }
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
        var appended: [UserPlaylist.Track] = []
        appended.reserveCapacity(newTracks.count)
        for t in newTracks {
            let k = pathKey(t.path)
            if existingKeys.contains(k) { continue }
            existingKeys.insert(k)
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
        let targetKey = pathKey(path)
        let before = playlists[idx].tracks.count
        playlists[idx].tracks.removeAll { pathKey($0.path) == targetKey }
        if playlists[idx].tracks.count != before {
            playlists[idx].updatedAt = Date()
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
                // Best-effort only.
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
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
