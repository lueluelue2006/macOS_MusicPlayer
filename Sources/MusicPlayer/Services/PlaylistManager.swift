import Foundation
import Combine

struct QueueRemovalContext {
    let removedFile: AudioFile
    let originalQueueIndex: Int
    let playbackScope: PlaybackScope
    let playlistPosition: Int?
}

final class PlaylistManager: ObservableObject {
    struct QueuePersistenceFlushResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case durable
            case skippedBeforeRestore
            case protectedReadOnly
            case timedOut
            case failed
        }

        let outcome: Outcome
        let attemptedRevision: UInt64
        let durableRevision: UInt64

        var isDurable: Bool { outcome == .durable }
    }

    enum QueueClearResult: Equatable, Sendable {
        case applied(QueuePersistenceFlushResult)
        case rejected

        var didApply: Bool {
            if case .applied = self { return true }
            return false
        }

        var isDurable: Bool {
            if case .applied(let flush) = self { return flush.isDurable }
            return false
        }
    }

    enum QueueLoadState: Equatable {
        case notStarted
        case loading(generation: UInt64)
        case ready
        case terminating(wasReady: Bool)
    }

    @Published var audioFiles: [AudioFile] = []
    @Published var currentIndex: Int = 0 {
        didSet {
            if !isApplyingPersistedCurrentIndex {
                retainedSavedCurrentFullOrderIndex = nil
            }
        }
    }
    @Published var filteredFiles: [AudioFile] = []
    @Published var searchText: String = ""
    /// Which collection playback controls operate on (queue vs a user playlist).
    @Published private(set) var playbackScope: PlaybackScope = .queue
    /// Changes whenever the ordered tracks behind `playbackScope` change without
    /// necessarily changing the scope value itself.
    @Published private(set) var playbackScopeRevision: UInt64 = 0
    @Published var scanSubfolders: Bool = true { // 默认开启子文件夹扫描
        didSet { saveScanSubfoldersPreference() }
    }
    private let userScanSubfoldersKey = "userScanSubfoldersEnabled"
    
    private var shuffleQueue: [Int] = []
    private var shuffleIndex = 0

    // Queue path-key -> index cache (accelerates playlist-scope lookup in large libraries).
    private var queueIndexByPathKey: [String: Int] = [:]
    private var isQueueIndexCacheDirty: Bool = true

    // Playlist-scope playback (order defined by user playlist, not by queue order).
    private var playbackPlaylistTrackKeys: [String] = []
    private var playbackPlaylistPositionByKey: [String: Int] = [:]
    private var playbackPlaylistPathByOccurrenceKey: [String: String] = [:]
    private var currentPlaybackPlaylistOccurrenceKey: String?
    private var playlistShuffleQueueKeys: [String] = []
    private var playlistShuffleIndex: Int = 0
    
    @Published var isRestoringPlaylist = false  // 标记是否正在恢复播放列表
    @Published private(set) var isInitialRestorePending = false
    @Published private(set) var queueLoadState: QueueLoadState
    private var didPerformInitialRestore: Bool = false
    private var queueLoadGeneration: UInt64 = 0
    private var initialRestoreTask: Task<Void, Never>?
    private var restoredMetadataHydrationTask: Task<Void, Never>?
    private var restoredMetadataHydrationGeneration: UInt64 = 0
    
    // MARK: - 添加/扫描进度（可取消）
    @Published private(set) var isAddingFiles: Bool = false
    @Published private(set) var addFilesPhase: String = ""
    @Published private(set) var addFilesDetail: String = ""
    @Published private(set) var addFilesProgressCurrent: Int = 0
    @Published private(set) var addFilesProgressTotal: Int = 0

    private var addFilesTask: Task<Void, Never>?
    private var pendingAddURLs: [URL] = []
    private var isTerminating: Bool = false
    private var terminationStartWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - 不可播放标记（按路径）
    @Published private(set) var unplayableReasons: [String: String] = [:]

    private struct SavedPlaylist: Codable {
        struct TrackRecord: Codable {
            let path: String
            let signature: FileSignature?
        }

        struct WeightRekeyRecord: Codable, Equatable {
            let oldPath: String
            let newPath: String
        }

        let version: Int?
        let tracks: [TrackRecord]?
        let paths: [String]
        let currentIndex: Int
        let pendingWeightRekeys: [WeightRekeyRecord]?

        init(
            version: Int?,
            tracks: [TrackRecord]?,
            paths: [String],
            currentIndex: Int,
            pendingWeightRekeys: [WeightRekeyRecord]? = nil
        ) {
            self.version = version
            self.tracks = tracks
            self.paths = paths
            self.currentIndex = currentIndex
            self.pendingWeightRekeys = pendingWeightRekeys
        }
    }

    private struct PlaylistVersionProbe: Codable {
        let version: Int?
    }
    private let playlistFileName = "playlist.json"
    private let playlistFileURLOverride: URL?
    private let playlistFileWriter: (Data, URL) throws -> Void
    private let isRunningRegressionTests: Bool
    private let playlistIOQueue = DispatchQueue(label: "playlist.persistence", qos: .utility)
    private let playlistIOQueueKey = DispatchSpecificKey<Void>()
    private let playlistSaveStateLock = NSLock()
    private var playlistSaveRevision: UInt64 = 0
    private var playlistSaveWorkItem: DispatchWorkItem?
    private var pendingPlaylistWrite: (revision: UInt64, snapshot: SavedPlaylist)?
    private var isPlaylistWriteDrainScheduled = false
    private var playlistDurableRevision: UInt64 = 0
    private var playlistLastFailedRevision: UInt64?
    private var playlistRetryAttempt = 0
    private var playlistRetryWorkItem: DispatchWorkItem?
    /// Protected by `playlistSaveStateLock`. Unlike the published lifecycle
    /// value, this flag is safe to consult from persistence queue callbacks.
    private var canBuildPlaylistPersistenceSnapshot: Bool
    private let playlistSaveDebounceInterval: TimeInterval
    private let playlistFormatVersion = 2
    private let maximumPlaylistStoreBytes = 16 * 1_024 * 1_024
    private let maximumPlaylistEntries = 100_000
    private let maximumPlaylistPathBytes = 16 * 1_024
    private let maximumPlaylistAggregatePathBytes = 12 * 1_024 * 1_024
    private let maximumPendingWeightRekeys = 4_096
    /// Keep task allocation bounded as well as AVFoundation I/O. A gate inside
    /// each task is insufficient here because a large queue could otherwise
    /// create tens of thousands of suspended Swift tasks at once.
    private static let maximumConcurrentMetadataRefreshTasks = 4
    private var isPlaylistPersistenceReadOnly = false
    private var fullOrderIndexForAudioFile: [Int?] = []
    private var retainedMissingWithOriginalIndex: [(originalIndex: Int, record: SavedPlaylist.TrackRecord)] = []
    private var retainedSavedCurrentFullOrderIndex: Int?
    private var isApplyingPersistedCurrentIndex = false
    private var pendingQueueWeightRekeys: [SavedPlaylist.WeightRekeyRecord] = []
    private var loadedSignatureByPath: [String: FileSignature] = [:]
    private var didNotifyProtectedQueueMutation = false
    private let metadataGate = ConcurrencyGate(maxConcurrent: 4) // 限制元数据加载并发
    private let durationGate = ConcurrencyGate(maxConcurrent: 2) // 限制时长计算并发（更轻量但也需要控速）
    private let signatureCaptureService: SignatureCaptureService
    private let freshMetadataLoaderOverride: ((URL) async -> AudioMetadata)?

    // MARK: - Playback scope persistence
    private let appPreferencesStore: AppPreferencesStore
    private let playbackWeights: PlaybackWeights
    private let playbackStateRekeyHandler: ((URL, URL) -> PlaybackStateStore.RekeyResult)?
    private var didNotifyProtectedScopePreference = false

    @MainActor private var durationPrefetchTask: Task<Void, Never>?
    @MainActor private var pendingDurationURLs: [URL] = []
    @MainActor private var pendingDurationURLKeys: Set<String> = []
    @MainActor private var pendingDurationIndex: Int = 0

    init(
        playlistFileURLOverride: URL? = nil,
        disablePersistence: Bool = false,
        persistenceDebounceInterval: TimeInterval = 0.4,
        signatureCaptureService: SignatureCaptureService? = nil,
        initialQueueLoadState: QueueLoadState? = nil,
        appPreferencesStore: AppPreferencesStore = .shared,
        playbackWeights: PlaybackWeights = .shared,
        playbackStateRekeyHandler: ((URL, URL) -> PlaybackStateStore.RekeyResult)? = nil,
        freshMetadataLoaderOverride: ((URL) async -> AudioMetadata)? = nil,
        playlistFileWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.playlistFileURLOverride = playlistFileURLOverride
        self.playlistFileWriter = playlistFileWriter ?? { data, url in
            try DerivedCacheFileIO.atomicWrite(data, to: url)
        }
        self.playlistSaveDebounceInterval = max(0, persistenceDebounceInterval)
        let isRunningRegressionTests = disablePersistence
            || ProcessInfo.processInfo.environment["MUSICPLAYER_RUN_REGRESSION_TESTS"] == "1"
        self.isRunningRegressionTests = isRunningRegressionTests
        let defaultLoadState: QueueLoadState = (playlistFileURLOverride != nil || isRunningRegressionTests)
            ? .ready
            : .notStarted
        let queueLoadState = initialQueueLoadState ?? defaultLoadState
        self.queueLoadState = queueLoadState
        switch queueLoadState {
        case .ready, .terminating(wasReady: true):
            self.canBuildPlaylistPersistenceSnapshot = true
        case .notStarted, .loading, .terminating(wasReady: false):
            self.canBuildPlaylistPersistenceSnapshot = false
        }
        self.signatureCaptureService = signatureCaptureService ?? SignatureCaptureService()
        self.freshMetadataLoaderOverride = freshMetadataLoaderOverride
        self.appPreferencesStore = appPreferencesStore
        self.playbackWeights = playbackWeights
        self.playbackStateRekeyHandler = playbackStateRekeyHandler
        playlistIOQueue.setSpecific(key: playlistIOQueueKey, value: ())
        if !isRunningRegressionTests {
            loadScanSubfoldersPreference()
        }

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
        playbackPlaylistPathByOccurrenceKey.removeAll(keepingCapacity: true)
        currentPlaybackPlaylistOccurrenceKey = nil
        resetPlaylistShuffleQueue()
        playbackScopeRevision &+= 1
        persistPlaybackScope(.queue)
    }

    /// Switch playback controls to operate on a specific user playlist (in its playlist order).
    /// - Note: `trackURLsInOrder` should contain only playable tracks in the playlist's order.
    func setPlaybackScopePlaylist(
        _ playlistID: UserPlaylist.ID,
        trackURLsInOrder: [URL],
        trackIDsInOrder: [String]? = nil,
        selectedTrackID: String? = nil
    ) {
        playbackScope = .playlist(playlistID)
        let previousOccurrence = currentPlaybackPlaylistOccurrenceKey
        let occurrences = makePlaylistOccurrences(
            trackURLsInOrder: trackURLsInOrder,
            trackIDsInOrder: trackIDsInOrder
        )
        playbackPlaylistTrackKeys = occurrences.map(\.key)
        playbackPlaylistPathByOccurrenceKey = Dictionary(
            uniqueKeysWithValues: occurrences.map { ($0.key, $0.pathKey) }
        )
        rebuildPlaybackPlaylistPositions()
        if let selectedTrackID,
           let selected = occurrences.first(where: { $0.trackID == selectedTrackID }) {
            currentPlaybackPlaylistOccurrenceKey = selected.key
        } else if let previousOccurrence,
                  playbackPlaylistPositionByKey[previousOccurrence] != nil {
            currentPlaybackPlaylistOccurrenceKey = previousOccurrence
        } else {
            currentPlaybackPlaylistOccurrenceKey = occurrenceKeyMatchingCurrentQueuePath()
        }
        resetPlaylistShuffleQueue()
        playbackScopeRevision &+= 1
        persistPlaybackScope(.playlist(playlistID))
    }

    /// Update the active playlist scope track list (e.g. after adding/removing tracks),
    /// keeping the existing shuffle queue as stable as possible.
    func updatePlaybackScopePlaylistTracksIfActive(
        _ playlistID: UserPlaylist.ID,
        trackURLsInOrder: [URL],
        trackIDsInOrder: [String]? = nil
    ) {
        guard playbackScope == .playlist(playlistID) else { return }
        guard !trackURLsInOrder.isEmpty else {
            setPlaybackScopeQueue()
            return
        }

        let oldKeys = playbackPlaylistTrackKeys
        let occurrences = makePlaylistOccurrences(
            trackURLsInOrder: trackURLsInOrder,
            trackIDsInOrder: trackIDsInOrder
        )
        let newKeys = occurrences.map(\.key)
        let newPathMap = Dictionary(
            uniqueKeysWithValues: occurrences.map { ($0.key, $0.pathKey) }
        )
        guard oldKeys != newKeys || playbackPlaylistPathByOccurrenceKey != newPathMap else {
            return
        }

        playbackPlaylistTrackKeys = newKeys
        playbackPlaylistPathByOccurrenceKey = newPathMap
        rebuildPlaybackPlaylistPositions()
        if let current = currentPlaybackPlaylistOccurrenceKey,
           playbackPlaylistPositionByKey[current] == nil {
            currentPlaybackPlaylistOccurrenceKey = occurrenceKeyMatchingCurrentQueuePath()
        }
        updatePlaylistShuffleQueue(oldKeys: oldKeys, newKeys: newKeys)
        playbackScopeRevision &+= 1
    }

    private func makePlaylistOccurrences(
        trackURLsInOrder: [URL],
        trackIDsInOrder: [String]?
    ) -> [(key: String, pathKey: String, trackID: String?)] {
        var usedKeys = Set<String>()
        return trackURLsInOrder.enumerated().map { index, url in
            let trackID = trackIDsInOrder?.indices.contains(index) == true
                ? trackIDsInOrder?[index]
                : nil
            let base = trackID.map { "id:\($0)" }
                ?? "occurrence:\(index):\(pathKey(url))"
            var key = base
            var collision = 1
            while !usedKeys.insert(key).inserted {
                key = "\(base)#\(collision)"
                collision += 1
            }
            return (key, pathKey(url), trackID)
        }
    }

    private func pathKeyForPlaylistOccurrence(_ occurrenceKey: String) -> String? {
        playbackPlaylistPathByOccurrenceKey[occurrenceKey]
    }

    private func occurrenceKeyMatchingCurrentQueuePath() -> String? {
        guard let currentPathKey = currentPathKeyInQueue() else { return nil }
        return playbackPlaylistTrackKeys.first {
            pathKeyForPlaylistOccurrence($0) == currentPathKey
        }
    }

    private func persistPlaybackScope(_ scope: PlaybackScope) {
        guard !isRunningRegressionTests else { return }
        guard appPreferencesStore.persistenceState == .writable else {
            if !didNotifyProtectedScopePreference {
                didNotifyProtectedScopePreference = true
                PersistenceLogger.notifyUser(
                    title: "播放范围偏好处于只读保护模式",
                    subtitle: "当前会话可用，重启后保留原设置"
                )
            }
            return
        }
        let preferenceScope: AppPreferencesStore.PlaybackScope
        switch scope {
        case .queue:
            preferenceScope = .queue
        case .playlist(let id):
            preferenceScope = .playlist(id)
        }
        _ = appPreferencesStore.update { $0.playbackScope = preferenceScope }
        _ = appPreferencesStore.persist()
    }

    /// Restore last used playback scope (queue vs a specific user playlist).
    ///
    /// - Important: Call this after the queue (`audioFiles`) has been restored, otherwise playlist-scope
    ///   playback won't be able to map tracks to queue indices.
    func restorePlaybackScopeIfNeeded(playlistsStore: PlaylistsStore) async {
        switch appPreferencesStore.load().playbackScope {
        case .queue:
            await MainActor.run { [weak self] in
                self?.setPlaybackScopeQueue()
            }

        case .playlist(let playlistID):
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
            let playableTracks = playlist.tracks.filter {
                fm.fileExists(atPath: $0.path)
            }
            let urlsInOrder = playableTracks.map { URL(fileURLWithPath: $0.path) }

            if urlsInOrder.isEmpty {
                await MainActor.run { [weak self] in
                    self?.setPlaybackScopeQueue()
                }
                return
            }

            // Extract signatures from playlist tracks
            var signatures: [String: FileSignature] = [:]
            for track in playlist.tracks {
                if let sig = track.signature {
                    signatures[track.path] = sig
                }
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

                let snapshot = FileValidationSnapshot.load(for: url)
                let duration = await DurationCache.shared.cachedDurationIfValid(for: url, snapshot: snapshot)
                if let cached = await MetadataCache.shared.cachedMetadataIfValid(for: url, snapshot: snapshot) {
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
            let signaturesSnapshot = signatures
            if !filesToAppend.isEmpty {
                await MainActor.run { [weak self] in
                    _ = self?.ensureInQueue(filesToAppend, focusURL: nil, signatures: signaturesSnapshot)
                }
            }

            await MainActor.run { [weak self] in
                self?.setPlaybackScopePlaylist(
                    playlistID,
                    trackURLsInOrder: urlsInOrder,
                    trackIDsInOrder: playableTracks.map { $0.id.uuidString }
                )
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
            for occurrenceKey in playbackPlaylistTrackKeys {
                guard let pathKey = pathKeyForPlaylistOccurrence(occurrenceKey),
                      let idx = indexInQueue(forPathKey: pathKey) else { continue }
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
                guard let pathKey = pathKeyForPlaylistOccurrence(key) else { continue }
                let weight = playbackWeights.multiplier(
                    forKey: pathKey,
                    scope: .playlist(playlistID)
                )
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
        guard !isTerminating else { return }

        queueLoadGeneration &+= 1
        let generation = queueLoadGeneration
        transitionQueueLoadState(.loading(generation: generation))
        isInitialRestorePending = true

        initialRestoreTask?.cancel()
        initialRestoreTask = Task.detached(priority: .utility) { [weak self, weak audioPlayer] in
            guard let self, let audioPlayer else { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                await self.finishCancelledInitialRestore(generation: generation)
                return
            }

            await playlistsStore.ensureLoaded()
            guard !Task.isCancelled else {
                await self.finishCancelledInitialRestore(generation: generation)
                return
            }

            await self.loadSavedPlaylist(audioPlayer: audioPlayer)
            guard !Task.isCancelled else {
                await self.finishCancelledInitialRestore(generation: generation)
                return
            }

            let accepted = await MainActor.run {
                self.completeInitialQueueLoad(generation: generation)
            }
            guard accepted else { return }

            await self.restorePlaybackScopeIfNeeded(playlistsStore: playlistsStore)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !self.isTerminating, self.queueLoadGeneration == generation else { return }
                // A Finder/Dock open suppresses only last-playback restoration.
                // The persisted queue must still load so a temporary session can
                // never replace it with an empty in-memory placeholder.
                let skipPlaybackRestore = audioPlayer.consumeSkipRestoreThisLaunch()
                if !skipPlaybackRestore, audioPlayer.currentFile == nil {
                    audioPlayer.loadLastPlayedFile()
                }
                self.isInitialRestorePending = false
                self.initialRestoreTask = nil
            }
        }
    }

    @MainActor
    @discardableResult
    func completeInitialQueueLoad(generation: UInt64) -> Bool {
        guard !isTerminating,
              queueLoadState == .loading(generation: generation) else {
            return false
        }
        transitionQueueLoadState(.ready)
        guard isPlaylistPersistenceWritable() else {
            pendingAddURLs.removeAll()
            addFilesTask?.cancel()
            resetAddFilesProgress()
            return true
        }
        replayPendingQueueWeightRekeysIfPossible()
        startNextAddBatchIfNeeded()
        return true
    }

    private func finishCancelledInitialRestore(generation: UInt64) async {
        await MainActor.run { [weak self] in
            guard let self,
                  self.queueLoadState == .loading(generation: generation) else { return }
            self.isInitialRestorePending = false
            self.initialRestoreTask = nil
            self.transitionQueueLoadState(.notStarted)
        }
    }

    @MainActor
    private func transitionQueueLoadState(_ newState: QueueLoadState) {
        let mayBuildSnapshot: Bool
        switch newState {
        case .ready, .terminating(wasReady: true):
            mayBuildSnapshot = true
        case .notStarted, .loading, .terminating(wasReady: false):
            mayBuildSnapshot = false
        }

        playlistSaveStateLock.lock()
        canBuildPlaylistPersistenceSnapshot = mayBuildSnapshot
        playlistSaveStateLock.unlock()
        queueLoadState = newState
    }

    // MARK: - Add files queue (cancellable)
    @MainActor
    func enqueueAddFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isTerminating else { return }
        guard isQueueContentMutationAllowed() else { return }
        let availableSlots = max(0, maximumPlaylistEntries - pendingAddURLs.count)
        guard availableSlots > 0 else {
            notifyQueueCapacityRejected()
            return
        }
        pendingAddURLs.append(contentsOf: urls.prefix(availableSlots))
        if urls.count > availableSlots {
            notifyQueueCapacityRejected()
        }
        startNextAddBatchIfNeeded()
    }

    @MainActor
    func cancelAddFiles() {
        let taskToCancel = addFilesTask
        pendingAddURLs.removeAll()
        resetAddFilesProgress()
        taskToCancel?.cancel()
    }

    /// Stops accepting import work without waiting for filesystem operations.
    /// AppKit termination must stay synchronous: waiting from
    /// `applicationShouldTerminate` can deadlock its nested run loop.
    @MainActor
    func prepareForImmediateTermination() {
        let wasReady: Bool
        switch queueLoadState {
        case .ready, .terminating(wasReady: true):
            wasReady = true
        case .notStarted, .loading, .terminating(wasReady: false):
            wasReady = false
        }
        isTerminating = true
        transitionQueueLoadState(.terminating(wasReady: wasReady))
        queueLoadGeneration &+= 1
        initialRestoreTask?.cancel()
        initialRestoreTask = nil
        restoredMetadataHydrationTask?.cancel()
        restoredMetadataHydrationTask = nil
        cancelDurationPrefetch()
        pendingAddURLs.removeAll()
        addFilesTask?.cancel()
        isInitialRestorePending = false
        resetAddFilesProgress()

        let startWaiters = terminationStartWaiters
        terminationStartWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }
    }

    @MainActor
    private func startNextAddBatchIfNeeded() {
        guard addFilesTask == nil else { return }
        guard !pendingAddURLs.isEmpty else { return }
        guard !isTerminating else { return }
        guard queueLoadState == .ready else { return }

        let batch = pendingAddURLs
        pendingAddURLs.removeAll()
        isAddingFiles = true

        let task = Task { [weak self] in
            guard let self else { return }
            await self.addFilesBatch(batch)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.addFilesTask = nil

                if self.isTerminating {
                    self.resetAddFilesProgress()
                    return
                }

                if !self.pendingAddURLs.isEmpty {
                    self.startNextAddBatchIfNeeded()
                } else {
                    self.resetAddFilesProgress()
                }
            }
        }
        addFilesTask = task
    }

    @MainActor
    func drainAndFlushForTermination() async {
        prepareForImmediateTermination()
        let taskToWait = addFilesTask
        await taskToWait?.value
        flushPlaylistPersistence()
    }

    @MainActor
    func waitUntilTerminationStartedForTesting() async {
        guard !isTerminating else { return }
        await withCheckedContinuation { continuation in
            terminationStartWaiters.append(continuation)
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

    func fileRelocationCandidatesSnapshot() -> [FileRelocationCandidate] {
        var seen = Set<String>()
        return audioFiles.compactMap { file in
            let key = pathKey(file.url)
            guard seen.insert(key).inserted,
                  let signature = loadedSignatureByPath[file.url.path] else { return nil }
            return FileRelocationCandidate(url: file.url, signature: signature)
        }
    }

    @MainActor
    private func appendPendingQueueWeightRekeys(
        _ records: [SavedPlaylist.WeightRekeyRecord]
    ) {
        pendingQueueWeightRekeys = mergedPendingQueueWeightRekeys(records)
    }

    private func mergedPendingQueueWeightRekeys(
        _ additionalRecords: [SavedPlaylist.WeightRekeyRecord]
    ) -> [SavedPlaylist.WeightRekeyRecord] {
        var merged = pendingQueueWeightRekeys
        var existing = Set(
            merged.map {
                "\(PathKey.canonical(path: $0.oldPath))\u{0}\(PathKey.canonical(path: $0.newPath))"
            }
        )
        for record in additionalRecords {
            let key = "\(PathKey.canonical(path: record.oldPath))\u{0}\(PathKey.canonical(path: record.newPath))"
            guard existing.insert(key).inserted else { continue }
            merged.append(record)
        }
        return merged
    }

    @MainActor
    private func queueStateFitsPersistenceBounds(
        addingFiles: [(file: AudioFile, signature: FileSignature?)] = [],
        removingMissingIndices: Set<Int> = [],
        addingRekeys: [SavedPlaylist.WeightRekeyRecord] = []
    ) -> Bool {
        let retainedMissingCount = retainedMissingWithOriginalIndex.indices.reduce(into: 0) {
            if !removingMissingIndices.contains($1) { $0 += 1 }
        }
        guard audioFiles.count <= maximumPlaylistEntries - retainedMissingCount,
              audioFiles.count + retainedMissingCount <= maximumPlaylistEntries - addingFiles.count else {
            return false
        }

        var aggregateBytes = 0
        func consumeString(_ value: String, requiresAbsolutePath: Bool) -> Bool {
            let bytes = value.utf8.count
            guard bytes > 0,
                  bytes <= maximumPlaylistPathBytes,
                  !value.utf8.contains(0),
                  !requiresAbsolutePath || value.hasPrefix("/"),
                  aggregateBytes <= maximumPlaylistAggregatePathBytes - bytes else {
                return false
            }
            aggregateBytes += bytes
            return true
        }
        func consumeSignature(_ signature: FileSignature?) -> Bool {
            guard let signature else { return true }
            guard signature.size >= 0,
                  consumeString(signature.pathKey, requiresAbsolutePath: false) else { return false }
            if let identifier = signature.fileResourceIdentifier,
               !consumeString(identifier, requiresAbsolutePath: false) { return false }
            if let identifier = signature.volumeIdentifier,
               !consumeString(identifier, requiresAbsolutePath: false) { return false }
            return true
        }

        for file in audioFiles {
            guard consumeString(file.url.path, requiresAbsolutePath: true),
                  consumeSignature(loadedSignatureByPath[file.url.path]) else { return false }
        }
        for (index, missing) in retainedMissingWithOriginalIndex.enumerated()
        where !removingMissingIndices.contains(index) {
            guard consumeString(missing.record.path, requiresAbsolutePath: true),
                  consumeSignature(missing.record.signature) else { return false }
        }
        for addition in addingFiles {
            guard consumeString(addition.file.url.path, requiresAbsolutePath: true),
                  consumeSignature(addition.signature) else { return false }
        }

        let mergedRekeys = mergedPendingQueueWeightRekeys(addingRekeys)
        guard mergedRekeys.count <= maximumPendingWeightRekeys else { return false }
        for rekey in mergedRekeys {
            guard consumeString(rekey.oldPath, requiresAbsolutePath: true),
                  consumeString(rekey.newPath, requiresAbsolutePath: true) else { return false }
        }
        return true
    }

    private func notifyQueueCapacityRejected() {
        PersistenceLogger.log("队列修改超过安全容量边界，已在修改内存前拒绝")
        DispatchQueue.main.async {
            PersistenceLogger.notifyUser(
                title: "无法添加更多歌曲",
                subtitle: "队列已达到安全容量上限，请先移除部分歌曲"
            )
        }
    }

    /// Replays a queue relocation as an idempotent mini-transaction:
    /// queue snapshot with intent -> durable weights -> queue snapshot without intent.
    @MainActor
    private func replayPendingQueueWeightRekeysIfPossible() {
        guard !pendingQueueWeightRekeys.isEmpty,
              isPlaylistPersistenceWritable() else { return }

        let records = pendingQueueWeightRekeys
        let changes = records.map {
            PlaybackWeights.TrackRekey(
                oldURL: URL(fileURLWithPath: $0.oldPath),
                newURL: URL(fileURLWithPath: $0.newPath)
            )
        }
        let mutation = playbackWeights.rekeyTracks(changes, scope: .queue)
        if case .rejectedReadOnly(let reason) = mutation {
            PersistenceLogger.log("队列移动后的权重迁移被拒绝：\(reason.diagnosticMessage)")
            return
        }
        guard playbackWeights.flushPersistence().isDurable else {
            PersistenceLogger.log("队列移动后的权重迁移尚未持久化，保留可重放 intent")
            return
        }

        for record in records {
            let result = playbackStateRekeyHandler?(
                URL(fileURLWithPath: record.oldPath),
                URL(fileURLWithPath: record.newPath)
            ) ?? .unchanged
            guard result.permitsIntentAcknowledgement else {
                PersistenceLogger.log("队列移动后的播放状态迁移尚未持久化，保留可重放 intent")
                return
            }
        }
        pendingQueueWeightRekeys.removeAll()
        let acknowledgement = flushPlaylistPersistence()
        guard acknowledgement.isDurable else {
            appendPendingQueueWeightRekeys(records)
            PersistenceLogger.log("队列移动 intent 确认写入失败，将在下次持久化时重放")
            return
        }
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

    @MainActor
    func waitForAddFilesCompletionForTesting() async {
        while let task = addFilesTask {
            await task.value
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

        let scanResult = RecursiveImportScanner.scan(
            urls: urls,
            recursive: shouldScanSubfolders,
            isCancelled: { Task.isCancelled }
        )

        if scanResult.wasCancelled || Task.isCancelled { return }

        let fileURLs = scanResult.files

        // Log actionable skipped items for debugging
        for skipped in scanResult.skipped {
            switch skipped.reason {
            case .unreadable, .obviousNonAudio:
                debugLog("Skipped: \(skipped.path) (\(skipped.reason))")
            case .symbolicLink, .duplicate, .hidden, .package:
                break // Expected, no action needed
            }
        }

        // Build scan completion summary
        var summaryParts: [String] = ["发现 \(fileURLs.count) 首"]
        if scanResult.totalSkippedItemCount > 0 {
            summaryParts.append("跳过 \(scanResult.totalSkippedItemCount) 项")
        }
        if scanResult.unsupportedFormatCount > 0 {
            summaryParts.append("不支持格式 \(scanResult.unsupportedFormatCount) 个")
        }
        if scanResult.wasTruncated {
            summaryParts.append("已达到安全扫描上限")
        }
        let scanSummary = summaryParts.joined(separator: "，")

        if fileURLs.isEmpty {
            await updateUI(phase: "未找到可导入的音频文件", detail: scanSummary, current: 0, total: 0, force: true)
            return
        }

        await updateUI(phase: "扫描完成", detail: scanSummary, current: fileURLs.count, total: fileURLs.count, force: true)

        await updateUI(phase: "读取元数据…", detail: "", current: 0, total: fileURLs.count, force: true)

        // Deduplicate input URLs by canonical and legacy path before worker pool
        let dedupedFileURLs: [URL] = {
            var seen = Set<String>()
            var seenLegacy = Set<String>()
            var result: [URL] = []
            for url in fileURLs {
                let key = PathKey.canonical(for: url)
                let legacy = PathKey.legacy(for: url)
                if seen.contains(key) || seenLegacy.contains(legacy) { continue }
                seen.insert(key)
                seenLegacy.insert(legacy)
                result.append(url)
            }
            return result
        }()

        let progress = MetadataProgressTracker()
        let results = await BoundedWorkerPool.map(
            items: dedupedFileURLs,
            maxConcurrent: 4
        ) { [weak self] url -> (AudioFile, FileSignature?)? in
            guard let self else { return nil }
            if Task.isCancelled { return nil }
            let metadata = await self.loadCachedMetadata(from: url)
            if Task.isCancelled { return nil }
            let duration = await DurationCache.shared.cachedDurationIfValid(for: url)
            if Task.isCancelled { return nil }

            // Capture file signature (sequentially in worker)
            let signature = await self.signatureCaptureService.captureSignature(for: url)

            let audioFile = AudioFile(url: url, metadata: metadata, duration: duration)

            if let snapshot = await progress.recordCompleted(url: url, total: dedupedFileURLs.count) {
                if Task.isCancelled { return nil }
                await MainActor.run {
                    self.isAddingFiles = true
                    self.addFilesPhase = "读取元数据…"
                    self.addFilesDetail = snapshot.detail
                    self.addFilesProgressCurrent = snapshot.current
                    self.addFilesProgressTotal = snapshot.total
                }
            }

            return (audioFile, signature)
        }

        let built: [(AudioFile, FileSignature?)] = results.compactMap { $0 }

        if Task.isCancelled { return }

        await MainActor.run {
            // Re-check cancellation after async work
            guard !Task.isCancelled,
                  !self.isTerminating,
                  self.queueLoadState == .ready,
                  self.isQueueContentMutationAllowed() else { return }

            let wasEmpty = self.audioFiles.isEmpty
            let oldCount = self.audioFiles.count
            let selectedFileID = self.audioFiles.indices.contains(self.currentIndex)
                ? self.audioFiles[self.currentIndex].id
                : nil

            // Consume persisted signatures when an imported file is the unique
            // identity match for a previously missing queue item. A candidate
            // shared by multiple missing records is left unresolved.
            var uniqueCandidates: [(file: AudioFile, signature: FileSignature, key: String)] = []
            var candidateKeys = Set<String>()
            for (file, signature) in built {
                guard let signature else { continue }
                let key = self.pathKey(file.url)
                guard candidateKeys.insert(key).inserted else { continue }
                uniqueCandidates.append((file, signature, key))
            }
            var candidateIndicesByIdentity: [FileSignatureMatcher.IdentityKey: [Int]] = [:]
            for (candidateIndex, candidate) in uniqueCandidates.enumerated() {
                guard let identity = FileSignatureMatcher.identityKey(for: candidate.signature) else {
                    continue
                }
                candidateIndicesByIdentity[identity, default: []].append(candidateIndex)
            }
            var proposedMatches: [Int: Int] = [:]
            var candidateUseCount: [Int: Int] = [:]
            for (missingIndex, missing) in self.retainedMissingWithOriginalIndex.enumerated() {
                guard let originalSignature = missing.record.signature,
                      let identity = FileSignatureMatcher.identityKey(for: originalSignature),
                      let matches = candidateIndicesByIdentity[identity],
                      matches.count == 1,
                      let candidateIndex = matches.first else { continue }
                proposedMatches[missingIndex] = candidateIndex
                candidateUseCount[candidateIndex, default: 0] += 1
            }

            var consumedMissingIndices = Set<Int>()
            var consumedCandidateKeys = Set<String>()
            var queueWeightRekeys: [SavedPlaylist.WeightRekeyRecord] = []
            var relocatedAdditions: [(
                file: AudioFile,
                signature: FileSignature,
                originalIndex: Int,
                oldPath: String
            )] = []
            let existingKeys = Set(self.audioFiles.map { self.pathKey($0.url) })
            for (missingIndex, candidateIndex) in proposedMatches.sorted(by: {
                self.retainedMissingWithOriginalIndex[$0.key].originalIndex
                    < self.retainedMissingWithOriginalIndex[$1.key].originalIndex
            }) {
                guard candidateUseCount[candidateIndex] == 1 else { continue }
                let missing = self.retainedMissingWithOriginalIndex[missingIndex]
                let candidate = uniqueCandidates[candidateIndex]
                // A queue is occurrence-based. Reusing an existing path here
                // would collapse a distinct historical slot into another item.
                guard !existingKeys.contains(candidate.key) else { continue }
                relocatedAdditions.append((
                    file: candidate.file,
                    signature: candidate.signature,
                    originalIndex: missing.originalIndex,
                    oldPath: missing.record.path
                ))
                consumedMissingIndices.insert(missingIndex)
                consumedCandidateKeys.insert(candidate.key)
                let oldURL = URL(fileURLWithPath: missing.record.path)
                if self.pathKey(oldURL) != candidate.key {
                    queueWeightRekeys.append(
                            .init(oldPath: oldURL.path, newPath: candidate.file.url.path)
                    )
                }
            }

            // 与现有列表去重：若重复路径已存在，保留已有（更早）的条目，丢弃新增重复
            var existing = existingKeys
            var existingLegacy = Set(self.audioFiles.map { PathKey.legacy(for: $0.url) })
            for relocated in relocatedAdditions {
                existing.insert(self.pathKey(relocated.file.url))
                existingLegacy.insert(PathKey.legacy(for: relocated.file.url))
            }
            var toAppend: [(file: AudioFile, signature: FileSignature?)] = []
            for (f, sig) in built {
                let key = self.pathKey(f.url)
                let legacy = PathKey.legacy(for: f.url)
                if consumedCandidateKeys.contains(key) { continue }
                if existing.contains(key) || existingLegacy.contains(legacy) { continue }
                existing.insert(key)
                existingLegacy.insert(legacy)
                toAppend.append((f, sig))
            }

            let allAdditions = relocatedAdditions.map {
                (file: $0.file, signature: Optional($0.signature))
            } + toAppend
            guard self.queueStateFitsPersistenceBounds(
                addingFiles: allAdditions,
                removingMissingIndices: consumedMissingIndices,
                addingRekeys: queueWeightRekeys
            ) else {
                self.notifyQueueCapacityRejected()
                return
            }

            if !consumedMissingIndices.isEmpty {
                self.retainedMissingWithOriginalIndex = self.retainedMissingWithOriginalIndex
                    .enumerated()
                    .filter { !consumedMissingIndices.contains($0.offset) }
                    .map(\.element)
            }

            if !relocatedAdditions.isEmpty {
                struct OrderedRuntimeEntry {
                    let file: AudioFile
                    let originalIndex: Int?
                    let ordinal: Int
                }
                while self.fullOrderIndexForAudioFile.count < self.audioFiles.count {
                    self.fullOrderIndexForAudioFile.append(nil)
                }
                var ordered = self.audioFiles.enumerated().map { runtimeIndex, file in
                    OrderedRuntimeEntry(
                        file: file,
                        originalIndex: self.fullOrderIndexForAudioFile[runtimeIndex],
                        ordinal: runtimeIndex
                    )
                }
                ordered.append(contentsOf: relocatedAdditions.enumerated().map { offset, item in
                    OrderedRuntimeEntry(
                        file: item.file,
                        originalIndex: item.originalIndex,
                        ordinal: oldCount + offset
                    )
                })
                ordered.sort { lhs, rhs in
                    switch (lhs.originalIndex, rhs.originalIndex) {
                    case let (left?, right?):
                        return left == right ? lhs.ordinal < rhs.ordinal : left < right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.ordinal < rhs.ordinal
                    }
                }
                self.audioFiles = ordered.map(\.file)
                self.fullOrderIndexForAudioFile = ordered.map(\.originalIndex)

                if let savedCurrent = self.retainedSavedCurrentFullOrderIndex,
                   let restoredIndex = self.fullOrderIndexForAudioFile.firstIndex(where: {
                       $0 == savedCurrent
                   }) {
                    self.isApplyingPersistedCurrentIndex = true
                    self.currentIndex = restoredIndex
                    self.isApplyingPersistedCurrentIndex = false
                    self.retainedSavedCurrentFullOrderIndex = nil
                } else if let selectedFileID,
                          let restoredIndex = self.audioFiles.firstIndex(where: {
                              $0.id == selectedFileID
                          }) {
                    self.currentIndex = restoredIndex
                }
            }

            for relocated in relocatedAdditions {
                self.loadedSignatureByPath.removeValue(forKey: relocated.oldPath)
                self.loadedSignatureByPath[relocated.file.url.path] = relocated.signature
            }
            for addition in toAppend {
                if let signature = addition.signature {
                    self.loadedSignatureByPath[addition.file.url.path] = signature
                }
            }
            self.audioFiles.append(contentsOf: toAppend.map(\.file))
            if !self.fullOrderIndexForAudioFile.isEmpty {
                self.fullOrderIndexForAudioFile.append(contentsOf: repeatElement(
                    nil,
                    count: toAppend.count
                ))
            }
            self.invalidateQueueIndexCache()
            self.updateFilteredFiles()
            let addedFiles = relocatedAdditions.map(\.file) + toAppend.map(\.file)
            self.enqueueDurationPrefetch(for: addedFiles.map(\.url))
            if relocatedAdditions.isEmpty {
                self.integrateNewQueueIndicesIntoShuffleQueue(oldCount: oldCount)
            } else {
                self.resetShuffleQueue()
            }

            if !queueWeightRekeys.isEmpty {
                self.appendPendingQueueWeightRekeys(queueWeightRekeys)
            }
            self.savePlaylist()
            if !queueWeightRekeys.isEmpty,
               self.flushPlaylistPersistence().isDurable {
                self.replayPendingQueueWeightRekeysIfPossible()
            }

            if wasEmpty && !self.audioFiles.isEmpty && !self.isRestoringPlaylist {
                NotificationCenter.default.post(name: .playlistDidAddFirstFiles, object: nil)
            }
        }
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

        let sourceFiles = audioFiles
        // Indexes keep the scheduling input compact even for a 100k-track queue;
        // copying every AudioFile into an enumerated tuple array would retain a
        // second large collection of metadata and lyric references.
        let sourceIndexes = Array(sourceFiles.indices)
        let completedRefreshes = await BoundedWorkerPool.map(
            items: sourceIndexes,
            maxConcurrent: Self.maximumConcurrentMetadataRefreshTasks
        ) { [weak self] index -> (Int, AudioFile)? in
            guard let self, !Task.isCancelled else { return nil }
            let file = sourceFiles[index]
            let newMetadata = await self.loadFreshMetadata(from: file.url)
            guard !Task.isCancelled else { return nil }
            await MetadataCache.shared.storeBasicMetadata(newMetadata, for: file.url)
            // 不保留歌词时间轴，强制后续重新解析（避免外部 .lrc 或嵌入歌词更新后不生效）
            let newFile = AudioFile(
                url: file.url,
                metadata: newMetadata,
                lyricsTimeline: nil,
                duration: file.duration
            )
            return (index, newFile)
        }
        var refreshedFiles = sourceFiles
        for case let (index, refreshedFile)? in completedRefreshes {
            refreshedFiles[index] = refreshedFile
        }
        let completedFiles = refreshedFiles

        await MainActor.run {
            audioFiles = completedFiles
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
        if let freshMetadataLoaderOverride {
            return await freshMetadataLoaderOverride(url)
        }
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
    func loadCachedMetadata(from url: URL, snapshot: FileValidationSnapshot? = nil) async -> AudioMetadata {
        if let cached = await MetadataCache.shared.cachedMetadataIfValid(for: url, snapshot: snapshot) {
            return cached
        }
        let fresh = await loadFreshMetadata(from: url)
        await MetadataCache.shared.storeBasicMetadata(fresh, for: url, snapshot: snapshot)
        return fresh
    }
    
    @discardableResult
    func removeFile(at index: Int) -> QueueRemovalContext? {
        guard isQueueContentMutationAllowed() else { return nil }
        guard audioFiles.indices.contains(index) else { return nil }
        let removedFile = audioFiles[index]
        let removedURL = removedFile.url
        let removedPath = removedURL.path
        let scopeBeforeRemoval = playbackScope
        let playlistPositionBeforeRemoval: Int?
        switch scopeBeforeRemoval {
        case .queue:
            playlistPositionBeforeRemoval = nil
        case .playlist:
            playlistPositionBeforeRemoval = currentPlaylistPosition()
        }
        let context = QueueRemovalContext(
            removedFile: removedFile,
            originalQueueIndex: index,
            playbackScope: scopeBeforeRemoval,
            playlistPosition: playlistPositionBeforeRemoval
        )
        audioFiles.remove(at: index)

        // Remove corresponding full-order index slot
        if index < fullOrderIndexForAudioFile.count {
            fullOrderIndexForAudioFile.remove(at: index)
        }

        // Clear loaded signature only if no other item with same path remains
        let remainingPathCount = audioFiles.filter { $0.url.path == removedPath }.count
        if remainingPathCount == 0 {
            loadedSignatureByPath.removeValue(forKey: removedPath)
        }

        invalidateQueueIndexCache()
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
        return context
    }

    func nextFileAfterRemovingQueueItem(
        _ context: QueueRemovalContext,
        queueIndexAfterBatchRemoval: Int? = nil
    ) -> AudioFile? {
        guard !audioFiles.isEmpty else { return nil }
        guard playbackScope == context.playbackScope else { return nil }

        switch context.playbackScope {
        case .queue:
            let insertionIndex = queueIndexAfterBatchRemoval ?? context.originalQueueIndex
            let normalizedInsertionIndex = max(0, insertionIndex)
            let start = normalizedInsertionIndex < audioFiles.count ? normalizedInsertionIndex : 0
            for offset in 0 ..< audioFiles.count {
                let index = (start + offset) % audioFiles.count
                guard !isUnplayableIndex(index) else { continue }
                currentIndex = index
                savePlaylist()
                return audioFiles[index]
            }
            return nil

        case .playlist:
            guard let removedPosition = context.playlistPosition,
                  !playbackPlaylistTrackKeys.isEmpty else { return nil }
            let total = playbackPlaylistTrackKeys.count
            for offset in 1 ... total {
                let position = (removedPosition + offset) % total
                let occurrenceKey = playbackPlaylistTrackKeys[position]
                guard let pathKey = pathKeyForPlaylistOccurrence(occurrenceKey),
                      let index = indexInQueue(forPathKey: pathKey),
                      !isUnplayableIndex(index) else { continue }
                currentIndex = index
                currentPlaybackPlaylistOccurrenceKey = occurrenceKey
                savePlaylist()
                return audioFiles[index]
            }
            return nil
        }
    }
    
    @MainActor
    @discardableResult
    func clearAllFiles() -> QueueClearResult {
        guard queueLoadState == .ready else { return .rejected }
        guard isQueueContentMutationAllowed() else { return .rejected }
        cancelDurationPrefetch()
        audioFiles.removeAll()
        invalidateQueueIndexCache()
        filteredFiles.removeAll()
        currentIndex = 0
        searchText = ""
        unplayableReasons.removeAll()
        resetShuffleQueue()
        setPlaybackScopeQueue()
        retainedMissingWithOriginalIndex.removeAll()
        fullOrderIndexForAudioFile.removeAll()
        loadedSignatureByPath.removeAll()
        pendingQueueWeightRekeys.removeAll()
        savePlaylist() // 清空后保存
        return .applied(flushPlaylistPersistence())
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
    func ensureInQueue(_ files: [AudioFile], focusURL: URL? = nil, signatures: [String: FileSignature] = [:]) -> Int? {
        guard !files.isEmpty else { return nil }
        guard queueLoadState == .ready else { return nil }
        guard isQueueContentMutationAllowed() else { return nil }

        var indexByKey: [String: Int] = [:]
        indexByKey.reserveCapacity(audioFiles.count)
        for (idx, f) in audioFiles.enumerated() {
            indexByKey[pathKey(f.url)] = idx
        }

        let focusKey = focusURL.map { pathKey($0) }
        let existingFocusIndex: Int? = focusKey.flatMap { indexByKey[$0] }
        var focusIndex = existingFocusIndex

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
        let additions = toAppend.map { file in
            (file: file, signature: signatures[file.url.path])
        }
        guard queueStateFitsPersistenceBounds(addingFiles: additions) else {
            notifyQueueCapacityRejected()
            return existingFocusIndex
        }

        // Store signatures only for files that are actually appended
        for f in toAppend {
            if let sig = signatures[f.url.path] {
                loadedSignatureByPath[f.url.path] = sig
            }
        }

        let oldCount = audioFiles.count
        audioFiles.append(contentsOf: toAppend)
        invalidateQueueIndexCache()
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
        guard audioFiles.indices.contains(index) else { return nil }
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
                savePlaylist()
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
                savePlaylist()
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
        createShuffleQueue(startFromRandom: true)
        if !shuffleQueue.isEmpty {
            currentIndex = shuffleQueue[0]
            shuffleIndex = 1
            savePlaylist()
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
            let occurrenceKey = playbackPlaylistTrackKeys[position]
            guard let pathKey = pathKeyForPlaylistOccurrence(occurrenceKey),
                  let idx = indexInQueue(forPathKey: pathKey) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            currentPlaybackPlaylistOccurrenceKey = occurrenceKey
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
            let occurrenceKey = playbackPlaylistTrackKeys[position]
            guard let pathKey = pathKeyForPlaylistOccurrence(occurrenceKey),
                  let idx = indexInQueue(forPathKey: pathKey) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            currentPlaybackPlaylistOccurrenceKey = occurrenceKey
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
                let occurrenceKey = playlistShuffleQueueKeys[i]
                if let pathKey = pathKeyForPlaylistOccurrence(occurrenceKey),
                   let idx = indexInQueue(forPathKey: pathKey),
                   !isUnplayableIndex(idx) {
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
            let occurrenceKey = playbackPlaylistTrackKeys[position]
            if let pathKey = pathKeyForPlaylistOccurrence(occurrenceKey),
               let idx = indexInQueue(forPathKey: pathKey),
               !isUnplayableIndex(idx) {
                return audioFiles[idx]
            }
        }
        return nil
    }

    private func getRandomFileInPlaylist() -> AudioFile? {
        createPlaylistShuffleQueue(startFromRandom: true)
        guard let firstKey = playlistShuffleQueueKeys.first,
              let pathKey = pathKeyForPlaylistOccurrence(firstKey),
              let idx = indexInQueue(forPathKey: pathKey),
              !isUnplayableIndex(idx) else { return nil }
        currentIndex = idx
        currentPlaybackPlaylistOccurrenceKey = firstKey
        savePlaylist()
        return audioFiles[idx]
    }

    private func getRandomFileExcludingCurrentInPlaylist() -> AudioFile? {
        guard playbackScopePlayableCount() > 1 else { return nil }
        guard case .playlist(let playlistID) = playbackScope else { return nil }

        let currentKey = currentPlaybackPlaylistOccurrenceKey
        var candidates: [String] = []
        candidates.reserveCapacity(playbackPlaylistTrackKeys.count)
        for key in playbackPlaylistTrackKeys {
            if key == currentKey { continue }
            guard let pathKey = pathKeyForPlaylistOccurrence(key),
                  let idx = indexInQueue(forPathKey: pathKey) else { continue }
            if isUnplayableIndex(idx) { continue }
            candidates.append(key)
        }
        guard let chosenKey = weightedRandomKey(keys: candidates, scope: .playlist(playlistID)),
              let pathKey = pathKeyForPlaylistOccurrence(chosenKey),
              let idx = indexInQueue(forPathKey: pathKey),
              !isUnplayableIndex(idx)
        else { return nil }

        currentIndex = idx
        currentPlaybackPlaylistOccurrenceKey = chosenKey
        savePlaylist()
        return audioFiles[idx]
    }

    private func currentPathKeyInQueue() -> String? {
        guard currentIndex >= 0, currentIndex < audioFiles.count else { return nil }
        return pathLookupKeys(audioFiles[currentIndex].url).first
    }

    private func currentPlaylistPosition() -> Int? {
        let currentPath = currentPathKeyInQueue()
        if let current = currentPlaybackPlaylistOccurrenceKey,
           let position = playbackPlaylistPositionByKey[current],
           pathKeyForPlaylistOccurrence(current) == currentPath {
            return position
        }
        guard let inferred = occurrenceKeyMatchingCurrentQueuePath() else { return nil }
        currentPlaybackPlaylistOccurrenceKey = inferred
        return playbackPlaylistPositionByKey[inferred]
    }

    private func indexInQueue(forPathKey key: String) -> Int? {
        rebuildQueueIndexCacheIfNeeded()
        for lookup in PathKey.lookupKeys(forPath: key) {
            if let idx = queueIndexByPathKey[lookup] {
                return idx
            }
        }
        return nil
    }

    private func invalidateQueueIndexCache() {
        isQueueIndexCacheDirty = true
    }

    private func rebuildQueueIndexCacheIfNeeded() {
        guard isQueueIndexCacheDirty else { return }
        isQueueIndexCacheDirty = false

        var indexMap: [String: Int] = [:]
        indexMap.reserveCapacity(max(16, audioFiles.count * 2))

        for (idx, file) in audioFiles.enumerated() {
            let keys = pathLookupKeys(file.url)
            guard let canonical = keys.first else { continue }
            indexMap[canonical] = idx
            for variant in keys.dropFirst() where indexMap[variant] == nil {
                indexMap[variant] = idx
            }
        }

        queueIndexByPathKey = indexMap
    }

    private func integrateNewQueueIndicesIntoShuffleQueue(oldCount: Int) {
        guard oldCount >= 0, oldCount < audioFiles.count else { return }
        guard !shuffleQueue.isEmpty else { return }

        let newIndices = (oldCount..<audioFiles.count).filter { !isUnplayableIndex($0) }
        guard !newIndices.isEmpty else { return }

        let insertLowerBound = min(shuffleIndex, shuffleQueue.count)
        for idx in newIndices {
            let weight = playbackWeights.multiplier(for: audioFiles[idx].url, scope: .queue)
            let u = Double.random(in: 0...1)
            let remaining = max(0, shuffleQueue.count - insertLowerBound)
            let fraction = pow(u, weight) // higher weight -> closer to 0 -> earlier
            let pos = insertLowerBound + Int((fraction * Double(remaining + 1)).rounded(.down))
            shuffleQueue.insert(idx, at: pos)
        }
    }

    // 洗牌算法
    private func createShuffleQueue(startFromRandom: Bool = false) {
        let playable = audioFiles.indices.filter { !isUnplayableIndex($0) }
        guard !playable.isEmpty else {
            shuffleQueue.removeAll(keepingCapacity: true)
            shuffleIndex = 0
            return
        }

        if startFromRandom || !playable.contains(currentIndex) || playable.count == 1 {
            shuffleQueue = weightedShuffleIndices(playable, scope: .queue)
            shuffleIndex = 0
            return
        }

        let rest = weightedShuffleIndices(playable.filter { $0 != currentIndex }, scope: .queue)
        shuffleQueue = [currentIndex] + rest
        shuffleIndex = 1
    }

    private func createPlaylistShuffleQueue(startFromRandom: Bool = false) {
        // Build a playable list in playlist order (skip missing/not-in-queue and unplayable).
        var playableKeys: [String] = []
        playableKeys.reserveCapacity(playbackPlaylistTrackKeys.count)
        for key in playbackPlaylistTrackKeys {
            guard let pathKey = pathKeyForPlaylistOccurrence(key),
                  let idx = indexInQueue(forPathKey: pathKey) else { continue }
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

        if let currentKey = currentPlaybackPlaylistOccurrenceKey,
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
            acc += playbackWeights.multiplier(for: audioFiles[idx].url, scope: scope)
        }
        guard total.isFinite, total > 0 else { return indices.randomElement() }

        var r = Double.random(in: 0..<total)
        for idx in indices {
            r -= playbackWeights.multiplier(for: audioFiles[idx].url, scope: scope)
            if r <= 0 { return idx }
        }
        return indices.last
    }

    private func weightedRandomKey(keys: [String], scope: PlaybackWeights.Scope) -> String? {
        guard !keys.isEmpty else { return nil }
        let total = keys.reduce(into: 0.0) { acc, key in
            let weightKey = pathKeyForPlaylistOccurrence(key) ?? key
            acc += playbackWeights.multiplier(forKey: weightKey, scope: scope)
        }
        guard total.isFinite, total > 0 else { return keys.randomElement() }

        var r = Double.random(in: 0..<total)
        for key in keys {
            let weightKey = pathKeyForPlaylistOccurrence(key) ?? key
            r -= playbackWeights.multiplier(forKey: weightKey, scope: scope)
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
            let w = max(0.000_001, playbackWeights.multiplier(for: audioFiles[idx].url, scope: scope))
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
            let weightKey = pathKeyForPlaylistOccurrence(key) ?? key
            let w = max(
                0.000_001,
                playbackWeights.multiplier(forKey: weightKey, scope: scope)
            )
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
            guard let pathKey = pathKeyForPlaylistOccurrence(key),
                  let idx = indexInQueue(forPathKey: pathKey) else { continue }
            if isUnplayableIndex(idx) { continue }
            currentIndex = idx
            currentPlaybackPlaylistOccurrenceKey = key
            savePlaylist()
            return audioFiles[idx]
        }
        return nil
    }

    private func getPreviousShuffledFileInPlaylist() -> AudioFile? {
        // playlistShuffleIndex points to "next position to read for next()"
        // To go back, we need the item at playlistShuffleIndex - 2
        guard playlistShuffleIndex >= 2 else { return nil }

        var searchIndex = playlistShuffleIndex - 2
        while searchIndex >= 0 {
            let key = playlistShuffleQueueKeys[searchIndex]
            guard let pathKey = pathKeyForPlaylistOccurrence(key),
                  let idx = indexInQueue(forPathKey: pathKey) else {
                searchIndex -= 1
                continue
            }
            if !isUnplayableIndex(idx) {
                currentIndex = idx
                currentPlaybackPlaylistOccurrenceKey = key
                playlistShuffleIndex = searchIndex + 1  // Set cursor so next() returns the following item
                savePlaylist()
                return audioFiles[idx]
            }
            searchIndex -= 1
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
                savePlaylist()
                return audioFiles[idx]
            }
        }
        return nil
    }
    
    private func getPreviousShuffledFile() -> AudioFile? {
        // shuffleIndex points to "next position to read for next()"
        // To go back, we need the item at shuffleIndex - 2
        guard shuffleIndex >= 2 else { return nil }

        var searchIndex = shuffleIndex - 2
        while searchIndex >= 0 {
            let idx = shuffleQueue[searchIndex]
            if !isUnplayableIndex(idx) {
                currentIndex = idx
                shuffleIndex = searchIndex + 1  // Set cursor so next() returns the following item
                savePlaylist()
                return audioFiles[idx]
            }
            searchIndex -= 1
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
        guard !isRunningRegressionTests else { return }
        let d = UserDefaults.standard
        d.set(scanSubfolders, forKey: userScanSubfoldersKey)
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
        if isRunningRegressionTests {
            debugLog("回归测试模式：跳过播放列表持久化写盘")
            return
        }
        let previousWorkItem: DispatchWorkItem?
        playlistSaveStateLock.lock()
        guard !isPlaylistPersistenceReadOnly else {
            playlistSaveStateLock.unlock()
            notifyProtectedQueueMutationIfNeeded()
            return
        }
        guard canBuildPlaylistPersistenceSnapshot else {
            playlistSaveStateLock.unlock()
            debugLog("队列尚未完成恢复：跳过持久化快照")
            return
        }
        playlistSaveRevision &+= 1
        let revision = playlistSaveRevision
        previousWorkItem = playlistSaveWorkItem
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.playlistSaveStateLock.lock()
            let isLatest = revision == self.playlistSaveRevision
            if isLatest {
                self.playlistSaveWorkItem = nil
            }
            self.playlistSaveStateLock.unlock()
            guard isLatest else { return }

            // Capture the latest queue only when the debounce drains, so rapid
            // navigation does not repeatedly allocate O(queue-size) path arrays.
            let snapshot = self.buildPlaylistSnapshot()
            self.debugLog(
                "保存播放列表: \(snapshot.paths.count) 个文件, 当前索引: \(snapshot.currentIndex)"
            )
            self.enqueuePlaylistWrite(snapshot, revision: revision)
        }
        playlistSaveWorkItem = workItem
        playlistSaveStateLock.unlock()
        previousWorkItem?.cancel()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + playlistSaveDebounceInterval,
            execute: workItem
        )
    }

    @discardableResult
    func flushPlaylistPersistence(timeout: TimeInterval = 5) -> QueuePersistenceFlushResult {
        guard !isRunningRegressionTests else {
            return QueuePersistenceFlushResult(
                outcome: .durable,
                attemptedRevision: playlistSaveRevision,
                durableRevision: playlistSaveRevision
            )
        }

        playlistSaveStateLock.lock()
        let readOnly = isPlaylistPersistenceReadOnly
        let canBuildSnapshot = canBuildPlaylistPersistenceSnapshot
        if readOnly || !canBuildSnapshot {
            playlistSaveRevision &+= 1
            let pending = playlistSaveWorkItem
            playlistSaveWorkItem = nil
            pendingPlaylistWrite = nil
            playlistRetryWorkItem?.cancel()
            playlistRetryWorkItem = nil
            playlistSaveStateLock.unlock()
            pending?.cancel()

            // The in-memory queue is either a protected schema or a temporary
            // pre-restore placeholder. Drain work already executing, but never
            // publish that placeholder as a new disk snapshot.
            let drained = drainPlaylistWrites(timeout: timeout, performDrain: false)
            if readOnly {
                notifyProtectedQueueMutationIfNeeded()
            }
            playlistSaveStateLock.lock()
            let attemptedRevision = playlistSaveRevision
            let durableRevision = playlistDurableRevision
            playlistSaveStateLock.unlock()
            return QueuePersistenceFlushResult(
                outcome: drained
                    ? (readOnly ? .protectedReadOnly : .skippedBeforeRestore)
                    : .timedOut,
                attemptedRevision: attemptedRevision,
                durableRevision: durableRevision
            )
        }
        playlistSaveStateLock.unlock()

        // Publish the flush snapshot through the same bounded, serial drain as
        // debounced saves. A flush can therefore never overtake an older write
        // or overwrite a newer snapshot that the active drain already picked up.
        let snapshot = buildPlaylistSnapshot()
        playlistSaveStateLock.lock()
        playlistSaveRevision &+= 1
        let revision = playlistSaveRevision
        let pending = playlistSaveWorkItem
        playlistSaveWorkItem = nil
        playlistRetryWorkItem?.cancel()
        playlistRetryWorkItem = nil
        playlistRetryAttempt = 0
        pendingPlaylistWrite = (revision, snapshot)
        isPlaylistWriteDrainScheduled = true
        playlistSaveStateLock.unlock()
        pending?.cancel()

        let drained = drainPlaylistWrites(timeout: timeout, performDrain: true)

        playlistSaveStateLock.lock()
        let durableRevision = playlistDurableRevision
        let isDurable = durableRevision >= revision
        playlistSaveStateLock.unlock()
        return QueuePersistenceFlushResult(
            outcome: isDurable ? .durable : (drained ? .failed : .timedOut),
            attemptedRevision: revision,
            durableRevision: durableRevision
        )
    }

    private func drainPlaylistWrites(
        timeout: TimeInterval,
        performDrain: Bool
    ) -> Bool {
        if DispatchQueue.getSpecific(key: playlistIOQueueKey) != nil {
            if performDrain { drainLatestPlaylistWrites() }
            return true
        }
        let completion = DispatchSemaphore(value: 0)
        playlistIOQueue.async { [self] in
            if performDrain { drainLatestPlaylistWrites() }
            completion.signal()
        }
        return completion.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func enqueuePlaylistWrite(_ snapshot: SavedPlaylist, revision: UInt64) {
        playlistSaveStateLock.lock()
        guard revision == playlistSaveRevision else {
            playlistSaveStateLock.unlock()
            return
        }
        playlistRetryWorkItem?.cancel()
        playlistRetryWorkItem = nil
        playlistRetryAttempt = 0
        pendingPlaylistWrite = (revision, snapshot)
        guard !isPlaylistWriteDrainScheduled else {
            playlistSaveStateLock.unlock()
            return
        }
        isPlaylistWriteDrainScheduled = true
        playlistSaveStateLock.unlock()

        playlistIOQueue.async { [weak self] in
            self?.drainLatestPlaylistWrites()
        }
    }

    private func drainLatestPlaylistWrites() {
        while true {
            playlistSaveStateLock.lock()
            guard let pending = pendingPlaylistWrite else {
                isPlaylistWriteDrainScheduled = false
                playlistSaveStateLock.unlock()
                return
            }
            pendingPlaylistWrite = nil
            playlistSaveStateLock.unlock()

            // Revisions can advance before their debounce has produced a new
            // snapshot. The captured snapshot is still safe to write: enqueues
            // are monotonic, and a newer captured snapshot replaces the single
            // pending slot or is written on the next loop iteration.
            let didPersist = savePlaylistToDisk(pending.snapshot)
            var shouldReturnForRetry = false
            playlistSaveStateLock.lock()
            if didPersist {
                playlistDurableRevision = max(playlistDurableRevision, pending.revision)
                if let failedRevision = playlistLastFailedRevision,
                   failedRevision <= pending.revision {
                    playlistLastFailedRevision = nil
                }
                playlistRetryAttempt = 0
                playlistRetryWorkItem?.cancel()
                playlistRetryWorkItem = nil
            } else {
                playlistLastFailedRevision = max(playlistLastFailedRevision ?? 0, pending.revision)
                if pendingPlaylistWrite == nil || pendingPlaylistWrite!.revision <= pending.revision {
                    pendingPlaylistWrite = pending
                    isPlaylistWriteDrainScheduled = false
                    schedulePlaylistWriteRetryLocked()
                    shouldReturnForRetry = true
                }
            }
            playlistSaveStateLock.unlock()
            if shouldReturnForRetry { return }
        }
    }

    /// Must be called with `playlistSaveStateLock` held.
    private func schedulePlaylistWriteRetryLocked() {
        guard !isPlaylistPersistenceReadOnly,
              pendingPlaylistWrite != nil,
              playlistRetryWorkItem == nil,
              playlistRetryAttempt < 3 else { return }

        playlistRetryAttempt += 1
        let attempt = playlistRetryAttempt
        let delay: TimeInterval
        switch attempt {
        case 1: delay = 0.25
        case 2: delay = 0.75
        default: delay = 2.0
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.playlistSaveStateLock.lock()
            self.playlistRetryWorkItem = nil
            guard !self.isPlaylistPersistenceReadOnly,
                  self.pendingPlaylistWrite != nil,
                  !self.isPlaylistWriteDrainScheduled else {
                self.playlistSaveStateLock.unlock()
                return
            }
            self.isPlaylistWriteDrainScheduled = true
            self.playlistSaveStateLock.unlock()
            self.drainLatestPlaylistWrites()
        }
        playlistRetryWorkItem = workItem
        playlistIOQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func buildPlaylistSnapshot() -> SavedPlaylist {
        // Build entries with stable sorting keys
        struct Entry {
            let sortKey: Int
            let record: SavedPlaylist.TrackRecord
            let runtimeIndex: Int?
        }

        var entries: [Entry] = []
        var nextNewItemSortKey = 0

        // Collect all original-index items (both active and missing)
        if !fullOrderIndexForAudioFile.isEmpty {
            nextNewItemSortKey = fullOrderIndexForAudioFile.compactMap { $0 }.max().map { $0 + 1 } ?? 0
        }
        for (originalIndex, _) in retainedMissingWithOriginalIndex {
            nextNewItemSortKey = max(nextNewItemSortKey, originalIndex + 1)
        }

        // Add active files with their original or new indices
        for (runtimeIndex, file) in audioFiles.enumerated() {
            let path = file.url.path
            let sig = loadedSignatureByPath[path]
            let record = SavedPlaylist.TrackRecord(path: path, signature: sig)

            let sortKey: Int
            if runtimeIndex < fullOrderIndexForAudioFile.count, let originalIndex = fullOrderIndexForAudioFile[runtimeIndex] {
                sortKey = originalIndex
            } else {
                sortKey = nextNewItemSortKey
                nextNewItemSortKey += 1
            }

            entries.append(Entry(sortKey: sortKey, record: record, runtimeIndex: runtimeIndex))
        }

        // Add retained missing records
        for (originalIndex, record) in retainedMissingWithOriginalIndex {
            entries.append(Entry(sortKey: originalIndex, record: record, runtimeIndex: nil))
        }

        // Sort by original index to restore interleaved order
        entries.sort { $0.sortKey < $1.sortKey }

        let finalRecords = entries.map { $0.record }
        // Map currentIndex from runtime to full-order position
        let fullOrderCurrentIndex: Int
        if let retainedSavedCurrentFullOrderIndex,
           let retainedPosition = entries.firstIndex(where: {
               $0.runtimeIndex == nil && $0.sortKey == retainedSavedCurrentFullOrderIndex
           }) {
            fullOrderCurrentIndex = retainedPosition
        } else if currentIndex >= 0 && currentIndex < audioFiles.count {
            if let position = entries.firstIndex(where: { $0.runtimeIndex == currentIndex }) {
                fullOrderCurrentIndex = position
            } else {
                fullOrderCurrentIndex = 0
            }
        } else {
            fullOrderCurrentIndex = 0
        }

        return SavedPlaylist(
            version: playlistFormatVersion,
            tracks: finalRecords,
            paths: [],
            currentIndex: fullOrderCurrentIndex,
            pendingWeightRekeys: pendingQueueWeightRekeys.isEmpty ? nil : pendingQueueWeightRekeys
        )
    }

    func loadSavedPlaylist(audioPlayer: AudioPlayer? = nil) async {
        guard let saved = loadSavedPlaylistSnapshot() else {
            debugLog("没有找到保存的播放列表")
            return
        }
        guard !Task.isCancelled else { return }

        // Parse TrackRecords from v1 schema or fall back to legacy paths.
        // A v1 payload with an empty tracks array and populated paths came from
        // an intermediate build and must not silently erase the queue.
        let records: [SavedPlaylist.TrackRecord]
        if let tracks = saved.tracks, !tracks.isEmpty || saved.paths.isEmpty {
            records = tracks
        } else {
            records = saved.paths.map { SavedPlaylist.TrackRecord(path: $0, signature: nil) }
        }

        let fileManager = FileManager.default
        var validEntries: [(url: URL, snapshot: FileValidationSnapshot, signature: FileSignature?, originalIndex: Int)] = []
        var missingWithIndex: [(originalIndex: Int, record: SavedPlaylist.TrackRecord)] = []

        for (originalIndex, record) in records.enumerated() {
            if Task.isCancelled { return }
            let url = URL(fileURLWithPath: record.path)
            let snapshot = FileValidationSnapshot.load(for: url, fileManager: fileManager)
            if snapshot.exists {
                validEntries.append((url, snapshot, record.signature, originalIndex))
            } else {
                missingWithIndex.append((originalIndex, record))
            }
        }

        // Build signature cache with last-wins for duplicate paths
        let signatureMap = validEntries.reduce(into: [String: FileSignature]()) { map, entry in
            if let sig = entry.signature {
                map[entry.url.path] = sig
            }
        }
        let missingSignatureMap = missingWithIndex.reduce(into: [String: FileSignature]()) { map, item in
            if let sig = item.record.signature {
                map[item.record.path] = sig
            }
        }
        let combinedSignatureMap = signatureMap.merging(missingSignatureMap) { _, missing in missing }

        let validURLs = validEntries.map(\.url)

        if validURLs.isEmpty {
            debugLog("保存的播放列表中没有任何仍然存在的文件")
            let missingSnapshot = missingWithIndex
            let sigMapSnapshot = combinedSignatureMap
            guard !Task.isCancelled else { return }
            let accepted = await MainActor.run { () -> Bool in
                guard !Task.isCancelled, !self.isTerminating else { return false }
                self.retainedMissingWithOriginalIndex = missingSnapshot
                self.fullOrderIndexForAudioFile = []
                self.loadedSignatureByPath = sigMapSnapshot
                self.retainedSavedCurrentFullOrderIndex = records.indices.contains(saved.currentIndex)
                    ? saved.currentIndex
                    : nil
                self.pendingQueueWeightRekeys = saved.pendingWeightRekeys ?? []
                if self.queueLoadState == .ready {
                    self.replayPendingQueueWeightRekeysIfPossible()
                }
                return true
            }
            guard accepted else { return }
            return
        }

        debugLog("轻量恢复保存的播放列表: \(validURLs.count) 个文件")

        // 取消上一轮“恢复后补全元数据”的后台任务（若存在）
        // 标记正在恢复播放列表，避免触发“首次添加自动播放”等逻辑（必须在主线程发布）
        let beganRestore = await MainActor.run { () -> Bool in
            guard !Task.isCancelled, !self.isTerminating else { return false }
            self.restoredMetadataHydrationTask?.cancel()
            self.restoredMetadataHydrationTask = nil
            self.restoredMetadataHydrationGeneration &+= 1
            self.cancelDurationPrefetch()
            self.isRestoringPlaylist = true
            return true
        }
        guard beganRestore else { return }

        // 恢复时优先使用磁盘元数据缓存（有失效判断），避免整列表先显示“未知艺术家/未知专辑”。
        var restoredFiles: [AudioFile] = []
        restoredFiles.reserveCapacity(validURLs.count)
        var cacheHits = 0
        var needsHydration: [URL] = []
        needsHydration.reserveCapacity(validURLs.count)
        var missingDurationURLs: [URL] = []
        missingDurationURLs.reserveCapacity(validURLs.count)
        for entry in validEntries {
            if Task.isCancelled { return }
            let url = entry.url
            let snapshot = entry.snapshot
            let duration = await DurationCache.shared.cachedDurationIfValid(for: url, snapshot: snapshot)
            if duration == nil {
                missingDurationURLs.append(url)
            }
            if let cached = await MetadataCache.shared.cachedMetadataIfValid(for: url, snapshot: snapshot) {
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
            needsHydration.append(url)
        }
        debugLog("恢复播放列表元数据缓存命中: \(cacheHits)/\(validURLs.count)")

        // Build full-order index mapping for runtime files
        var fullOrderIndices: [Int?] = []
        fullOrderIndices.reserveCapacity(restoredFiles.count)
        for entry in validEntries {
            fullOrderIndices.append(entry.originalIndex)
        }

        // Map saved currentIndex from full list to runtime available files
        let runtimeCurrentIndex: Int
        if let runtimeIdx = validEntries.firstIndex(where: { $0.originalIndex == saved.currentIndex }) {
            runtimeCurrentIndex = runtimeIdx
        } else if saved.currentIndex < records.count {
            // Saved current item is missing: prefer first valid item after it
            if let nextIdx = validEntries.firstIndex(where: { $0.originalIndex > saved.currentIndex }) {
                runtimeCurrentIndex = nextIdx
            } else if let lastIdx = validEntries.lastIndex(where: { $0.originalIndex < saved.currentIndex }) {
                runtimeCurrentIndex = lastIdx
            } else {
                runtimeCurrentIndex = 0
            }
        } else {
            runtimeCurrentIndex = 0
        }

        let restoredFilesSnapshot = restoredFiles
        let durationPrefetchURLs = missingDurationURLs
        let sigMapSnapshot = combinedSignatureMap
        let missingSnapshot = missingWithIndex
        let fullOrderSnapshot = fullOrderIndices
        guard !Task.isCancelled else { return }
        let installed = await MainActor.run { () -> Bool in
            guard !Task.isCancelled, !self.isTerminating else { return false }
            self.retainedMissingWithOriginalIndex = missingSnapshot
            self.fullOrderIndexForAudioFile = fullOrderSnapshot
            self.loadedSignatureByPath = sigMapSnapshot
            self.audioFiles = restoredFilesSnapshot
            self.invalidateQueueIndexCache()
            self.isApplyingPersistedCurrentIndex = true
            self.currentIndex = min(max(runtimeCurrentIndex, 0), restoredFilesSnapshot.count - 1)
            self.isApplyingPersistedCurrentIndex = false
            self.retainedSavedCurrentFullOrderIndex = missingSnapshot.contains {
                $0.originalIndex == saved.currentIndex
            } ? saved.currentIndex : nil
            self.pendingQueueWeightRekeys = saved.pendingWeightRekeys ?? []
            self.updateFilteredFiles()
            self.resetShuffleQueue()
            self.enqueueDurationPrefetch(for: durationPrefetchURLs)
            if self.queueLoadState == .ready {
                self.replayPendingQueueWeightRekeysIfPossible()
            }
            return true
        }
        guard installed, !Task.isCancelled else { return }

        // 恢复完成；后续由 AudioPlayer.loadLastPlayedFile 按需定位到具体曲目
        let finishedRestore = await MainActor.run { () -> Bool in
            guard !self.isTerminating else { return false }
            self.isRestoringPlaylist = false
            return true
        }
        guard finishedRestore, !Task.isCancelled else { return }

        // 在后台逐步补全真实元数据（避免重启后整列表都显示“未知艺术家/未知专辑”）。
        let hydrationURLs = needsHydration
        guard !hydrationURLs.isEmpty else { return }
        await MainActor.run {
            guard !self.isTerminating, !Task.isCancelled else { return }
            self.restoredMetadataHydrationGeneration &+= 1
            let generation = self.restoredMetadataHydrationGeneration
            self.restoredMetadataHydrationTask = Task.detached(priority: .utility) { [weak self, weak audioPlayer] in
                guard let self else { return }
                await self.hydrateRestoredMetadata(urls: hydrationURLs, audioPlayer: audioPlayer)
                await MainActor.run {
                    guard self.restoredMetadataHydrationGeneration == generation else { return }
                    self.restoredMetadataHydrationTask = nil
                }
            }
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
                guard let self, !self.isTerminating else { return }
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

    /// Waits for restore follow-up work so tests can clean temporary cache entries
    /// deterministically before the test process exits.
    func waitForBackgroundRestoreWorkForTesting() async {
        let metadataTask = await MainActor.run { restoredMetadataHydrationTask }
        await metadataTask?.value
        let durationTask = await MainActor.run { durationPrefetchTask }
        await durationTask?.value
    }

    private func loadSavedPlaylistSnapshot() -> SavedPlaylist? {
        let diskOutcome = loadSavedPlaylistFromDisk()

        switch diskOutcome {
        case .loaded(let snapshot):
            return snapshot
        case .protectedFuture, .protectedCorrupt, .protectedUnreadable:
            // Disk file exists but is protected; do not fall back to UserDefaults
            return nil
        case .missing:
            // Only fall back to UserDefaults when disk file is truly absent
            break
        }

        // 兼容旧版 UserDefaults：读取后迁移到磁盘
        let d = UserDefaults.standard
        if let filePaths = d.stringArray(forKey: "savedPlaylistPaths"), !filePaths.isEmpty {
            let savedIndex = d.integer(forKey: "savedPlaylistIndex")
            let snapshot = SavedPlaylist(version: nil, tracks: nil, paths: filePaths, currentIndex: savedIndex)
            if savePlaylistToDisk(snapshot) {
                d.removeObject(forKey: "savedPlaylistPaths")
                d.removeObject(forKey: "savedPlaylistIndex")
            }
            return snapshot
        }
        return nil
    }

    private enum PlaylistLoadOutcome {
        case missing
        case loaded(SavedPlaylist)
        case protectedFuture
        case protectedCorrupt
        case protectedUnreadable
    }

    private func loadSavedPlaylistFromDisk() -> PlaylistLoadOutcome {
        guard let url = playlistFileURL() else { return .missing }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        let data: Data
        do {
            data = try DerivedCacheFileIO.readBoundedRegularFile(
                at: url,
                maximumBytes: maximumPlaylistStoreBytes
            )
        } catch {
            debugLog("无法读取队列文件: \(error)")
            setPlaylistPersistenceReadOnly(true)
            PersistenceLogger.log("队列文件无法读取: \(url.path), 错误: \(error)")
            DispatchQueue.main.async {
                PersistenceLogger.notifyUser(title: "队列文件无法读取", subtitle: "已进入保护模式")
            }
            return .protectedUnreadable
        }

        // Probe version before full decode
        let probeVersion: Int?
        do {
            let probe = try JSONDecoder().decode(PlaylistVersionProbe.self, from: data)
            probeVersion = probe.version
        } catch {
            probeVersion = nil
        }

        if let v = probeVersion, v != 1, v != playlistFormatVersion {
            debugLog("队列文件版本 \(v) 不受当前版本支持，进入只读模式")
            setPlaylistPersistenceReadOnly(true)
            PersistenceLogger.log("检测到不受支持的队列版本 \(v)，进入只读模式保护数据")
            DispatchQueue.main.async {
                PersistenceLogger.notifyUser(
                    title: "队列文件版本过新",
                    subtitle: "可能由新版本创建，当前版本只读保护"
                )
            }
            return .protectedFuture
        }

        do {
            let snapshot = try JSONDecoder().decode(SavedPlaylist.self, from: data)
            guard isStructurallyValidPlaylistSnapshot(snapshot) else {
                debugLog("队列文件结构或边界校验失败，保留原文件")
                setPlaylistPersistenceReadOnly(true)
                preserveCorruptedPlaylistDiagnostic(at: url, originalData: data)
                return .protectedCorrupt
            }
            return .loaded(snapshot)
        } catch {
            debugLog("队列文件损坏: \(error)，保留原文件并写入有界诊断副本")
            setPlaylistPersistenceReadOnly(true)
            preserveCorruptedPlaylistDiagnostic(at: url, originalData: data)
            return .protectedCorrupt
        }
    }

    private func isStructurallyValidPlaylistSnapshot(_ snapshot: SavedPlaylist) -> Bool {
        guard snapshot.version == nil || snapshot.version == 1
                || snapshot.version == playlistFormatVersion else { return false }
        let records: [SavedPlaylist.TrackRecord]
        if let tracks = snapshot.tracks, !tracks.isEmpty || snapshot.paths.isEmpty {
            records = tracks
        } else {
            records = snapshot.paths.map {
                SavedPlaylist.TrackRecord(path: $0, signature: nil)
            }
        }

        guard records.count <= maximumPlaylistEntries,
              snapshot.currentIndex >= 0,
              (records.isEmpty ? snapshot.currentIndex == 0 : snapshot.currentIndex < records.count)
        else { return false }

        if let version = snapshot.version, version >= 2 {
            guard snapshot.tracks != nil else { return false }
            if !snapshot.paths.isEmpty,
               snapshot.paths != snapshot.tracks?.map(\.path) {
                return false
            }
        } else if let tracks = snapshot.tracks,
                  !tracks.isEmpty,
                  !snapshot.paths.isEmpty,
                  tracks.map(\.path) != snapshot.paths {
            return false
        }

        var aggregatePathBytes = 0
        func consume(_ value: String, requiresAbsolutePath: Bool) -> Bool {
            let byteCount = value.utf8.count
            guard byteCount > 0,
                  byteCount <= maximumPlaylistPathBytes,
                  !value.utf8.contains(0),
                  !requiresAbsolutePath || value.hasPrefix("/"),
                  aggregatePathBytes <= maximumPlaylistAggregatePathBytes - byteCount else {
                return false
            }
            aggregatePathBytes += byteCount
            return true
        }
        for record in records {
            guard consume(record.path, requiresAbsolutePath: true) else { return false }
            if let signature = record.signature {
                guard signature.size >= 0,
                      consume(signature.pathKey, requiresAbsolutePath: false) else { return false }
                if let identifier = signature.fileResourceIdentifier,
                   !consume(identifier, requiresAbsolutePath: false) { return false }
                if let identifier = signature.volumeIdentifier,
                   !consume(identifier, requiresAbsolutePath: false) { return false }
            }
        }

        let rekeys = snapshot.pendingWeightRekeys ?? []
        guard rekeys.count <= maximumPendingWeightRekeys else { return false }
        for rekey in rekeys {
            guard consume(rekey.oldPath, requiresAbsolutePath: true),
                  consume(rekey.newPath, requiresAbsolutePath: true) else { return false }
        }
        return true
    }

    private func setPlaylistPersistenceReadOnly(_ value: Bool) {
        playlistSaveStateLock.lock()
        isPlaylistPersistenceReadOnly = value
        if value {
            // Cancel pending debounced saves and clear pending write
            playlistSaveWorkItem?.cancel()
            playlistSaveWorkItem = nil
            pendingPlaylistWrite = nil
            playlistRetryWorkItem?.cancel()
            playlistRetryWorkItem = nil
            playlistSaveRevision &+= 1
        } else {
            didNotifyProtectedQueueMutation = false
        }
        playlistSaveStateLock.unlock()
        if value {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingAddURLs.removeAll()
                self.addFilesTask?.cancel()
                self.resetAddFilesProgress()
            }
        }
    }

    private func isQueueContentMutationAllowed() -> Bool {
        guard isPlaylistPersistenceWritable() else {
            notifyProtectedQueueMutationIfNeeded()
            return false
        }
        return true
    }

    private func notifyProtectedQueueMutationIfNeeded() {
        playlistSaveStateLock.lock()
        let shouldNotify = !didNotifyProtectedQueueMutation
        didNotifyProtectedQueueMutation = true
        playlistSaveStateLock.unlock()
        guard shouldNotify else { return }
        DispatchQueue.main.async {
            PersistenceLogger.notifyUser(
                title: "队列处于只读保护模式",
                subtitle: "本次修改已拒绝，原队列不会被覆盖"
            )
        }
    }

    private func isPlaylistPersistenceWritable() -> Bool {
        playlistSaveStateLock.lock()
        defer { playlistSaveStateLock.unlock() }
        return !isPlaylistPersistenceReadOnly
    }

    private func preserveCorruptedPlaylistDiagnostic(at url: URL, originalData: Data) {
        let parent = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let digest = Self.stableDigest(originalData)
        var quarantineURL = parent.appendingPathComponent(
            "\(baseName).corrupted.\(digest).json",
            isDirectory: false
        )

        if FileManager.default.fileExists(atPath: quarantineURL.path) {
            if let existing = try? DerivedCacheFileIO.readBoundedRegularFile(
                at: quarantineURL,
                maximumBytes: maximumPlaylistStoreBytes
            ), existing == originalData {
                Self.pruneCorruptedPlaylistDiagnostics(
                    in: parent,
                    baseName: baseName,
                    preserving: quarantineURL
                )
                notifyCorruptedPlaylistPreserved(diagnosticURL: quarantineURL)
                return
            }
            quarantineURL = parent.appendingPathComponent(
                "\(baseName).corrupted.\(digest).\(UUID().uuidString).json",
                isDirectory: false
            )
        }

        do {
            try DerivedCacheFileIO.atomicWrite(originalData, to: quarantineURL)
            Self.pruneCorruptedPlaylistDiagnostics(
                in: parent,
                baseName: baseName,
                preserving: quarantineURL
            )
            notifyCorruptedPlaylistPreserved(diagnosticURL: quarantineURL)
        } catch {
            debugLog("写入队列诊断副本失败: \(error)，原文件仍保持只读")
            PersistenceLogger.log("写入队列诊断副本失败: \(error)，原文件: \(url.path)")
        }
    }

    private func notifyCorruptedPlaylistPreserved(diagnosticURL: URL) {
        debugLog("已保留损坏队列原文件，诊断副本: \(diagnosticURL.lastPathComponent)")
        PersistenceLogger.log("已保留损坏队列原文件，诊断副本: \(diagnosticURL.path)")
        DispatchQueue.main.async {
            PersistenceLogger.notifyUser(
                title: "队列文件已损坏",
                subtitle: "原文件已保护，本次运行不会覆盖"
            )
        }
    }

    private static func stableDigest(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func pruneCorruptedPlaylistDiagnostics(
        in directory: URL,
        baseName: String,
        preserving preservedURL: URL
    ) {
        let fileManager = FileManager.default
        guard let files = DerivedCacheFileIO.boundedDirectoryURLs(
            in: directory,
            maximumEntries: 4_096
        ) else { return }

        let prefix = "\(baseName).corrupted."
        let candidates = files.filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json"
        }
        guard candidates.count > 2 else { return }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs == preservedURL { return false }
            if rhs == preservedURL { return true }
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if lhsDate == rhsDate { return lhs.lastPathComponent < rhs.lastPathComponent }
            return lhsDate < rhsDate
        }
        for staleURL in sorted.prefix(candidates.count - 2) where staleURL != preservedURL {
            try? fileManager.removeItem(at: staleURL)
        }
    }

    private func savePlaylistToDisk(_ snapshot: SavedPlaylist) -> Bool {
        if isRunningRegressionTests {
            return true
        }
        guard let url = playlistFileURL() else { return false }

        // Check write protection before entering IO queue
        guard isPlaylistPersistenceWritable() else { return false }

        let isOnIOQueue = DispatchQueue.getSpecific(key: playlistIOQueueKey) != nil
        let write = {
            // Final write protection check on IO thread
            guard self.isPlaylistPersistenceWritable() else { return false }
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
        guard isStructurallyValidPlaylistSnapshot(snapshot) else {
            throw DerivedCachePersistenceError.writeFailed("队列快照超出条目或路径安全边界")
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumPlaylistStoreBytes else {
            throw DerivedCachePersistenceError.writeFailed("队列快照超过 16 MB 安全上限")
        }
        try playlistFileWriter(data, url)
    }

    private func playlistFileURL() -> URL? {
        if let playlistFileURLOverride {
            do {
                try DerivedCacheFileIO.ensureParentDirectory(for: playlistFileURLOverride)
            } catch {
                debugLog("创建或验证测试播放列表目录失败: \(error)")
                return nil
            }
            return playlistFileURLOverride
        }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        let fileURL = dir.appendingPathComponent(playlistFileName, isDirectory: false)
        do {
            try DerivedCacheFileIO.ensureParentDirectory(for: fileURL)
        } catch {
            debugLog("创建或验证应用支持目录失败: \(error)")
            return nil
        }
        return fileURL
    }
}

extension Notification.Name {
    static let playlistDidAddFirstFiles = Notification.Name("playlistDidAddFirstFiles")
}

import AVFoundation

// 元数据加载进度跟踪，用于节流 UI 更新
private actor MetadataProgressTracker {
    struct Snapshot {
        let current: Int
        let detail: String
        let total: Int
    }

    private var processed = 0
    private var lastUIUpdate = Date.distantPast

    func recordCompleted(url: URL, total: Int) -> Snapshot? {
        processed += 1
        let current = processed
        let isFinalItem = (current == total)

        // Final item always publishes; others throttle at 0.15s and every 8 items
        let shouldPublish = isFinalItem || (current % 8 == 0 && Date().timeIntervalSince(lastUIUpdate) >= 0.15)

        guard shouldPublish else {
            return nil
        }

        lastUIUpdate = Date()
        return Snapshot(
            current: current,
            detail: url.lastPathComponent,
            total: total
        )
    }
}

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
