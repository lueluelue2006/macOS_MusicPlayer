import Foundation
import Combine

final class PlaylistManager: ObservableObject {
    @Published var audioFiles: [AudioFile] = []
    @Published var currentIndex: Int = 0
    @Published var filteredFiles: [AudioFile] = []
    @Published var searchText: String = ""
    /// Which collection playback controls operate on (queue vs a user playlist).
    @Published private(set) var playbackScope: PlaybackScope = .queue
    @Published var scanSubfolders: Bool = true { // 默认开启子文件夹扫描
        didSet { saveScanSubfoldersPreference() }
    }
    private let userScanSubfoldersKey = "userScanSubfoldersEnabled"
    
    private var shuffleQueue: [Int] = []
    private var shuffleIndex = 0

    // Playlist-scope playback (order defined by user playlist, not by queue order).
    private var playbackPlaylistTrackKeys: [String] = []
    private var playbackPlaylistPositionByKey: [String: Int] = [:]
    private var playlistShuffleQueueKeys: [String] = []
    private var playlistShuffleIndex: Int = 0
    
    @Published var isRestoringPlaylist = false  // 标记是否正在恢复播放列表
    private var didPerformInitialRestore: Bool = false
    private var initialRestoreTask: Task<Void, Never>?
    private var restoredMetadataHydrationTask: Task<Void, Never>?
    
    // MARK: - 添加/扫描进度（可取消）
    @Published private(set) var isAddingFiles: Bool = false
    @Published private(set) var addFilesPhase: String = ""
    @Published private(set) var addFilesDetail: String = ""
    @Published private(set) var addFilesProgressCurrent: Int = 0
    @Published private(set) var addFilesProgressTotal: Int = 0

    private var addFilesTask: Task<Void, Never>?
    private var pendingAddURLs: [URL] = []

    // MARK: - 不可播放标记（按路径）
    @Published private(set) var unplayableReasons: [String: String] = [:]

    private struct SavedPlaylist: Codable {
        let paths: [String]
        let currentIndex: Int
    }
    private let playlistFileName = "playlist.json"
    private let playlistIOQueue = DispatchQueue(label: "playlist.persistence", qos: .utility)
    private let playlistIOQueueKey = DispatchSpecificKey<Void>()
    private let metadataGate = ConcurrencyGate(maxConcurrent: 4) // 限制元数据加载并发
    private let durationGate = ConcurrencyGate(maxConcurrent: 2) // 限制时长计算并发（更轻量但也需要控速）

    // MARK: - Playback scope persistence
    private let userPlaybackScopeKindKey = "userPlaybackScopeKind"
    private let userPlaybackScopePlaylistIDKey = "userPlaybackScopePlaylistID"
    private enum PlaybackScopePersistenceKind: String {
        case queue
        case playlist
    }

    @MainActor private var durationPrefetchTask: Task<Void, Never>?
    @MainActor private var pendingDurationURLs: [URL] = []
    @MainActor private var pendingDurationURLKeys: Set<String> = []
    @MainActor private var pendingDurationIndex: Int = 0

    init() {
        playlistIOQueue.setSpecific(key: playlistIOQueueKey, value: ())
        loadScanSubfoldersPreference()

        // When weights change, regenerate shuffle queues on next usage.
        NotificationCenter.default.addObserver(
            forName: .playbackWeightsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetShuffleQueue()
        }
    }

    // MARK: - Playback scope

    /// Switch playback controls to operate on the main queue.
    func setPlaybackScopeQueue() {
        if playbackScope != .queue {
            playbackScope = .queue
        }
        playbackPlaylistTrackKeys.removeAll(keepingCapacity: true)
        playbackPlaylistPositionByKey.removeAll(keepingCapacity: true)
        resetPlaylistShuffleQueue()
        persistPlaybackScope(.queue)
    }

    /// Switch playback controls to operate on a specific user playlist (in its playlist order).
    /// - Note: `trackURLsInOrder` should contain only playable tracks in the playlist's order.
    func setPlaybackScopePlaylist(_ playlistID: UserPlaylist.ID, trackURLsInOrder: [URL]) {
        playbackScope = .playlist(playlistID)
        playbackPlaylistTrackKeys = trackURLsInOrder.map { pathKey($0) }
        rebuildPlaybackPlaylistPositions()
        resetPlaylistShuffleQueue()
        persistPlaybackScope(.playlist(playlistID))
    }

    /// Update the active playlist scope track list (e.g. after adding/removing tracks),
    /// keeping the existing shuffle queue as stable as possible.
    func updatePlaybackScopePlaylistTracksIfActive(_ playlistID: UserPlaylist.ID, trackURLsInOrder: [URL]) {
        guard playbackScope == .playlist(playlistID) else { return }

        let oldKeys = playbackPlaylistTrackKeys
        let newKeys = trackURLsInOrder.map { pathKey($0) }

        playbackPlaylistTrackKeys = newKeys
        rebuildPlaybackPlaylistPositions()
        updatePlaylistShuffleQueue(oldKeys: oldKeys, newKeys: newKeys)
    }

    private func persistPlaybackScope(_ scope: PlaybackScope) {
        let d = UserDefaults.standard
        switch scope {
        case .queue:
            d.set(PlaybackScopePersistenceKind.queue.rawValue, forKey: userPlaybackScopeKindKey)
            d.removeObject(forKey: userPlaybackScopePlaylistIDKey)
        case .playlist(let id):
            d.set(PlaybackScopePersistenceKind.playlist.rawValue, forKey: userPlaybackScopeKindKey)
            d.set(id.uuidString, forKey: userPlaybackScopePlaylistIDKey)
        }
    }

