import Foundation
import Combine

@MainActor
final class PlaylistsStore: ObservableObject {
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published var selectedPlaylistID: UserPlaylist.ID?
    @Published private(set) var isReady = false

    private let playlistsFileName = "user-playlists.json"
    private let formatVersion = 1
    private let playlistsFileURLOverride: URL?

    private struct StoreFile: Codable {
        let version: Int
        let playlists: [UserPlaylist]
    }

    private struct StoreVersionProbe: Codable {
        let version: Int?
    }

    /// Set when the on-disk store uses a future schema version or cannot be
    /// decoded. While true, mutation entry points do not modify memory and
    /// no write path is allowed to overwrite the original file bytes.
    private(set) var isPersistenceReadOnly = false

    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "playlists.persistence", qos: .utility)
    private let ioQueueKey = DispatchSpecificKey<Void>()

    private let signatureCaptureCoordinator: SignatureCaptureCoordinator

    init(playlistsFileURLOverride: URL? = nil, signatureCaptureService: SignatureCaptureService? = nil) {
        self.playlistsFileURLOverride = playlistsFileURLOverride
        let service = signatureCaptureService ?? SignatureCaptureService()
        self.signatureCaptureCoordinator = SignatureCaptureCoordinator(service: service)
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
            isReady = true
            return
        }

        enum LoadOutcome {
            case missing
            case loaded(StoreFile)
            case protectedFuture(Int)
            case protectedCorrupt
        }

        let outcome: LoadOutcome = await withCheckedContinuation { continuation in
            ioQueue.async {
                let fm = FileManager.default
                guard fm.fileExists(atPath: url.path) else {
                    continuation.resume(returning: .missing)
                    return
                }

                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    // File exists but cannot be read: protect it
                    Self.quarantineCorruptedFile(url: url, data: nil, reason: "unreadable")
                    continuation.resume(returning: .protectedCorrupt)
                    return
                }

                // Probe version first to detect future schemas
                if let probe = try? JSONDecoder().decode(StoreVersionProbe.self, from: data),
                   let version = probe.version,
                   version > self.formatVersion {
                    continuation.resume(returning: .protectedFuture(version))
                    return
                }

                // Attempt full decode
                guard let store = try? JSONDecoder().decode(StoreFile.self, from: data) else {
                    Self.quarantineCorruptedFile(url: url, data: data, reason: "decode-failed")
                    continuation.resume(returning: .protectedCorrupt)
                    return
                }

                // Verify version matches current format
                guard store.version == self.formatVersion else {
                    continuation.resume(returning: .protectedFuture(store.version))
                    return
                }

                continuation.resume(returning: .loaded(store))
            }
        }

        switch outcome {
        case .missing:
            break
        case .loaded(let store):
            playlists = store.playlists
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlists.first?.id
            }
        case .protectedFuture(let version):
            isPersistenceReadOnly = true
            PersistenceLogger.log("检测到未来歌单文件版本 \(version)（当前支持 \(formatVersion)），进入只读模式保护数据")
            DispatchQueue.main.async {
                PersistenceLogger.notifyUser(
                    title: "歌单文件版本过新",
                    subtitle: "可能由新版本创建，当前版本只读保护"
                )
            }
        case .protectedCorrupt:
            isPersistenceReadOnly = true
        }

        loadTask = nil
        isReady = true
    }

    func createEmptyPlaylist(name: String) -> UserPlaylist.ID? {
        loadIfNeeded()
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return nil }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名歌单" : trimmed

        let playlist = UserPlaylist(name: finalName, tracks: [])
        playlists.insert(playlist, at: 0)
        selectedPlaylistID = playlist.id
        saveNow()
        return playlist.id
    }

    func createPlaylist(name: String, trackURLs: [URL]) async -> UserPlaylist.ID? {
        await ensureLoaded()
        let tracks = normalizeTracks(from: trackURLs)
        return await createPlaylistWithTracks(name: name, tracks: tracks)
    }

    func createPlaylist(name: String, tracks: [UserPlaylist.Track]) async -> UserPlaylist.ID? {
        await ensureLoaded()
        return await createPlaylistWithTracks(name: name, tracks: tracks)
    }

    private func createPlaylistWithTracks(name: String, tracks: [UserPlaylist.Track]) async -> UserPlaylist.ID? {
        loadIfNeeded()
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return nil }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名歌单" : trimmed

        guard !tracks.isEmpty else {
            return createEmptyPlaylist(name: finalName)
        }

        // Submit batch for signature capture
        let batch = SignatureCaptureBatch(id: UUID(), playlistID: nil, tracks: tracks)
        guard let (batchID, task) = await signatureCaptureCoordinator.submitBatch(batch) else {
            return nil  // Terminating, reject
        }

        // Single completion path: await result → validate → merge → finish
        let result = await task.value

        // Re-validate write protection after async work
        guard !isPersistenceReadOnly else {
            await signatureCaptureCoordinator.finishBatch(batchID)
            return nil
        }

        let playlist = UserPlaylist(name: finalName, tracks: result.enrichedTracks)
        playlists.insert(playlist, at: 0)
        selectedPlaylistID = playlist.id
        saveNow()

        await signatureCaptureCoordinator.finishBatch(batchID)
        return playlist.id
    }

    func deletePlaylist(_ playlist: UserPlaylist) {
        loadIfNeeded()
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return }
        playlists.removeAll { $0.id == playlist.id }
        if selectedPlaylistID == playlist.id {
            selectedPlaylistID = playlists.first?.id
        }
        _ = PlaybackWeights.shared.removePlaylist(playlist.id)
        saveNow()
    }

    func renamePlaylist(_ playlist: UserPlaylist, to newName: String) {
        loadIfNeeded()
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return }
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[idx].name = trimmed.isEmpty ? playlists[idx].name : trimmed
        playlists[idx].updatedAt = Date()
        saveNow()
    }

    func addTracks(_ urls: [URL], to playlistID: UserPlaylist.ID) async -> Int {
        await ensureLoaded()
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return 0 }
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return 0 }

        let newTracks = normalizeTracks(from: urls)
        guard !newTracks.isEmpty else { return 0 }

        // First deduplication pass against existing playlist
        var existingKeys = Set(playlists[idx].tracks.map { pathKey($0.path) })
        var existingLegacyKeys = Set(playlists[idx].tracks.map { PathKey.legacy(path: $0.path) })
        var candidateTracks: [UserPlaylist.Track] = []
        candidateTracks.reserveCapacity(newTracks.count)
        for t in newTracks {
            let k = pathKey(t.path)
            let legacy = PathKey.legacy(path: t.path)
            if existingKeys.contains(k) || existingLegacyKeys.contains(legacy) { continue }
            existingKeys.insert(k)
            existingLegacyKeys.insert(legacy)
            candidateTracks.append(t)
        }
        guard !candidateTracks.isEmpty else { return 0 }

        // Submit batch for signature capture
        let batch = SignatureCaptureBatch(id: UUID(), playlistID: playlistID, tracks: candidateTracks)
        guard let (batchID, task) = await signatureCaptureCoordinator.submitBatch(batch) else {
            return 0  // Terminating, reject
        }

        let result = await task.value

        // Re-validate after async work: write protection, playlist still exists
        guard !isPersistenceReadOnly else {
            await signatureCaptureCoordinator.finishBatch(batchID)
            return 0
        }
        guard let currentIdx = playlists.firstIndex(where: { $0.id == playlistID }) else {
            await signatureCaptureCoordinator.finishBatch(batchID)
            return 0  // Playlist was deleted
        }

        // Second deduplication pass: playlist may have changed during capture
        var currentKeys = Set(playlists[currentIdx].tracks.map { pathKey($0.path) })
        var currentLegacyKeys = Set(playlists[currentIdx].tracks.map { PathKey.legacy(path: $0.path) })
        var finalTracks: [UserPlaylist.Track] = []
        finalTracks.reserveCapacity(result.enrichedTracks.count)
        for t in result.enrichedTracks {
            let k = pathKey(t.path)
            let legacy = PathKey.legacy(path: t.path)
            if currentKeys.contains(k) || currentLegacyKeys.contains(legacy) { continue }
            currentKeys.insert(k)
            currentLegacyKeys.insert(legacy)
            finalTracks.append(t)
        }

        guard !finalTracks.isEmpty else {
            await signatureCaptureCoordinator.finishBatch(batchID)
            return 0
        }

        playlists[currentIdx].tracks.append(contentsOf: finalTracks)
        playlists[currentIdx].updatedAt = Date()
        saveNow()

        await signatureCaptureCoordinator.finishBatch(batchID)
        return finalTracks.count
    }

    func removeTrack(path: String, from playlistID: UserPlaylist.ID) {
        loadIfNeeded()
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return }
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let targetKeys = Set(pathLookupKeys(path))
        let before = playlists[idx].tracks.count
        playlists[idx].tracks.removeAll {
            let keys = pathLookupKeys($0.path)
            return keys.contains(where: targetKeys.contains)
        }
        if playlists[idx].tracks.count != before {
            playlists[idx].updatedAt = Date()
            _ = PlaybackWeights.shared.removeTrack(URL(fileURLWithPath: path), fromPlaylist: playlistID)
            saveNow()
        }
    }

    func playlist(for id: UserPlaylist.ID?) -> UserPlaylist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    // MARK: - Persistence

    private func saveNow() {
        guard isReady, loadTask == nil, !isPersistenceReadOnly else { return }
        guard let url = playlistsFileURL() else { return }
        let payload = StoreFile(version: formatVersion, playlists: playlists)
        ioQueue.async { [payload] in
            Self.persist(payload, to: url)
        }
    }

    /// Drains all pending signature capture batches and flushes persistence.
    /// Must be called during app termination to ensure no data loss.
    func drainAndFlushForTermination() async {
        await signatureCaptureCoordinator.drainForTermination()
        flushPersistence()
    }

    /// Wait until termination has started (for testing)
    func waitUntilTerminationStartedForTesting() async {
        await signatureCaptureCoordinator.waitUntilTerminationStartedForTesting()
    }

    /// Drains queued snapshots and persists the latest user-playlist state.
    /// Called during orderly app termination so a just-created playlist cannot
    /// be lost while its asynchronous write is still pending.
    func flushPersistence() {
        guard isLoaded, loadTask == nil else {
            // Never snapshot the temporary empty state while the initial disk
            // load is still waiting to apply on the main actor. Draining the IO
            // queue is safe; writing here could replace an existing library.
            if DispatchQueue.getSpecific(key: ioQueueKey) == nil {
                ioQueue.sync {}
            }
            return
        }
        guard !isPersistenceReadOnly else {
            // Read-only mode: drain pending writes but do not generate new snapshots.
            if DispatchQueue.getSpecific(key: ioQueueKey) == nil {
                ioQueue.sync {}
            }
            return
        }
        guard let url = playlistsFileURL() else { return }
        let payload = StoreFile(version: formatVersion, playlists: playlists)
        let operation = { Self.persist(payload, to: url) }
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            operation()
        } else {
            ioQueue.sync(execute: operation)
        }
    }

    nonisolated private static func persist(_ payload: StoreFile, to url: URL) {
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

    nonisolated private static func quarantineCorruptedFile(url: URL, data: Data?, reason: String) {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let quarantineURL = directory.appendingPathComponent("\(baseName).corrupted.\(UUID().uuidString).json")

        if let data = data {
            do {
                try data.write(to: quarantineURL, options: .atomic)
                PersistenceLogger.log("已隔离损坏的歌单文件到: \(quarantineURL.path) (原因: \(reason))")
            } catch {
                PersistenceLogger.log("无法写入隔离文件 \(quarantineURL.path): \(error)")
            }
        } else {
            PersistenceLogger.log("歌单文件损坏但无法读取原始数据: \(url.path) (原因: \(reason))")
        }

        DispatchQueue.main.async {
            PersistenceLogger.notifyUser(
                title: "歌单文件已损坏",
                subtitle: "原文件已保护，诊断信息: \(reason)"
            )
        }
    }

    private func playlistsFileURL() -> URL? {
        if let playlistsFileURLOverride {
            let directory = playlistsFileURLOverride.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                } catch {
                    return nil
                }
            }
            return playlistsFileURLOverride
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
        isReady = true
    }
}