    /// Restore last used playback scope (queue vs a specific user playlist).
    ///
    /// - Important: Call this after the queue (`audioFiles`) has been restored, otherwise playlist-scope
    ///   playback won't be able to map tracks to queue indices.
    func restorePlaybackScopeIfNeeded(playlistsStore: PlaylistsStore) async {
        let d = UserDefaults.standard
        guard
            let rawKind = d.string(forKey: userPlaybackScopeKindKey),
            let kind = PlaybackScopePersistenceKind(rawValue: rawKind)
        else {
            return
        }

        switch kind {
        case .queue:
            await MainActor.run { [weak self] in
                self?.setPlaybackScopeQueue()
            }

        case .playlist:
            guard
                let rawID = d.string(forKey: userPlaybackScopePlaylistIDKey),
                let playlistID = UUID(uuidString: rawID)
            else {
                await MainActor.run { [weak self] in
                    self?.setPlaybackScopeQueue()
                }
                return
            }

            let playlist: UserPlaylist? = await MainActor.run {
                playlistsStore.playlist(for: playlistID)
            }
            guard let playlist else {
                await MainActor.run { [weak self] in
                    self?.setPlaybackScopeQueue()
                }
                return
            }

            let fm = FileManager.default
            let urlsInOrder = playlist.tracks
                .map { URL(fileURLWithPath: $0.path) }
                .filter { fm.fileExists(atPath: $0.path) }

            if urlsInOrder.isEmpty {
                await MainActor.run { [weak self] in
                    self?.setPlaybackScopeQueue()
                }
                return
            }

            // Ensure playlist tracks exist in queue, but keep it lightweight:
            // - Prefer disk caches (duration/metadata)
            // - Fall back to filename-only placeholder (no AVAsset scan on startup)
            let existingQueueKeys: Set<String> = await MainActor.run {
                Set(self.audioFiles.flatMap { self.pathLookupKeys($0.url) })
            }

            var toAppend: [AudioFile] = []
            toAppend.reserveCapacity(8)
            var needsHydration: [URL] = []
            needsHydration.reserveCapacity(8)

            for url in urlsInOrder {
                let key = pathKey(url)
                if existingQueueKeys.contains(key) { continue }

                let duration = await DurationCache.shared.cachedDurationIfValid(for: url)
                if let cached = await MetadataCache.shared.cachedMetadataIfValid(for: url) {
                    toAppend.append(AudioFile(url: url, metadata: cached, duration: duration))
                } else {
                    let title = url.deletingPathExtension().lastPathComponent
                    let meta = AudioMetadata(
                        title: title.isEmpty ? "未知标题" : title,
                        artist: "未知艺术家",
                        album: "未知专辑",
                        year: nil,
                        genre: nil,
                        artwork: nil
                    )
                    toAppend.append(AudioFile(url: url, metadata: meta, duration: duration))
                    needsHydration.append(url)
                }
            }

            let filesToAppend = toAppend
            if !filesToAppend.isEmpty {
                await MainActor.run { [weak self] in
                    _ = self?.ensureInQueue(filesToAppend, focusURL: nil)
                }
            }

            await MainActor.run { [weak self] in
                self?.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: urlsInOrder)
            }

            // Best-effort: hydrate missing metadata in background (only for the newly appended tracks).
            let hydrationURLs = needsHydration
            guard !hydrationURLs.isEmpty else { return }
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let results: [(URL, AudioMetadata)] = await withTaskGroup(of: (URL, AudioMetadata).self) { group in
                    for url in hydrationURLs {
                        group.addTask { [weak self] in
                            guard let self else {
                                return (url, AudioMetadata(title: "未知标题", artist: "未知艺术家", album: "未知专辑", year: nil, genre: nil, artwork: nil))
                            }
                            let metadata = await self.loadCachedMetadata(from: url)
                            return (url, metadata)
                        }
                    }
                    var collected: [(URL, AudioMetadata)] = []
                    collected.reserveCapacity(hydrationURLs.count)
                    for await item in group {
                        collected.append(item)
                    }
                    return collected
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (url, metadata) in results {
                        let lookupSet = Set(self.pathLookupKeys(url))
                        if let index = self.audioFiles.firstIndex(where: { !lookupSet.isDisjoint(with: Set(self.pathLookupKeys($0.url))) }) {
                            let existing = self.audioFiles[index]
                            self.audioFiles[index] = AudioFile(url: existing.url, metadata: metadata, lyricsTimeline: existing.lyricsTimeline, duration: existing.duration)
                        }
                    }
                    self.updateFilteredFiles()
                }
            }
        }
    }

    /// Number of playable tracks in the current playback scope.
    func playbackScopePlayableCount() -> Int {
        switch playbackScope {
        case .queue:
            return audioFiles.indices.reduce(0) { acc, idx in
                acc + (isUnplayableIndex(idx) ? 0 : 1)
            }
        case .playlist:
            guard !playbackPlaylistTrackKeys.isEmpty else { return 0 }
            var count = 0
            for key in playbackPlaylistTrackKeys {
                guard let idx = indexInQueue(forPathKey: key) else { continue }
                if !isUnplayableIndex(idx) { count += 1 }
            }
            return count
        }
    }

    private func rebuildPlaybackPlaylistPositions() {
        playbackPlaylistPositionByKey.removeAll(keepingCapacity: true)
        for (idx, key) in playbackPlaylistTrackKeys.enumerated() {
            // Preserve the first occurrence if duplicates ever exist (shouldn't, but be defensive).
            if playbackPlaylistPositionByKey[key] == nil {
                playbackPlaylistPositionByKey[key] = idx
            }
        }
    }

    private func resetPlaylistShuffleQueue() {
        playlistShuffleQueueKeys.removeAll(keepingCapacity: true)
        playlistShuffleIndex = 0
    }

    private func updatePlaylistShuffleQueue(oldKeys: [String], newKeys: [String]) {
        guard !playlistShuffleQueueKeys.isEmpty else { return }
        guard case .playlist(let playlistID) = playbackScope else { return }

        let oldSet = Set(oldKeys)
        let newSet = Set(newKeys)
        let removed = oldSet.subtracting(newSet)
        let added = newKeys.filter { !oldSet.contains($0) }

        if !removed.isEmpty {
            playlistShuffleQueueKeys.removeAll { removed.contains($0) }
            playlistShuffleIndex = min(playlistShuffleIndex, playlistShuffleQueueKeys.count)
        }

        if !added.isEmpty {
            // Insert newly added tracks into the remaining shuffle window (after current index).
            let insertLowerBound = min(playlistShuffleIndex, playlistShuffleQueueKeys.count)
            for key in added {
                let weight = PlaybackWeights.shared.multiplier(forKey: key, scope: .playlist(playlistID))
                let u = Double.random(in: 0...1)
                let remaining = max(0, playlistShuffleQueueKeys.count - insertLowerBound)
                let fraction = pow(u, weight) // higher weight -> closer to 0 -> earlier
                let pos = insertLowerBound + Int((fraction * Double(remaining + 1)).rounded(.down))
                playlistShuffleQueueKeys.insert(key, at: pos)
            }
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    // MARK: - Initial restore (once per launch)
    @MainActor
    func performInitialRestoreIfNeeded(audioPlayer: AudioPlayer, playlistsStore: PlaylistsStore) {
        guard !didPerformInitialRestore else { return }
        didPerformInitialRestore = true

        initialRestoreTask?.cancel()
        initialRestoreTask = Task.detached(priority: .userInitiated) { [weak self, weak audioPlayer] in
            guard let self, let audioPlayer else { return }
            await playlistsStore.ensureLoaded()
            await self.loadSavedPlaylist(audioPlayer: audioPlayer)
            let skipRestore = await MainActor.run {
                // 若本次启动是通过 Finder/Dock 外部文件打开，则不恢复上次播放/播放范围
                audioPlayer.consumeSkipRestoreThisLaunch()
            }
            if skipRestore { return }

            await self.restorePlaybackScopeIfNeeded(playlistsStore: playlistsStore)

            await MainActor.run {
                if audioPlayer.currentFile == nil {
                    audioPlayer.loadLastPlayedFile()
                }
            }
        }
    }

    // MARK: - Add files queue (cancellable)
    @MainActor
    func enqueueAddFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingAddURLs.append(contentsOf: urls)
        startNextAddBatchIfNeeded()
    }

    @MainActor
    func cancelAddFiles() {
        addFilesTask?.cancel()
        addFilesTask = nil
        pendingAddURLs.removeAll()
        resetAddFilesProgress()
    }

    @MainActor
    private func startNextAddBatchIfNeeded() {
        guard addFilesTask == nil else { return }
        guard !pendingAddURLs.isEmpty else { return }

        let batch = pendingAddURLs
        pendingAddURLs.removeAll()
        isAddingFiles = true

        addFilesTask = Task { [weak self] in
            guard let self else { return }
            await self.addFilesBatch(batch)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.addFilesTask = nil
                if Task.isCancelled {
                    self.pendingAddURLs.removeAll()
                    self.resetAddFilesProgress()
                    return
                }
                if self.pendingAddURLs.isEmpty {
                    self.resetAddFilesProgress()
                } else {
                    self.startNextAddBatchIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func resetAddFilesProgress() {
        isAddingFiles = false
        addFilesPhase = ""
        addFilesDetail = ""
        addFilesProgressCurrent = 0
        addFilesProgressTotal = 0
    }

    // MARK: - Unplayable tracking
    func unplayableReason(for url: URL) -> String? {
        unplayableReasons[pathKey(url)]
    }

    @MainActor
    func markUnplayable(_ url: URL, reason: String) {
        let key = pathKey(url)
        unplayableReasons[key] = reason
        resetShuffleQueue()
    }

    @MainActor
    func clearUnplayable(_ url: URL) {
        let key = pathKey(url)
        if unplayableReasons.removeValue(forKey: key) != nil {
            resetShuffleQueue()
        }
    }

    @MainActor
    func clearAllUnplayableMarks() {
        guard !unplayableReasons.isEmpty else { return }
        unplayableReasons.removeAll()
        resetShuffleQueue()
    }

    private func isUnplayableIndex(_ index: Int) -> Bool {
        guard index >= 0, index < audioFiles.count else { return false }
        return unplayableReasons[pathKey(audioFiles[index].url)] != nil
    }
    
    /// Backward-compatible async API: enqueue and return immediately.
    func addFiles(_ urls: [URL]) async {
        await MainActor.run {
            self.enqueueAddFiles(urls)
        }
    }

    // MARK: - Batch add implementation
    private func addFilesBatch(_ urls: [URL]) async {
        if Task.isCancelled { return }

        let shouldScanSubfolders = await MainActor.run { self.scanSubfolders }

        var lastUIUpdate = Date.distantPast
        func updateUI(phase: String, detail: String, current: Int, total: Int, force: Bool = false) async {
            let now = Date()
            if !force && now.timeIntervalSince(lastUIUpdate) < 0.15 {
                return
            }
            lastUIUpdate = now
            await MainActor.run {
                self.isAddingFiles = true
                self.addFilesPhase = phase
                self.addFilesDetail = detail
                self.addFilesProgressCurrent = current
                self.addFilesProgressTotal = total
            }
        }

        await updateUI(phase: "扫描文件…", detail: "", current: 0, total: 0, force: true)
        let fileURLs = await collectAudioFileURLs(
            from: urls,
            scanSubfolders: shouldScanSubfolders,
            updateUI: updateUI
        )

        if Task.isCancelled { return }
        if fileURLs.isEmpty {
            await updateUI(phase: "未找到可导入的音频文件", detail: "", current: 0, total: 0, force: true)
            return
        }

        await updateUI(phase: "读取元数据…", detail: "", current: 0, total: fileURLs.count, force: true)

        var built: [AudioFile] = []
        built.reserveCapacity(fileURLs.count)

        var processed = 0
        await withTaskGroup(of: AudioFile?.self) { group in
            for url in fileURLs {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    if Task.isCancelled { return nil }
                    let metadata = await self.loadCachedMetadata(from: url)
                    if Task.isCancelled { return nil }
                    let duration = await DurationCache.shared.cachedDurationIfValid(for: url)
                    return AudioFile(url: url, metadata: metadata, duration: duration)
                }
            }

            for await item in group {
                if Task.isCancelled { break }
                processed += 1
                if let f = item { built.append(f) }
                if processed % 8 == 0 || processed == fileURLs.count {
                    await updateUI(
                        phase: "读取元数据…",
                        detail: item?.url.lastPathComponent ?? "",
                        current: processed,
                        total: fileURLs.count
                    )
                }
            }
        }

        if Task.isCancelled { return }

        // 去重（路径粒度）：仅保留首次出现的路径
        let newFilesDedupWithinBatch: [AudioFile] = {
            var seen = Set<String>()
            var seenLegacy = Set<String>()
            var result: [AudioFile] = []
            for f in built {
                let key = self.pathKey(f.url)
                let legacy = PathKey.legacy(for: f.url)
                if seen.contains(key) || seenLegacy.contains(legacy) { continue }
                seen.insert(key)
                seenLegacy.insert(legacy)
                result.append(f)
            }
            return result
        }()

        await MainActor.run {
            let wasEmpty = self.audioFiles.isEmpty
            // 与现有列表去重：若重复路径已存在，保留已有（更早）的条目，丢弃新增重复
            var existing = Set(self.audioFiles.map { self.pathKey($0.url) })
            var existingLegacy = Set(self.audioFiles.map { PathKey.legacy(for: $0.url) })
            var toAppend: [AudioFile] = []
            for f in newFilesDedupWithinBatch {
                let key = self.pathKey(f.url)
                let legacy = PathKey.legacy(for: f.url)
                if existing.contains(key) || existingLegacy.contains(legacy) { continue }
                existing.insert(key)
                existingLegacy.insert(legacy)
                toAppend.append(f)
            }
            let oldCount = self.audioFiles.count
            self.audioFiles.append(contentsOf: toAppend)
            self.updateFilteredFiles()
            self.enqueueDurationPrefetch(for: toAppend.map { $0.url })
            self.integrateNewQueueIndicesIntoShuffleQueue(oldCount: oldCount)

            self.savePlaylist()

            if wasEmpty && !self.audioFiles.isEmpty && !self.isRestoringPlaylist {
                NotificationCenter.default.post(name: .playlistDidAddFirstFiles, object: nil)
            }
        }
    }

    /// 收集音频文件 URL：支持文件夹扫描（可选子文件夹），并跳过符号链接目录以避免循环。
    private func collectAudioFileURLs(
        from urls: [URL],
        scanSubfolders: Bool,
        updateUI: (String, String, Int, Int, Bool) async -> Void
    ) async -> [URL] {
        let fileManager = FileManager.default
        var stack: [URL] = urls
        var visitedDirectories: Set<String> = []
        var results: [URL] = []

        var scannedItems = 0
        var foundFiles = 0

        while let url = stack.popLast() {
            if Task.isCancelled { break }
            scannedItems += 1

            if scannedItems % 64 == 0 {
                await Task.yield()
            }

            if scannedItems % 40 == 0 {
                await updateUI("扫描文件…", url.lastPathComponent, foundFiles, 0, false)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // Skip symlinked directories to avoid loops.
                let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                if isSymlink { continue }

                let canonical = PathKey.canonical(path: url.resolvingSymlinksInPath().standardizedFileURL.path)
                if visitedDirectories.contains(canonical) { continue }
                visitedDirectories.insert(canonical)

                do {
                    let contents = try fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )

                    for child in contents {
                        if Task.isCancelled { break }
                        let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values?.isSymbolicLink == true { continue }
                        if values?.isDirectory == true {
                            if scanSubfolders {
                                stack.append(child)
                            }
                            continue
                        }
                        if isAudioFile(child) {
                            results.append(child)
                            foundFiles += 1
                            if foundFiles % 20 == 0 {
                                await updateUI("扫描文件…", child.lastPathComponent, foundFiles, 0, false)
                            }
                        }
                    }
                } catch {
                    // Ignore unreadable folders.
                    continue
                }
            } else {
                if isAudioFile(url) {
                    results.append(url)
                    foundFiles += 1
                }
            }
        }

        // 去重（路径粒度）：仅保留首次出现的路径
        var seen = Set<String>()
        var deduped: [URL] = []
        deduped.reserveCapacity(results.count)
        for u in results {
            let key = pathKey(u)
            if !seen.contains(key) {
                seen.insert(key)
                deduped.append(u)
            }
        }
        await updateUI("扫描完成", "发现 \(deduped.count) 首", deduped.count, 0, true)
        return deduped
    }
    
    // 更新文件的元数据（仅覆盖指定字段：标题/艺术家/专辑/年份/类型）
    func updateFileMetadata(_ file: AudioFile, title: String, artist: String, album: String, year: String?, genre: String?) {
        if let index = audioFiles.firstIndex(where: { $0.id == file.id }) {
            // 创建新的元数据
            let newMetadata = AudioMetadata(
                title: title.isEmpty ? "未知标题" : title,
                artist: artist.isEmpty ? "未知艺术家" : artist,
                album: album.isEmpty ? "未知专辑" : album,
                year: (year?.isEmpty == false ? year : audioFiles[index].metadata.year),
                genre: (genre?.isEmpty == false ? genre : audioFiles[index].metadata.genre),
                artwork: audioFiles[index].metadata.artwork
            )
            
            // 保留已有的歌词时间轴
            let existingLyrics = audioFiles[index].lyricsTimeline
            
            // 创建新的AudioFile
            let newFile = AudioFile(url: file.url, metadata: newMetadata, lyricsTimeline: existingLyrics, duration: file.duration)
            audioFiles[index] = newFile
            updateFilteredFiles()

            // 同步更新磁盘元数据缓存（仅基本字段；失效由 mtime+size 保证）
            Task.detached(priority: .utility) {
                await MetadataCache.shared.storeBasicMetadata(newMetadata, for: file.url)
            }
        }
    }
    
    // 刷新单个文件的元数据（从文件重新读取）
    func refreshFileMetadata(_ file: AudioFile) async {
        // 强制清除所有缓存，重新创建 AVAsset
        let newMetadata = await loadFreshMetadata(from: file.url)
        await MetadataCache.shared.storeBasicMetadata(newMetadata, for: file.url)

        await MainActor.run {
            guard let refreshedIndex = self.audioFiles.firstIndex(where: { $0.id == file.id }) else {
                return
            }
            let existing = self.audioFiles[refreshedIndex]
            let newFile = AudioFile(url: existing.url, metadata: newMetadata, duration: existing.duration)
            self.audioFiles[refreshedIndex] = newFile
            self.updateFilteredFiles()
        }

        // 清除该文件的歌词缓存，确保后续重新解析（包括侧载 LRC 或嵌入变更）
        await LyricsService.shared.invalidate(for: file.url)
    }
    
    // 刷新所有文件的元数据
    func refreshAllMetadata(audioPlayer: AudioPlayer? = nil) async {
        // 记录当前播放歌曲及其歌词（如果已加载），用于刷新时优先保留
        let currentFileURL = audioPlayer?.currentFile?.url
        // 刷新应当反映外部更改（尤其是 .lrc），不再盲目保留旧歌词
        // let currentLyrics = audioPlayer?.lyricsTimeline

        let refreshedFiles: [AudioFile] = await withTaskGroup(of: (Int, AudioFile).self) { group in
            for (index, file) in audioFiles.enumerated() {
                group.addTask {
                    let newMetadata = await self.loadFreshMetadata(from: file.url)
                    await MetadataCache.shared.storeBasicMetadata(newMetadata, for: file.url)
                    // 不保留歌词时间轴，强制后续重新解析（避免外部 .lrc 或嵌入歌词更新后不生效）
                    let newFile = AudioFile(url: file.url, metadata: newMetadata, lyricsTimeline: nil, duration: file.duration)
                    return (index, newFile)
                }
            }
            
            var results: [(Int, AudioFile)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        
        await MainActor.run {
            audioFiles = refreshedFiles
            updateFilteredFiles()

            // 如果有正在播放的文件，更新AudioPlayer中的引用
            if let currentURL = currentFileURL,
                let audioPlayer = audioPlayer,
               let newCurrentFile = audioFiles.first(where: { $0.url == currentURL }) {
                // 暂时保留播放器当前显示的歌词，待下面主动重载后替换
                let mergedCurrent = AudioFile(url: newCurrentFile.url, metadata: newCurrentFile.metadata, lyricsTimeline: audioPlayer.lyricsTimeline, duration: newCurrentFile.duration)
                audioPlayer.currentFile = mergedCurrent
            }
        }

        // 全量刷新后：清空所有歌词缓存并主动为“当前曲目”重载歌词
        await LyricsService.shared.invalidateAll()
        // 清空封面（仅保留当前缩略图，不做跨曲目缓存），避免封面不更新
        if let audioPlayer = audioPlayer {
            await audioPlayer.clearArtworkCache()
        }
        // 保留音量均衡缓存：避免“完全刷新”导致所有歌曲都需要重新分析。
        // 若用户确实需要重算（例如音频内容被替换），可在菜单或“音量均衡分析”页手动清空缓存。
        if let currentURL = currentFileURL, let audioPlayer = audioPlayer {
            let result = await LyricsService.shared.loadLyrics(for: currentURL)
            await MainActor.run {
                switch result {
                case .success(let timeline):
                    audioPlayer.lyricsTimeline = timeline
                    // 将新时间轴写回列表中的对应条目和 currentFile
                    if let idx = self.audioFiles.firstIndex(where: { $0.url == currentURL }) {
                        let f = self.audioFiles[idx]
                        self.audioFiles[idx] = AudioFile(url: f.url, metadata: f.metadata, lyricsTimeline: timeline, duration: f.duration)
                    }
                    if let cur = audioPlayer.currentFile, cur.url == currentURL {
                        audioPlayer.currentFile = AudioFile(url: cur.url, metadata: cur.metadata, lyricsTimeline: timeline, duration: cur.duration)
                    }
                    // 彻底刷新当前曲目的底层播放器，确保持续播放但载入新文件内容
                    audioPlayer.reloadCurrentPreservingState()
                case .failure:
                    audioPlayer.lyricsTimeline = nil
                    if let idx = self.audioFiles.firstIndex(where: { $0.url == currentURL }) {
                        let f = self.audioFiles[idx]
                        self.audioFiles[idx] = AudioFile(url: f.url, metadata: f.metadata, lyricsTimeline: nil, duration: f.duration)
                    }
                    if let cur = audioPlayer.currentFile, cur.url == currentURL {
                        audioPlayer.currentFile = AudioFile(url: cur.url, metadata: cur.metadata, lyricsTimeline: nil, duration: cur.duration)
                    }
                    // 即便没有歌词，也要重载当前曲目，确保元数据/封面/时长更新
                    audioPlayer.reloadCurrentPreservingState()
                }
            }
        }
    }
    
    // 强制加载新的元数据，清除所有缓存
    func loadFreshMetadata(from url: URL) async -> AudioMetadata {
        await metadataGate.acquire()
        defer { Task { await metadataGate.release() } }
        // 创建一个全新的 AVAsset，不使用任何缓存
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            // 禁用所有缓存
            "AVURLAssetHTTPCookiesKey": [],
            "AVURLAssetAllowsCellularAccessKey": false
        ])
        
        // 强制重新加载元数据（优先 commonMetadata；部分 MP3 在 load(.metadata) 场景会返回空数组）
        do {
            // 使用现代异步API加载元数据，增加 20s 超时保护
            return try await AsyncTimeout.withTimeout(20) {
                await AudioMetadata.load(from: asset, includeArtwork: false)
            }
        } catch is TimeoutError {
            debugLog("加载元数据超时(20s)，使用回退解析: \(url.lastPathComponent)")
            return await AudioMetadata.load(from: asset, includeArtwork: false)
        } catch {
            debugLog("加载元数据失败: \(error)")
            // 如果异步加载失败，回退到同步方法
            return await AudioMetadata.load(from: asset, includeArtwork: false)
        }
    }

    /// 加载元数据（带磁盘缓存）：仅缓存标题/艺术家/专辑，并用 (mtime+size) 做失效判断。
    /// - 目的：重启/清空后重新导入时避免反复读取 AVAsset 元数据（更快、更省 CPU）。
    func loadCachedMetadata(from url: URL) async -> AudioMetadata {
        if let cached = await MetadataCache.shared.cachedMetadataIfValid(for: url) {
            return cached
        }
        let fresh = await loadFreshMetadata(from: url)
        await MetadataCache.shared.storeBasicMetadata(fresh, for: url)
        return fresh
    }
    
    func removeFile(at index: Int) {
        guard index < audioFiles.count else { return }
        let removedURL = audioFiles[index].url
        audioFiles.remove(at: index)
        unplayableReasons.removeValue(forKey: pathKey(removedURL))

        if audioFiles.isEmpty {
            setPlaybackScopeQueue()
        }
        
        if currentIndex >= index {
            currentIndex = max(0, currentIndex - 1)
        }
        
        updateFilteredFiles()
        resetShuffleQueue()
        savePlaylist() // 保存播放列表
    }
    
    @MainActor
    func clearAllFiles() {
        cancelDurationPrefetch()
        audioFiles.removeAll()
        filteredFiles.removeAll()
        currentIndex = 0
        searchText = ""
        unplayableReasons.removeAll()
        resetShuffleQueue()
        setPlaybackScopeQueue()
        savePlaylist() // 清空后保存
    }
    
    func searchFiles(_ query: String) {
        searchText = query
        updateFilteredFiles()
    }
    
    private func updateFilteredFiles() {
        if searchText.isEmpty {
            filteredFiles = audioFiles
        } else {
            filteredFiles = audioFiles.filter { file in
                file.metadata.title.localizedCaseInsensitiveContains(searchText) ||
                file.metadata.artist.localizedCaseInsensitiveContains(searchText) ||
                file.metadata.album.localizedCaseInsensitiveContains(searchText) ||
                file.url.lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    // MARK: - Direct append (for playlists feature)

    /// Append files to the current queue without re-reading metadata.
    /// - Note: Dedup is by normalized path key.
    /// - Returns: The index of `focusURL` in the queue after ensuring, if provided.
    @MainActor
    func ensureInQueue(_ files: [AudioFile], focusURL: URL? = nil) -> Int? {
        guard !files.isEmpty else { return nil }

        var indexByKey: [String: Int] = [:]
        indexByKey.reserveCapacity(audioFiles.count)
        for (idx, f) in audioFiles.enumerated() {
            indexByKey[pathKey(f.url)] = idx
        }

        let focusKey = focusURL.map { pathKey($0) }
        var focusIndex: Int? = focusKey.flatMap { indexByKey[$0] }

        var toAppend: [AudioFile] = []
        toAppend.reserveCapacity(files.count)

        for f in files {
            let key = pathKey(f.url)
            if let existing = indexByKey[key] {
                if focusIndex == nil, let focusKey, focusKey == key { focusIndex = existing }
                continue
            }

            let newIndex = audioFiles.count + toAppend.count
            indexByKey[key] = newIndex
            if focusIndex == nil, let focusKey, focusKey == key { focusIndex = newIndex }
            toAppend.append(f)
        }

        guard !toAppend.isEmpty else { return focusIndex }

        let oldCount = audioFiles.count
        audioFiles.append(contentsOf: toAppend)
        updateFilteredFiles()
        enqueueDurationPrefetch(for: toAppend.map(\.url))
        integrateNewQueueIndicesIntoShuffleQueue(oldCount: oldCount)
        savePlaylist()

        return focusIndex
    }
    
    func nextFile(isShuffling: Bool) -> AudioFile? {
        guard !audioFiles.isEmpty else { return nil }

        switch playbackScope {
        case .queue:
            return nextFileInQueue(isShuffling: isShuffling)
        case .playlist:
            return nextFileInPlaylist(isShuffling: isShuffling)
        }
    }

    /// 预览“下一首”（不改变 currentIndex，也不推进 shuffleIndex）。
    /// 用于“预加载下一首”场景：提前准备下一首音频，减少曲目切换间隙。
    func peekNextFile(isShuffling: Bool) -> AudioFile? {
        guard !audioFiles.isEmpty else { return nil }

        switch playbackScope {
        case .queue:
            return peekNextFileInQueue(isShuffling: isShuffling)
        case .playlist:
            return peekNextFileInPlaylist(isShuffling: isShuffling)
        }
    }
    
    func previousFile(isShuffling: Bool) -> AudioFile? {
        guard !audioFiles.isEmpty else { return nil }

        switch playbackScope {
        case .queue:
            return previousFileInQueue(isShuffling: isShuffling)
        case .playlist:
            return previousFileInPlaylist(isShuffling: isShuffling)
        }
    }
    
    func selectFile(at index: Int) -> AudioFile? {
        guard index < audioFiles.count else { return nil }
        currentIndex = index
        savePlaylist() // 保存当前索引
        return audioFiles[index]
    }
    
    func getRandomFile() -> AudioFile? {
        guard !audioFiles.isEmpty else { return nil }

        switch playbackScope {
        case .queue:
            return getRandomFileInQueue()
        case .playlist:
            return getRandomFileInPlaylist()
        }
    }
    
    // 获取一个随机文件，但排除当前正在播放的
    func getRandomFileExcludingCurrent() -> AudioFile? {
        switch playbackScope {
        case .queue:
            return getRandomFileExcludingCurrentInQueue()
        case .playlist:
            return getRandomFileExcludingCurrentInPlaylist()
        }
    }

    // MARK: - Playback in queue scope

    private func nextFileInQueue(isShuffling: Bool) -> AudioFile? {
        if isShuffling {
            return getNextShuffledFile()
        }

        let total = audioFiles.count
        var attempts = 0
        while attempts < total {
            currentIndex = (currentIndex + 1) % total
            attempts += 1
            if !isUnplayableIndex(currentIndex) {
                return audioFiles[currentIndex]
            }
        }
        return nil
    }

    private func previousFileInQueue(isShuffling: Bool) -> AudioFile? {
        if isShuffling {
            return getPreviousShuffledFile()
        }

        let total = audioFiles.count
        var attempts = 0
        while attempts < total {
            currentIndex = currentIndex > 0 ? currentIndex - 1 : total - 1
            attempts += 1
            if !isUnplayableIndex(currentIndex) {
                return audioFiles[currentIndex]
            }
        }
        return nil
    }

    private func peekNextFileInQueue(isShuffling: Bool) -> AudioFile? {
        if isShuffling {
            // 确保洗牌队列存在（允许提前创建队列；不会影响 UI）
            if shuffleQueue.isEmpty || shuffleIndex >= shuffleQueue.count {
                createShuffleQueue()
            }
            var i = shuffleIndex
            while i < shuffleQueue.count {
                let idx = shuffleQueue[i]
                if !isUnplayableIndex(idx) {
                    return audioFiles[idx]
                }
                i += 1
            }
            return nil
        }

        let total = audioFiles.count
        var attempts = 0
        var idx = currentIndex
        while attempts < total {
            idx = (idx + 1) % total
            attempts += 1
            if !isUnplayableIndex(idx) {
                return audioFiles[idx]
            }
        }
        return nil
    }

    private func getRandomFileInQueue() -> AudioFile? {
        createShuffleQueue()
        if !shuffleQueue.isEmpty {
            currentIndex = shuffleQueue[0]
            shuffleIndex = 1
            return audioFiles[currentIndex]
        }
        return nil
    }

    private func getRandomFileExcludingCurrentInQueue() -> AudioFile? {
        guard audioFiles.count > 1 else { return nil }

        let candidates = audioFiles.indices.filter { $0 != currentIndex && !isUnplayableIndex($0) }
        guard let idx = weightedRandomIndex(indices: candidates, scope: .queue) else { return nil }

        currentIndex = idx
        savePlaylist() // 保存新的索引
        return audioFiles[idx]
    }

    // MARK: - Playback in playlist scope

    private func nextFileInPlaylist(isShuffling: Bool) -> AudioFile? {
        guard !playbackPlaylistTrackKeys.isEmpty else { return nil }
        if isShuffling {
            return getNextShuffledFileInPlaylist()
        }

        let total = playbackPlaylistTrackKeys.count
        var attempts = 0
        var position = currentPlaylistPosition() ?? -1
        while attempts < total {
            position = (position + 1) % total
            attempts += 1
            let key = playbackPlaylistTrackKeys[position]
            guard let idx = indexInQueue(forPathKey: key) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            savePlaylist()
            return audioFiles[idx]
        }
        return nil
    }

    private func previousFileInPlaylist(isShuffling: Bool) -> AudioFile? {
        guard !playbackPlaylistTrackKeys.isEmpty else { return nil }
        if isShuffling {
            return getPreviousShuffledFileInPlaylist()
        }

        let total = playbackPlaylistTrackKeys.count
        var attempts = 0
        var position = currentPlaylistPosition() ?? 0
        while attempts < total {
            position = position > 0 ? (position - 1) : (total - 1)
            attempts += 1
            let key = playbackPlaylistTrackKeys[position]
            guard let idx = indexInQueue(forPathKey: key) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            savePlaylist()
            return audioFiles[idx]
        }
        return nil
    }

    private func peekNextFileInPlaylist(isShuffling: Bool) -> AudioFile? {
        guard !playbackPlaylistTrackKeys.isEmpty else { return nil }

        if isShuffling {
            if playlistShuffleQueueKeys.isEmpty || playlistShuffleIndex >= playlistShuffleQueueKeys.count {
                createPlaylistShuffleQueue()
            }
            var i = playlistShuffleIndex
            while i < playlistShuffleQueueKeys.count {
                let key = playlistShuffleQueueKeys[i]
                if let idx = indexInQueue(forPathKey: key), !isUnplayableIndex(idx) {
                    return audioFiles[idx]
                }
                i += 1
            }
            return nil
        }

        let total = playbackPlaylistTrackKeys.count
        var attempts = 0
        var position = currentPlaylistPosition() ?? -1
        while attempts < total {
            position = (position + 1) % total
            attempts += 1
            let key = playbackPlaylistTrackKeys[position]
            if let idx = indexInQueue(forPathKey: key), !isUnplayableIndex(idx) {
                return audioFiles[idx]
            }
        }
        return nil
    }

    private func getRandomFileInPlaylist() -> AudioFile? {
        createPlaylistShuffleQueue(startFromRandom: true)
        guard let firstKey = playlistShuffleQueueKeys.first else { return nil }
        guard let idx = indexInQueue(forPathKey: firstKey), !isUnplayableIndex(idx) else { return nil }
        currentIndex = idx
        savePlaylist()
        return audioFiles[idx]
    }

    private func getRandomFileExcludingCurrentInPlaylist() -> AudioFile? {
        guard playbackScopePlayableCount() > 1 else { return nil }
        guard case .playlist(let playlistID) = playbackScope else { return nil }

        let currentKey = currentPathKeyInQueue()
        var candidates: [String] = []
        candidates.reserveCapacity(playbackPlaylistTrackKeys.count)
        for key in playbackPlaylistTrackKeys {
            if key == currentKey { continue }
            guard let idx = indexInQueue(forPathKey: key) else { continue }
            if isUnplayableIndex(idx) { continue }
            candidates.append(key)
        }
        guard let chosenKey = weightedRandomKey(keys: candidates, scope: .playlist(playlistID)),
              let idx = indexInQueue(forPathKey: chosenKey),
              !isUnplayableIndex(idx)
        else { return nil }

        currentIndex = idx
        savePlaylist()
        return audioFiles[idx]
    }

    private func currentPathKeyInQueue() -> String? {
        guard currentIndex >= 0, currentIndex < audioFiles.count else { return nil }
        return pathLookupKeys(audioFiles[currentIndex].url).first
    }

    private func currentPlaylistPosition() -> Int? {
        guard let currentKey = currentPathKeyInQueue() else { return nil }
        return playbackPlaylistPositionByKey[currentKey]
    }

    private func indexInQueue(forPathKey key: String) -> Int? {
        let lookupSet = Set(PathKey.lookupKeys(forPath: key))
        for (idx, file) in audioFiles.enumerated() {
            if !lookupSet.isDisjoint(with: Set(pathLookupKeys(file.url))) {
                return idx
            }
        }
        return nil
    }

    private func integrateNewQueueIndicesIntoShuffleQueue(oldCount: Int) {
        guard oldCount >= 0, oldCount < audioFiles.count else { return }
        guard !shuffleQueue.isEmpty else { return }

        let newIndices = (oldCount..<audioFiles.count).filter { !isUnplayableIndex($0) }
        guard !newIndices.isEmpty else { return }

        let insertLowerBound = min(shuffleIndex, shuffleQueue.count)
        for idx in newIndices {
            let weight = PlaybackWeights.shared.multiplier(for: audioFiles[idx].url, scope: .queue)
            let u = Double.random(in: 0...1)
            let remaining = max(0, shuffleQueue.count - insertLowerBound)
            let fraction = pow(u, weight) // higher weight -> closer to 0 -> earlier
            let pos = insertLowerBound + Int((fraction * Double(remaining + 1)).rounded(.down))
            shuffleQueue.insert(idx, at: pos)
        }
    }

    // 洗牌算法
    private func createShuffleQueue() {
        let playable = audioFiles.indices.filter { !isUnplayableIndex($0) }
        shuffleQueue = weightedShuffleIndices(playable, scope: .queue)
        shuffleIndex = 0
    }

    private func createPlaylistShuffleQueue(startFromRandom: Bool = false) {
        // Build a playable list in playlist order (skip missing/not-in-queue and unplayable).
        var playableKeys: [String] = []
        playableKeys.reserveCapacity(playbackPlaylistTrackKeys.count)
        var seen = Set<String>()
        for key in playbackPlaylistTrackKeys {
            if seen.contains(key) { continue }
            seen.insert(key)
            guard let idx = indexInQueue(forPathKey: key) else { continue }
            if isUnplayableIndex(idx) { continue }
            playableKeys.append(key)
        }

        guard !playableKeys.isEmpty else {
            playlistShuffleQueueKeys.removeAll(keepingCapacity: true)
            playlistShuffleIndex = 0
            return
        }

        if startFromRandom {
            if case .playlist(let playlistID) = playbackScope {
                playlistShuffleQueueKeys = weightedShuffleKeys(playableKeys, scope: .playlist(playlistID))
            } else {
                playlistShuffleQueueKeys = playableKeys.shuffled()
            }
            playlistShuffleIndex = min(1, playlistShuffleQueueKeys.count)
            return
        }

        if let currentKey = currentPathKeyInQueue(),
           playableKeys.contains(currentKey),
           playableKeys.count > 1 {
            var rest = playableKeys.filter { $0 != currentKey }
            if case .playlist(let playlistID) = playbackScope {
                rest = weightedShuffleKeys(rest, scope: .playlist(playlistID))
            } else {
                rest.shuffle()
            }
            playlistShuffleQueueKeys = [currentKey] + rest
            playlistShuffleIndex = 1
        } else {
            if case .playlist(let playlistID) = playbackScope {
                playlistShuffleQueueKeys = weightedShuffleKeys(playableKeys, scope: .playlist(playlistID))
            } else {
                playlistShuffleQueueKeys = playableKeys.shuffled()
            }
            playlistShuffleIndex = 0
        }
    }

    // MARK: - Weighted shuffle/random helpers

    private func weightedRandomIndex(indices: [Int], scope: PlaybackWeights.Scope) -> Int? {
        guard !indices.isEmpty else { return nil }
        var total: Double = 0
        total = indices.reduce(into: 0) { acc, idx in
            acc += PlaybackWeights.shared.multiplier(for: audioFiles[idx].url, scope: scope)
        }
        guard total.isFinite, total > 0 else { return indices.randomElement() }

        var r = Double.random(in: 0..<total)
        for idx in indices {
            r -= PlaybackWeights.shared.multiplier(for: audioFiles[idx].url, scope: scope)
            if r <= 0 { return idx }
        }
        return indices.last
    }

    private func weightedRandomKey(keys: [String], scope: PlaybackWeights.Scope) -> String? {
        guard !keys.isEmpty else { return nil }
        let total = keys.reduce(into: 0.0) { acc, key in
            acc += PlaybackWeights.shared.multiplier(forKey: key, scope: scope)
        }
        guard total.isFinite, total > 0 else { return keys.randomElement() }

        var r = Double.random(in: 0..<total)
        for key in keys {
            r -= PlaybackWeights.shared.multiplier(forKey: key, scope: scope)
            if r <= 0 { return key }
        }
        return keys.last
    }

    /// Efraimidis–Spirakis: weighted random permutation without replacement.
    private func weightedShuffleIndices(_ indices: [Int], scope: PlaybackWeights.Scope) -> [Int] {
        guard indices.count >= 2 else { return indices }
        var keyed: [(Double, Int)] = []
        keyed.reserveCapacity(indices.count)
        for idx in indices {
            let w = max(0.000_001, PlaybackWeights.shared.multiplier(for: audioFiles[idx].url, scope: scope))
            let u = max(Double.leastNonzeroMagnitude, Double.random(in: 0...1))
            let k = -log(u) / w
            keyed.append((k, idx))
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map { $0.1 }
    }

    private func weightedShuffleKeys(_ keys: [String], scope: PlaybackWeights.Scope) -> [String] {
        guard keys.count >= 2 else { return keys }
        var keyed: [(Double, String)] = []
        keyed.reserveCapacity(keys.count)
        for key in keys {
            let w = max(0.000_001, PlaybackWeights.shared.multiplier(forKey: key, scope: scope))
            let u = max(Double.leastNonzeroMagnitude, Double.random(in: 0...1))
            let k = -log(u) / w
            keyed.append((k, key))
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map { $0.1 }
    }

    private func getNextShuffledFileInPlaylist() -> AudioFile? {
        if playlistShuffleQueueKeys.isEmpty || playlistShuffleIndex >= playlistShuffleQueueKeys.count {
            createPlaylistShuffleQueue()
        }

        while playlistShuffleIndex < playlistShuffleQueueKeys.count {
            let key = playlistShuffleQueueKeys[playlistShuffleIndex]
            playlistShuffleIndex += 1
            guard let idx = indexInQueue(forPathKey: key) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            savePlaylist()
            return audioFiles[idx]
        }
        return nil
    }

    private func getPreviousShuffledFileInPlaylist() -> AudioFile? {
        while playlistShuffleIndex > 0 {
            playlistShuffleIndex -= 1
            let key = playlistShuffleQueueKeys[playlistShuffleIndex]
            guard let idx = indexInQueue(forPathKey: key) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            savePlaylist()
            return audioFiles[idx]
        }
        return nil
    }
    
    private func getNextShuffledFile() -> AudioFile? {
        if shuffleQueue.isEmpty || shuffleIndex >= shuffleQueue.count {
            createShuffleQueue()
        }

        while shuffleIndex < shuffleQueue.count {
            let idx = shuffleQueue[shuffleIndex]
            shuffleIndex += 1
            if !isUnplayableIndex(idx) {
                currentIndex = idx
                return audioFiles[idx]
            }
        }
        return nil
    }
    
    private func getPreviousShuffledFile() -> AudioFile? {
        while shuffleIndex > 0 {
            shuffleIndex -= 1
            let idx = shuffleQueue[shuffleIndex]
            if !isUnplayableIndex(idx) {
                currentIndex = idx
                return audioFiles[idx]
            }
        }
        return nil
    }
    
    private func resetShuffleQueue() {
        shuffleQueue.removeAll()
        shuffleIndex = 0
        resetPlaylistShuffleQueue()
    }

    // MARK: - 子文件夹扫描偏好持久化
    private func loadScanSubfoldersPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userScanSubfoldersKey) != nil {
            self.scanSubfolders = d.bool(forKey: userScanSubfoldersKey)
        }
    }

    private func saveScanSubfoldersPreference() {
        let d = UserDefaults.standard
        d.set(scanSubfolders, forKey: userScanSubfoldersKey)
    }
    
	    private func isAudioFile(_ url: URL) -> Bool {
	        let audioExtensions = [
	            "mp3", "m4a", "aac", // MPEG family
	            "wav", "aif", "aiff", "aifc", "caf", // PCM/CoreAudio
	            "flac" // Lossless
	        ]
	        return audioExtensions.contains(url.pathExtension.lowercased())
	    }

    // 统一的路径键（Unicode 规范化 + 标准路径，不再强制 lowercased）
    private func pathKey(_ url: URL) -> String {
        return PathKey.canonical(for: url)
    }

    private func pathLookupKeys(_ url: URL) -> [String] {
        PathKey.lookupKeys(for: url)
    }
    
    // 当选择了新曲目时，尝试预取歌词（供未来调用）
    func preloadLyricsIfNeeded(for url: URL) async -> LyricsTimeline? {
        let result = await LyricsService.shared.loadLyrics(for: url)
        if case .success(let timeline) = result {
            return timeline
        }
        return nil
    }

    // MARK: - Duration prefetch (lazy + disk cache)

    /// Clear in-memory durations (for the current session) and restart lazy duration prefetch.
    /// - Note: This does **not** delete any music files. Disk cache is handled elsewhere.
    @MainActor
    func resetDurationsAndRestartPrefetch() {
        cancelDurationPrefetch()

        audioFiles = audioFiles.map { file in
            AudioFile(url: file.url, metadata: file.metadata, lyricsTimeline: file.lyricsTimeline, duration: nil)
        }
        filteredFiles = filteredFiles.map { file in
            AudioFile(url: file.url, metadata: file.metadata, lyricsTimeline: file.lyricsTimeline, duration: nil)
        }

        enqueueDurationPrefetch(for: audioFiles.map(\.url))
    }

    @MainActor
    private func enqueueDurationPrefetch(for urls: [URL]) {
        guard !urls.isEmpty else { return }

        // Only enqueue URLs that are currently missing duration (reduces queue churn).
        let missingKeys = Set(audioFiles.filter { $0.duration == nil }.map { pathKey($0.url) })
        guard !missingKeys.isEmpty else { return }

        for url in urls {
            let key = pathKey(url)
            guard missingKeys.contains(key) else { continue }
            if pendingDurationURLKeys.contains(key) { continue }
            pendingDurationURLKeys.insert(key)
            pendingDurationURLs.append(url)
        }

        startDurationPrefetchIfNeeded()
    }

    @MainActor
    private func startDurationPrefetchIfNeeded() {
        guard durationPrefetchTask == nil else { return }
        durationPrefetchTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runDurationPrefetchLoop()
        }
    }

    @MainActor
    private func cancelDurationPrefetch() {
        durationPrefetchTask?.cancel()
        durationPrefetchTask = nil
        pendingDurationURLs.removeAll(keepingCapacity: true)
        pendingDurationURLKeys.removeAll(keepingCapacity: true)
        pendingDurationIndex = 0
    }

    private func popNextDurationURL() async -> URL? {
        await MainActor.run {
            guard pendingDurationIndex < pendingDurationURLs.count else {
                pendingDurationURLs.removeAll(keepingCapacity: true)
                pendingDurationURLKeys.removeAll(keepingCapacity: true)
                pendingDurationIndex = 0
                durationPrefetchTask = nil
                return nil
            }

            let url = pendingDurationURLs[pendingDurationIndex]
            pendingDurationIndex += 1
            pendingDurationURLKeys.remove(pathKey(url))

            // Compact occasionally to avoid O(n^2) removeFirst costs.
            if pendingDurationIndex == pendingDurationURLs.count {
                pendingDurationURLs.removeAll(keepingCapacity: true)
                pendingDurationURLKeys.removeAll(keepingCapacity: true)
                pendingDurationIndex = 0
            } else if pendingDurationIndex > 32 && pendingDurationIndex * 2 > pendingDurationURLs.count {
                pendingDurationURLs.removeFirst(pendingDurationIndex)
                pendingDurationIndex = 0
            }

            return url
        }
    }

    @MainActor
    private func applyDuration(_ seconds: TimeInterval, for url: URL) {
        let keys = Set(pathLookupKeys(url))
        if let idx = audioFiles.firstIndex(where: { !Set(pathLookupKeys($0.url)).isDisjoint(with: keys) }) {
            let f = audioFiles[idx]
            if f.duration == nil {
                audioFiles[idx] = AudioFile(url: f.url, metadata: f.metadata, lyricsTimeline: f.lyricsTimeline, duration: seconds)
            }
        }
        if let idx = filteredFiles.firstIndex(where: { !Set(pathLookupKeys($0.url)).isDisjoint(with: keys) }) {
            let f = filteredFiles[idx]
            if f.duration == nil {
                filteredFiles[idx] = AudioFile(url: f.url, metadata: f.metadata, lyricsTimeline: f.lyricsTimeline, duration: seconds)
            }
        }
    }

    private func runDurationPrefetchLoop() async {
        while true {
            if Task.isCancelled { break }

            let busy = await MainActor.run { self.isAddingFiles || self.isRestoringPlaylist }
            if busy {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            guard let url = await popNextDurationURL() else { break }
            if Task.isCancelled { break }

            // Skip if no longer in the playlist, or already has a duration.
            let needsWork = await MainActor.run { () -> Bool in
                let lookupSet = Set(self.pathLookupKeys(url))
                guard let idx = self.audioFiles.firstIndex(where: { !lookupSet.isDisjoint(with: Set(self.pathLookupKeys($0.url))) }) else { return false }
                return self.audioFiles[idx].duration == nil
            }
            if !needsWork { continue }

            if let cached = await DurationCache.shared.cachedDurationIfValid(for: url) {
                await MainActor.run { self.applyDuration(cached, for: url) }
                continue
            }

            await durationGate.acquire()
            let loaded = await DurationService.loadDurationSeconds(for: url)
            await durationGate.release()

            if Task.isCancelled { break }
            guard let loaded else { continue }

            await DurationCache.shared.storeDuration(loaded, for: url)
            await MainActor.run { self.applyDuration(loaded, for: url) }
        }

        await MainActor.run {
            self.durationPrefetchTask = nil
        }
    }
    
    // MARK: - 保存和加载播放列表
    func savePlaylist() {
        let snapshot = SavedPlaylist(paths: audioFiles.map { $0.url.path }, currentIndex: currentIndex)
        debugLog("保存播放列表: \(snapshot.paths.count) 个文件, 当前索引: \(snapshot.currentIndex)")
        guard let url = playlistFileURL() else {
            PersistenceLogger.log("保存播放列表失败: 无法创建应用支持目录")
            DispatchQueue.main.async {
                PersistenceLogger.notifyUser(title: "播放列表保存失败", subtitle: "无法创建应用支持目录")
            }
            return
        }
        playlistIOQueue.async {
            do {
                try self.writePlaylistSnapshot(snapshot, to: url)
            } catch {
                self.debugLog("保存播放列表到磁盘失败: \(error)")
                PersistenceLogger.log("保存播放列表失败: \(error)")
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(title: "播放列表保存失败", subtitle: "请检查磁盘权限或空间")
                }
            }
        }
    }
    
    func loadSavedPlaylist(audioPlayer: AudioPlayer? = nil) async {
        guard let saved = loadSavedPlaylistSnapshot() else {
            debugLog("没有找到保存的播放列表")
            return
        }

        let fileManager = FileManager.default
        let validURLs: [URL] = saved.paths.compactMap { path in
            guard fileManager.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        if validURLs.isEmpty {
            debugLog("保存的播放列表中没有任何仍然存在的文件")
            return
        }

        debugLog("轻量恢复保存的播放列表: \(validURLs.count) 个文件")

        // 取消上一轮“恢复后补全元数据”的后台任务（若存在）
        restoredMetadataHydrationTask?.cancel()
        restoredMetadataHydrationTask = nil

        // 标记正在恢复播放列表，避免触发“首次添加自动播放”等逻辑（必须在主线程发布）
        await MainActor.run {
            self.cancelDurationPrefetch()
            self.isRestoringPlaylist = true
        }

        // 恢复时优先使用磁盘元数据缓存（有失效判断），避免整列表先显示“未知艺术家/未知专辑”。
        var restoredFiles: [AudioFile] = []
        restoredFiles.reserveCapacity(validURLs.count)
        var cacheHits = 0
        for url in validURLs {
            let duration = await DurationCache.shared.cachedDurationIfValid(for: url)
            if let cached = await MetadataCache.shared.cachedMetadataIfValid(for: url) {
                restoredFiles.append(AudioFile(url: url, metadata: cached, duration: duration))
                cacheHits += 1
                continue
            }

            // 缓存未命中：使用极轻量的占位元数据（仅根据文件名构建标题）
            let title = url.deletingPathExtension().lastPathComponent
            let metadata = AudioMetadata(
                title: title.isEmpty ? "未知标题" : title,
                artist: "未知艺术家",
                album: "未知专辑",
                year: nil,
                genre: nil,
                artwork: nil
            )
            restoredFiles.append(AudioFile(url: url, metadata: metadata, duration: duration))
        }
        debugLog("恢复播放列表元数据缓存命中: \(cacheHits)/\(validURLs.count)")

        let restoredFilesSnapshot = restoredFiles
        await MainActor.run {
            self.audioFiles = restoredFilesSnapshot
            self.currentIndex = 0
            self.updateFilteredFiles()
            self.resetShuffleQueue()
            self.enqueueDurationPrefetch(for: validURLs)
        }

        // 恢复完成；后续由 AudioPlayer.loadLastPlayedFile 按需定位到具体曲目
        await MainActor.run {
            self.isRestoringPlaylist = false
        }

        // 在后台逐步补全真实元数据（避免重启后整列表都显示“未知艺术家/未知专辑”）。
        restoredMetadataHydrationTask = Task.detached(priority: .utility) { [weak self, weak audioPlayer] in
            guard let self else { return }
            await self.hydrateRestoredMetadata(urls: validURLs, audioPlayer: audioPlayer)
        }
    }

    private func hydrateRestoredMetadata(urls: [URL], audioPlayer: AudioPlayer?) async {
        // 分批并发加载，避免一次性创建过多 task，同时让 UI 更快看到更新
        let batchSize = 8
        var start = 0
        while start < urls.count {
            if Task.isCancelled { return }

            let end = min(start + batchSize, urls.count)
            let batch = Array(urls[start..<end])

            let results: [(URL, AudioMetadata)] = await withTaskGroup(of: (URL, AudioMetadata).self) { group in
                for url in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (url, AudioMetadata(title: "未知标题", artist: "未知艺术家", album: "未知专辑", year: nil, genre: nil, artwork: nil)) }
                        let metadata = await self.loadCachedMetadata(from: url)
                        return (url, metadata)
                    }
                }

                var collected: [(URL, AudioMetadata)] = []
                collected.reserveCapacity(batch.count)
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            if Task.isCancelled { return }

            await MainActor.run { [weak self, weak audioPlayer] in
                guard let self else { return }
                for (url, metadata) in results {
                    let lookupSet = Set(self.pathLookupKeys(url))
                    guard let index = self.audioFiles.firstIndex(where: { !lookupSet.isDisjoint(with: Set(self.pathLookupKeys($0.url))) }) else {
                        continue
                    }
                    let existing = self.audioFiles[index]
                    self.audioFiles[index] = AudioFile(url: existing.url, metadata: metadata, lyricsTimeline: existing.lyricsTimeline, duration: existing.duration)

                    if let ap = audioPlayer, ap.currentFile?.url.path == existing.url.path {
                        ap.currentFile = AudioFile(url: existing.url, metadata: metadata, lyricsTimeline: ap.currentFile?.lyricsTimeline, duration: ap.currentFile?.duration)
                    }
                }
                self.updateFilteredFiles()
            }

            start = end
        }
    }

    private func loadSavedPlaylistSnapshot() -> SavedPlaylist? {
        // 优先从磁盘读取
        if let disk = loadSavedPlaylistFromDisk() {
            return disk
        }
        // 兼容旧版 UserDefaults：读取后迁移到磁盘
        let d = UserDefaults.standard
        if let filePaths = d.stringArray(forKey: "savedPlaylistPaths"), !filePaths.isEmpty {
            let savedIndex = d.integer(forKey: "savedPlaylistIndex")
            let snapshot = SavedPlaylist(paths: filePaths, currentIndex: savedIndex)
            if savePlaylistToDisk(snapshot) {
                d.removeObject(forKey: "savedPlaylistPaths")
                d.removeObject(forKey: "savedPlaylistIndex")
            }
            return snapshot
        }
        return nil
    }

    private func loadSavedPlaylistFromDisk() -> SavedPlaylist? {
        guard let url = playlistFileURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SavedPlaylist.self, from: data)
        } catch {
            debugLog("读取保存的播放列表失败: \(error)，将删除损坏的文件")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func savePlaylistToDisk(_ snapshot: SavedPlaylist) -> Bool {
        guard let url = playlistFileURL() else { return false }
        let isOnIOQueue = DispatchQueue.getSpecific(key: playlistIOQueueKey) != nil
        let write = {
            do {
                try self.writePlaylistSnapshot(snapshot, to: url)
                return true
            } catch {
                self.debugLog("保存播放列表到磁盘失败: \(error)")
                PersistenceLogger.log("保存播放列表失败: \(error)")
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(title: "播放列表保存失败", subtitle: "请检查磁盘权限或空间")
                }
                return false
            }
        }
        if isOnIOQueue {
            return write()
        }
        return playlistIOQueue.sync {
            write()
        }
    }

    private func writePlaylistSnapshot(_ snapshot: SavedPlaylist, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private func playlistFileURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                debugLog("创建应用支持目录失败: \(error)")
                return nil
            }
        }
        return dir.appendingPathComponent(playlistFileName, isDirectory: false)
    }
}

extension Notification.Name {
    static let playlistDidAddFirstFiles = Notification.Name("playlistDidAddFirstFiles")
}

import AVFoundation

// 轻量级并发闸，用于限制异步任务并发数
actor ConcurrencyGate {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterIndex: Int = 0

    init(maxConcurrent: Int) {
        permits = max(1, maxConcurrent)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiterIndex < waiters.count {
            let continuation = waiters[waiterIndex]
            waiterIndex += 1

            // Periodically compact the array to avoid unbounded growth from removed heads.
            if waiterIndex == waiters.count {
                waiters.removeAll(keepingCapacity: true)
                waiterIndex = 0
            } else if waiterIndex > 32 && waiterIndex * 2 > waiters.count {
                waiters.removeFirst(waiterIndex)
                waiterIndex = 0
            }

            continuation.resume()
            return
        }

        permits += 1
    }
}
