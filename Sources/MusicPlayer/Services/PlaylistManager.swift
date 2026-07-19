import Foundation
import Combine

struct QueueRemovalContext {
    let removedFile: AudioFile
    let originalQueueIndex: Int
    let playbackScope: PlaybackScope
    let playlistPosition: Int?
}

final class PlaylistManager: ObservableObject, AudioPlaybackAccessLeaseProviding {
    struct ResolvedPlaylistTrack: Sendable {
        let url: URL
        let offlineReason: String?
    }

    private struct PendingLibraryLocationRefresh: Sendable {
        let baseLocation: LibraryLocation
        let refresh: LibraryBookmarkRefresh
    }
    enum QueuePersistenceProtection: Equatable {
        case future(version: Int)
        case foreignDatabase
        case corrupt(diagnosticURL: URL?)
        case unreadable(message: String)

        var diagnosticMessage: String {
            switch self {
            case .future(let version):
                return "音乐库版本 \(version) 高于当前应用，已保持只读。"
            case .foreignDatabase:
                return "音乐库标识不匹配，已保持只读。"
            case .corrupt:
                return "队列数据已损坏，原始内容已保留为诊断副本。"
            case .unreadable(let message):
                return message
            }
        }

        var canResetQueue: Bool {
            if case .corrupt(let diagnosticURL) = self { return diagnosticURL != nil }
            return false
        }
    }
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

    struct QueueTerminationSnapshotPreparation: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            /// The current immutable queue snapshot was already available.
            case reusedLatest
            /// A current immutable queue snapshot was captured within the budget.
            case prepared
            /// The SQLite queue has no structural debt; only its cursor needs flushing.
            case cursorOnly
            case skippedBeforeRestore
            case protectedReadOnly
            /// Capturing a new snapshot could not safely fit in the remaining budget.
            case timedOut
        }

        let outcome: Outcome
        let generation: UInt64
        let entryCount: Int

        var canAttemptFlush: Bool {
            switch outcome {
            case .reusedLatest, .prepared, .cursorOnly:
                return true
            case .skippedBeforeRestore, .protectedReadOnly, .timedOut:
                return false
            }
        }
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

    @Published var audioFiles: [AudioFile] = [] {
        didSet { playlistSnapshotStateGeneration &+= 1 }
    }
    @Published var currentIndex: Int = 0 {
        didSet {
            playlistSnapshotStateGeneration &+= 1
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
        didSet {
            guard !isRestoringScanSubfoldersPreference else { return }
            saveScanSubfoldersPreference()
        }
    }
    private var isRestoringScanSubfoldersPreference = false
    
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
    @Published private(set) var queuePersistenceProtection: QueuePersistenceProtection?
    private var didPerformInitialRestore: Bool = false
    private var queueLoadGeneration: UInt64 = 0
    private var initialRestoreTask: Task<Void, Never>?
    private var restoredMetadataHydrationTask: Task<Void, Never>?
    private var restoredMetadataHydrationGeneration: UInt64 = 0
    /// Non-nil from the instant the startup session snapshot is captured until
    /// the normalized restore result is merged back. Scope setters must remain
    /// side-effect-free with respect to PlaybackSessionStore in this interval.
    private var playbackSessionRestoreGeneration: UInt64?
    
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
            let id: UUID?
            let path: String
            let signature: FileSignature?
            let locationID: UUID?
            let relativePath: String?

            init(
                id: UUID? = nil,
                path: String,
                signature: FileSignature?,
                locationID: UUID? = nil,
                relativePath: String? = nil
            ) {
                self.id = id
                self.path = path
                self.signature = signature
                self.locationID = locationID
                self.relativePath = relativePath
            }
        }

        struct WeightRekeyRecord: Codable, Equatable {
            let id: UUID
            let oldPath: String
            let newPath: String
            let createdAt: Date

            init(
                id: UUID = UUID(),
                oldPath: String,
                newPath: String,
                createdAt: Date = Date()
            ) {
                self.id = id
                self.oldPath = oldPath
                self.newPath = newPath
                self.createdAt = createdAt
            }

            private enum CodingKeys: String, CodingKey {
                case id, oldPath, newPath, createdAt
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                oldPath = try container.decode(String.self, forKey: .oldPath)
                newPath = try container.decode(String.self, forKey: .newPath)
                id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
                createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
                    ?? Date(timeIntervalSinceReferenceDate: 0)
            }
        }

        let version: Int?
        let storeRevision: UInt64?
        let tracks: [TrackRecord]?
        let paths: [String]
        let currentIndex: Int
        let pendingWeightRekeys: [WeightRekeyRecord]?

        init(
            version: Int?,
            storeRevision: UInt64? = nil,
            tracks: [TrackRecord]?,
            paths: [String],
            currentIndex: Int,
            pendingWeightRekeys: [WeightRekeyRecord]? = nil
        ) {
            self.version = version
            self.storeRevision = storeRevision
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
    private let libraryDatabase: LibraryDatabase?
    private let libraryLocationResolver: LibraryLocationResolver
    private let playlistFileWriter: (Data, URL) throws -> Void
    private let isRunningRegressionTests: Bool
    private let playlistIOQueue = DispatchQueue(label: "playlist.persistence", qos: .utility)
    private let playlistIOQueueKey = DispatchSpecificKey<Void>()
    private let playlistSaveStateLock = NSLock()
    private var playlistSaveRevision: UInt64 = 0
    private var playlistSaveWorkItem: DispatchWorkItem?
    private var pendingPlaylistWrite: (revision: UInt64, snapshot: SavedPlaylist)?
    private var playlistSnapshotStateGeneration: UInt64 = 0
    private var latestCapturedPlaylistSnapshot: (
        stateGeneration: UInt64,
        revision: UInt64,
        snapshot: SavedPlaylist
    )?
    private var terminationSnapshotPreparation: (
        generation: UInt64,
        result: QueueTerminationSnapshotPreparation
    )?
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
    /// Stable occurrence identity aligned one-to-one with `audioFiles`.
    private var queueEntryIDs: [UUID] = []
    private struct QueueLocationReference: Equatable {
        let locationID: UUID
        let relativePath: String?
    }
    /// External-root references aligned one-to-one with `audioFiles`.
    private var queueLocationReferences: [QueueLocationReference?] = []
    private var latestExternalTopologyGeneration: UInt64 = 0
    /// Last structural revision committed to Library.sqlite. Access is protected
    /// by `playlistSaveStateLock` when used off the main thread.
    private var libraryQueueRevision: UInt64 = 0
    private var cursorSaveWorkItem: DispatchWorkItem?
    private var cursorSaveGeneration: UInt64 = 0
    private var cursorDurableGeneration: UInt64 = 0
    private var didNotifyProtectedQueueMutation = false
    private var protectedQueueSourceURL: URL?
    private let metadataGate = ConcurrencyGate(maxConcurrent: 4) // 限制元数据加载并发
    private let durationGate = ConcurrencyGate(maxConcurrent: 2) // 限制时长计算并发（更轻量但也需要控速）
    private let signatureCaptureService: SignatureCaptureService
    private let freshMetadataLoaderOverride: ((URL) async -> AudioMetadata)?

    // MARK: - Playback scope persistence
    let appPreferencesStore: AppPreferencesStore
    let playbackSessionStore: PlaybackSessionStore?
    private let legacyUserDefaults: UserDefaults
    /// The process-wide weight store injected by the composition root.
    /// Views, commands and IPC must use this exact instance so production
    /// never splits state between Library.sqlite and the legacy singleton.
    let playbackWeights: PlaybackWeights
    private let playbackStateRekeyHandler: ((URL, URL) -> PlaybackStateStore.RekeyResult)?

    @MainActor private var durationPrefetchTask: Task<Void, Never>?
    @MainActor private var pendingDurationURLs: [URL] = []
    @MainActor private var pendingDurationURLKeys: Set<String> = []
    @MainActor private var pendingDurationIndex: Int = 0

    init(
        playlistFileURLOverride: URL? = nil,
        libraryDatabase: LibraryDatabase? = nil,
        libraryLocationResolver: LibraryLocationResolver = LibraryLocationResolver(),
        disablePersistence: Bool = false,
        persistenceDebounceInterval: TimeInterval = 0.4,
        signatureCaptureService: SignatureCaptureService? = nil,
        initialQueueLoadState: QueueLoadState? = nil,
        appPreferencesStore: AppPreferencesStore = .shared,
        legacyUserDefaults: UserDefaults? = nil,
        playbackSessionStore: PlaybackSessionStore? = nil,
        playbackWeights: PlaybackWeights = .shared,
        playbackStateRekeyHandler: ((URL, URL) -> PlaybackStateStore.RekeyResult)? = nil,
        freshMetadataLoaderOverride: ((URL) async -> AudioMetadata)? = nil,
        playlistFileWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.playlistFileURLOverride = playlistFileURLOverride
        self.libraryDatabase = libraryDatabase
        self.libraryLocationResolver = libraryLocationResolver
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
        self.legacyUserDefaults = legacyUserDefaults ?? .standard
        self.playbackSessionStore = playbackSessionStore
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

    var currentPlaybackPlaylistTrackID: String? {
        guard case .playlist = playbackScope,
              let key = currentPlaybackPlaylistOccurrenceKey,
              key.hasPrefix("id:") else { return nil }
        let raw = String(key.dropFirst(3))
        return raw.split(separator: "#", maxSplits: 1).first.map(String.init)
    }

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
            setPlaybackScopePlaylist(
                playlistID,
                trackURLsInOrder: [],
                trackIDsInOrder: []
            )
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
        guard playbackSessionRestoreGeneration == nil,
              !isRunningRegressionTests,
              let playbackSessionStore else { return }
        let storedScope: PlaybackSessionStore.Scope
        switch scope {
        case .queue:
            storedScope = .queue
        case .playlist(let id):
            storedScope = .playlist(id)
        }
        _ = playbackSessionStore.mergeScope(storedScope)
        if audioFiles.indices.contains(currentIndex) {
            _ = playbackSessionStore.mergeInstalledTrack(
                playbackSessionTrackIdentity(for: audioFiles[currentIndex].url)
            )
        }
    }

    /// Restore last used playback scope (queue vs a specific user playlist).
    ///
    /// - Important: Call this after the queue (`audioFiles`) has been restored, otherwise playlist-scope
    ///   playback won't be able to map tracks to queue indices.
    func restorePlaybackScopeIfNeeded(playlistsStore: PlaylistsStore) async {
        await restorePlaybackScopeIfNeeded(
            playlistsStore: playlistsStore,
            sessionSnapshot: playbackSessionStore?.snapshot
        )
    }

    private func restorePlaybackScopeIfNeeded(
        playlistsStore: PlaylistsStore,
        sessionSnapshot: PlaybackSessionStore.Snapshot?
    ) async {
        let persistedScope: PlaybackScope
        switch sessionSnapshot?.scope ?? .queue {
        case .queue:
            persistedScope = .queue
        case .playlist(let id):
            persistedScope = .playlist(id)
        }
        switch persistedScope {
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
            let resolvedTracks = await resolvePlaylistTrackLocations(playlist.tracks)
            let playableIndices = playlist.tracks.indices.filter { index in
                resolvedTracks.indices.contains(index)
                    && resolvedTracks[index].offlineReason == nil
                    && fm.fileExists(atPath: resolvedTracks[index].url.path)
            }
            let playableTracks = playableIndices.map { playlist.tracks[$0] }
            let urlsInOrder = playableIndices.map { resolvedTracks[$0].url }

            if urlsInOrder.isEmpty {
                await MainActor.run { [weak self] in
                    self?.setPlaybackScopeQueue()
                }
                return
            }

            // Extract signatures from playlist tracks
            var signatures: [String: FileSignature] = [:]
            for (index, track) in playlist.tracks.enumerated() {
                if let sig = track.signature {
                    let path = resolvedTracks.indices.contains(index)
                        ? resolvedTracks[index].url.path
                        : track.path
                    signatures[path] = sig
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
            let storedTracksByResolvedPath = Dictionary(
                playableIndices.map { index in
                    (resolvedTracks[index].url.path, playlist.tracks[index])
                },
                uniquingKeysWith: { first, _ in first }
            )
            if !filesToAppend.isEmpty {
                await MainActor.run { [weak self] in
                    _ = self?.ensureInQueue(
                        filesToAppend,
                        focusURL: nil,
                        signatures: signaturesSnapshot,
                        storedTracksByResolvedPath: storedTracksByResolvedPath
                    )
                }
            }

            await MainActor.run { [weak self] in
                self?.setPlaybackScopePlaylist(
                    playlistID,
                    trackURLsInOrder: urlsInOrder,
                    trackIDsInOrder: playableTracks.map { $0.id.uuidString },
                    selectedTrackID: sessionSnapshot?.installedTrack.scopeTrackID?.uuidString
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
        // Capture exactly once before detached restore work starts. Every scope,
        // identity and position decision below is derived from this value.
        let frozenSessionSnapshot = playbackSessionStore?.snapshot
        if frozenSessionSnapshot != nil {
            playbackSessionRestoreGeneration = generation
        }
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

            await self.restorePlaybackScopeIfNeeded(
                playlistsStore: playlistsStore,
                sessionSnapshot: frozenSessionSnapshot
            )
            guard !Task.isCancelled else {
                await self.finishCancelledInitialRestore(generation: generation)
                return
            }

            await MainActor.run {
                guard !self.isTerminating, self.queueLoadGeneration == generation else { return }
                // A Finder/Dock open suppresses only last-playback restoration.
                // The persisted queue must still load so a temporary session can
                // never replace it with an empty in-memory placeholder.
                let skipPlaybackRestore = audioPlayer.consumeSkipRestoreThisLaunch()
                var restoredURL: URL?
                if !skipPlaybackRestore, audioPlayer.currentFile == nil {
                    if let session = frozenSessionSnapshot {
                        self.ensureQueueEntryIDAlignment()
                        restoredURL = self.restoredPlaybackURL(from: session)
                        if let restoredURL {
                            audioPlayer.loadPlaybackSession(
                                fileURL: restoredURL,
                                time: Double(session.positionMilliseconds) / 1_000
                            )
                        }
                    } else {
                        audioPlayer.loadLastPlayedFile()
                    }
                }
                if let session = frozenSessionSnapshot {
                    // Resolve even when a Finder/Dock launch suppresses playback;
                    // normalization must still use the same frozen identity.
                    restoredURL = restoredURL ?? self.restoredPlaybackURL(from: session)
                    self.finishPlaybackSessionRestore(
                        generation: generation,
                        frozenSnapshot: session,
                        restoredURL: restoredURL
                    )
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
            guard let self else { return }
            if self.playbackSessionRestoreGeneration == generation {
                self.playbackSessionRestoreGeneration = nil
            }
            guard self.queueLoadState == .loading(generation: generation) else { return }
            self.isInitialRestorePending = false
            self.initialRestoreTask = nil
            self.transitionQueueLoadState(.notStarted)
        }
    }

    @MainActor
    private func restoredPlaybackURL(
        from snapshot: PlaybackSessionStore.Snapshot
    ) -> URL? {
        if case .playlist = playbackScope,
           let scopeTrackID = snapshot.installedTrack.scopeTrackID {
            let occurrencePrefix = "id:\(scopeTrackID.uuidString)"
            if let occurrence = playbackPlaylistTrackKeys.first(where: {
                $0 == occurrencePrefix || $0.hasPrefix("\(occurrencePrefix)#")
            }),
               let key = pathKeyForPlaylistOccurrence(occurrence),
               let index = indexInQueue(forPathKey: key),
               audioFiles.indices.contains(index) {
                return audioFiles[index].url
            }
        }
        return snapshot.installedTrack.queueEntryID
            .flatMap { queueEntryIDs.firstIndex(of: $0) }
            .flatMap { audioFiles.indices.contains($0) ? audioFiles[$0].url : nil }
            ?? snapshot.installedTrack.fallbackPath.flatMap { fallback in
                let key = PathKey.canonical(path: fallback)
                return audioFiles.first { pathKey($0.url) == key }?.url
            }
    }

    /// Final restore publication is deliberately concentrated in one MainActor
    /// turn. PlaybackSessionStore cancels/debounces each intermediate revision,
    /// so these three merges converge on one final persisted snapshot; this is
    /// the current atomicity boundary until the store exposes a whole-session merge.
    @MainActor
    private func finishPlaybackSessionRestore(
        generation: UInt64,
        frozenSnapshot: PlaybackSessionStore.Snapshot,
        restoredURL: URL?
    ) {
        guard playbackSessionRestoreGeneration == generation,
              let playbackSessionStore else { return }
        playbackSessionRestoreGeneration = nil

        let normalizedScope: PlaybackSessionStore.Scope
        switch playbackScope {
        case .queue: normalizedScope = .queue
        case .playlist(let id): normalizedScope = .playlist(id)
        }
        let normalizedURL = restoredURL
            ?? (audioFiles.indices.contains(currentIndex) ? audioFiles[currentIndex].url : nil)
        let normalizedTrack = normalizedURL.map(playbackSessionTrackIdentity(for:)) ?? .empty
        let normalizedPosition = restoredURL == nil ? 0 : frozenSnapshot.positionMilliseconds
        _ = playbackSessionStore.mergeScope(normalizedScope)
        _ = playbackSessionStore.mergeInstalledTrack(normalizedTrack)
        _ = playbackSessionStore.mergePosition(milliseconds: normalizedPosition)
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
    func prepareForImmediateTermination(generation: UInt64? = nil) {
        // Termination is one-way. Repeated callbacks for the same AppKit quit
        // request must not advance queue generations or restart cancellation.
        guard !isTerminating else { return }
        let wasReady: Bool
        switch queueLoadState {
        case .ready, .terminating(wasReady: true):
            wasReady = true
        case .notStarted, .loading, .terminating(wasReady: false):
            wasReady = false
        }
        isTerminating = true
        playbackSessionRestoreGeneration = nil
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

    /// Captures (or reuses) the immutable structural queue snapshot consumed by
    /// the termination flush. The estimate is intentionally conservative: for a
    /// large queue with too little budget, returning `.timedOut` is preferable to
    /// beginning an unbounded O(n log n) build on AppKit's synchronous quit path.
    @MainActor
    func prepareTerminationQueueSnapshot(
        remaining: TimeInterval,
        generation: UInt64
    ) -> QueueTerminationSnapshotPreparation {
        playlistSaveStateLock.lock()
        if let cached = terminationSnapshotPreparation,
           cached.generation == generation {
            playlistSaveStateLock.unlock()
            return cached.result
        }
        let entryCount = audioFiles.count + retainedMissingWithOriginalIndex.count
        let readOnly = isPlaylistPersistenceReadOnly
        let canBuild = canBuildPlaylistPersistenceSnapshot
        let hasStructuralDebt = playlistSaveRevision > playlistDurableRevision
            || playlistSaveWorkItem != nil
            || pendingPlaylistWrite != nil
            || isPlaylistWriteDrainScheduled
        let currentStateGeneration = playlistSnapshotStateGeneration
        let reusable = latestCapturedPlaylistSnapshot.flatMap {
            $0.stateGeneration == currentStateGeneration ? $0 : nil
        }
        playlistSaveStateLock.unlock()

        let outcome: QueueTerminationSnapshotPreparation.Outcome
        if readOnly {
            outcome = .protectedReadOnly
        } else if !canBuild {
            outcome = .skippedBeforeRestore
        } else if libraryDatabase != nil, !hasStructuralDebt {
            outcome = .cursorOnly
        } else if reusable != nil {
            outcome = .reusedLatest
        } else {
            let budget = remaining.isFinite ? max(0, remaining) : 0
            // Includes alignment, record allocation and final sorting. At the
            // hard 100k cap this reserves roughly half a second for capture.
            let estimatedCaptureSeconds = 0.004 + (Double(entryCount) * 0.000_005)
            guard budget >= estimatedCaptureSeconds else {
                let result = QueueTerminationSnapshotPreparation(
                    outcome: .timedOut,
                    generation: generation,
                    entryCount: entryCount
                )
                playlistSaveStateLock.lock()
                terminationSnapshotPreparation = (generation, result)
                playlistSaveStateLock.unlock()
                return result
            }

            let startedAt = ProcessInfo.processInfo.systemUptime
            let snapshot = buildPlaylistSnapshot()
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            guard elapsed <= budget else {
                outcome = .timedOut
                let result = QueueTerminationSnapshotPreparation(
                    outcome: outcome,
                    generation: generation,
                    entryCount: entryCount
                )
                playlistSaveStateLock.lock()
                terminationSnapshotPreparation = (generation, result)
                playlistSaveStateLock.unlock()
                return result
            }
            playlistSaveStateLock.lock()
            latestCapturedPlaylistSnapshot = (
                currentStateGeneration,
                playlistSaveRevision,
                snapshot
            )
            playlistSaveStateLock.unlock()
            outcome = .prepared
        }

        let result = QueueTerminationSnapshotPreparation(
            outcome: outcome,
            generation: generation,
            entryCount: entryCount
        )
        playlistSaveStateLock.lock()
        terminationSnapshotPreparation = (generation, result)
        playlistSaveStateLock.unlock()
        return result
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
        addingRekeys: [SavedPlaylist.WeightRekeyRecord] = [],
        signatureOverrides: [String: FileSignature] = [:],
        locationOverrides: [Int: QueueLocationReference] = [:],
        addingLocationReferences: [QueueLocationReference?] = []
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

        for (index, file) in audioFiles.enumerated() {
            guard consumeString(file.url.path, requiresAbsolutePath: true),
                  consumeSignature(
                    signatureOverrides[file.url.path] ?? loadedSignatureByPath[file.url.path]
                  ) else { return false }
            let location = locationOverrides[index]
                ?? (queueLocationReferences.indices.contains(index)
                    ? queueLocationReferences[index]
                    : nil)
            if let relativePath = location?.relativePath {
                guard (try? LibraryRelativePath.validate(
                    relativePath,
                    allowEmpty: false
                )) != nil,
                consumeString(relativePath, requiresAbsolutePath: false) else { return false }
            }
        }
        for (index, missing) in retainedMissingWithOriginalIndex.enumerated()
        where !removingMissingIndices.contains(index) {
            guard consumeString(missing.record.path, requiresAbsolutePath: true),
                  consumeSignature(missing.record.signature) else { return false }
        }
        for (index, addition) in addingFiles.enumerated() {
            guard consumeString(addition.file.url.path, requiresAbsolutePath: true),
                  consumeSignature(addition.signature) else { return false }
            if addingLocationReferences.indices.contains(index),
               let relativePath = addingLocationReferences[index]?.relativePath {
                guard (try? LibraryRelativePath.validate(
                    relativePath,
                    allowEmpty: false
                )) != nil,
                consumeString(relativePath, requiresAbsolutePath: false) else { return false }
            }
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

        // Persist one bookmark per user-selected root (or explicit single
        // file), then attach only compact relative references to queue rows.
        // A mounted-volume rename can therefore be repaired without scanning.
        let importLocations = await registerImportLocations(for: urls)
        var importedReferenceByPath: [String: QueueLocationReference] = [:]
        if !importLocations.isEmpty {
            let orderedLocations = importLocations.sorted {
                $0.fallbackPath.count > $1.fallbackPath.count
            }
            for fileURL in fileURLs {
                for location in orderedLocations {
                    if let reference = try? await libraryLocationResolver.makeReference(
                        for: fileURL,
                        in: location
                    ) {
                        importedReferenceByPath[fileURL.path] = QueueLocationReference(
                            locationID: reference.locationID ?? location.id,
                            relativePath: reference.relativePath
                        )
                        break
                    }
                }
            }
        }
        let importReferencesSnapshot = importedReferenceByPath

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

            self.ensureQueueEntryIDAlignment()
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
                entryID: UUID,
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
                    entryID: missing.record.id ?? UUID(),
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
                    let entryID: UUID
                    let locationReference: QueueLocationReference?
                    let originalIndex: Int?
                    let ordinal: Int
                }
                while self.fullOrderIndexForAudioFile.count < self.audioFiles.count {
                    self.fullOrderIndexForAudioFile.append(nil)
                }
                var ordered = self.audioFiles.enumerated().map { runtimeIndex, file in
                    OrderedRuntimeEntry(
                        file: file,
                        entryID: self.queueEntryIDs[runtimeIndex],
                        locationReference: self.queueLocationReferences.indices.contains(runtimeIndex)
                            ? self.queueLocationReferences[runtimeIndex]
                            : nil,
                        originalIndex: self.fullOrderIndexForAudioFile[runtimeIndex],
                        ordinal: runtimeIndex
                    )
                }
                ordered.append(contentsOf: relocatedAdditions.enumerated().map { offset, item in
                    OrderedRuntimeEntry(
                        file: item.file,
                        entryID: item.entryID,
                        locationReference: nil,
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
                self.queueEntryIDs = ordered.map(\.entryID)
                self.queueLocationReferences = ordered.map(\.locationReference)
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
            self.queueEntryIDs.append(contentsOf: toAppend.map { _ in UUID() })
            self.queueLocationReferences.append(contentsOf: toAppend.map {
                importReferencesSnapshot[$0.file.url.path]
            })
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

    private func registerImportLocations(for selectedURLs: [URL]) async -> [LibraryLocation] {
        guard let libraryDatabase, libraryDatabase.accessMode == .writable else { return [] }

        var existingByIdentity: [String: LibraryLocation] = [:]
        do {
            _ = try libraryDatabase.forEachLibraryLocation { record in
                let key = "\(record.location.kind.rawValue)\u{0}\(record.location.fallbackPath)"
                existingByIdentity[key] = record.location
                return true
            }
        } catch {
            PersistenceLogger.log("读取已授权音乐位置失败：\(error.localizedDescription)")
            return []
        }

        var locations: [LibraryLocation] = []
        var seen = Set<String>()
        for suppliedURL in selectedURLs {
            guard !Task.isCancelled else { return locations }
            let url = suppliedURL.standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let kind: LibraryLocationKind
            if values?.isDirectory == true {
                kind = .directory
            } else if values?.isRegularFile == true {
                kind = .singleFile
            } else {
                continue
            }
            let identity = "\(kind.rawValue)\u{0}\(url.path)"
            guard seen.insert(identity).inserted else { continue }

            let location: LibraryLocation
            do {
                location = try await libraryLocationResolver.makeLocation(
                    for: url,
                    kind: kind,
                    id: existingByIdentity[identity]?.id ?? UUID()
                )
            } catch {
                PersistenceLogger.log("无法保存音乐位置 \(url.lastPathComponent)：\(error.localizedDescription)")
                continue
            }

            var stored = false
            for _ in 0..<3 {
                do {
                    let revision = try libraryDatabase.libraryLocationsRevision()
                    stored = try libraryDatabase.upsertLibraryLocation(
                        LibraryLocationRecord(location: location, updatedAt: Date()),
                        expectedRevision: revision,
                        nextRevision: revision &+ 1
                    )
                    if stored { break }
                } catch {
                    PersistenceLogger.log("保存音乐位置失败：\(error.localizedDescription)")
                    break
                }
            }
            if stored {
                locations.append(location)
                existingByIdentity[identity] = location
            }
        }
        return locations
    }

    /// Re-resolves only tracks backed by a persisted location. Offline rows
    /// stay in the queue with their stable occurrence IDs, and reconnecting a
    /// volume updates paths in place rather than scanning the disk.
    func refreshExternalMediaAvailability(
        playlistsStore: PlaylistsStore? = nil,
        topologyGeneration: UInt64? = nil
    ) async {
        guard libraryDatabase != nil else { return }
        let acceptedGeneration = await MainActor.run { () -> UInt64? in
            let generation = topologyGeneration
                ?? (self.latestExternalTopologyGeneration &+ 1)
            guard generation > self.latestExternalTopologyGeneration else { return nil }
            self.latestExternalTopologyGeneration = generation
            return generation
        }
        guard let acceptedGeneration else { return }
        let locations = await loadLibraryLocationsOffMain()

        struct Candidate: @unchecked Sendable {
            let index: Int
            let entryID: UUID
            let file: AudioFile
            let reference: LibraryTrackReference
        }
        let candidates: [Candidate] = await MainActor.run {
            self.ensureQueueEntryIDAlignment()
            return self.audioFiles.indices.compactMap { index in
                guard let stored = self.queueLocationReferences[index],
                      let reference = try? LibraryTrackReference(
                          id: self.queueEntryIDs[index],
                          locationID: stored.locationID,
                          relativePath: stored.relativePath,
                          legacyAbsolutePath: self.audioFiles[index].url.path,
                          signature: self.loadedSignatureByPath[self.audioFiles[index].url.path]
                      ) else { return nil }
                return Candidate(
                    index: index,
                    entryID: self.queueEntryIDs[index],
                    file: self.audioFiles[index],
                    reference: reference
                )
            }
        }
        struct ResolutionUpdate: @unchecked Sendable {
            let candidate: Candidate
            let availability: LibraryLocationAvailability
        }
        var updates: [ResolutionUpdate] = []
        updates.reserveCapacity(candidates.count)
        var refreshedLocations: [UUID: PendingLibraryLocationRefresh] = [:]
        for start in stride(from: 0, to: candidates.count, by: 256) {
            guard !Task.isCancelled else { return }
            for candidate in candidates[start..<min(start + 256, candidates.count)] {
                guard let location = locations[candidate.reference.locationID ?? UUID()] else {
                    updates.append(ResolutionUpdate(
                        candidate: candidate,
                        availability: .invalidReference("保存的音乐位置不存在")
                    ))
                    continue
                }
                let resolution = await libraryLocationResolver.resolve(
                    candidate.reference,
                    in: location
                )
                updates.append(ResolutionUpdate(
                    candidate: candidate,
                    availability: resolution.availability
                ))
                if let refresh = resolution.bookmarkRefresh {
                    refreshedLocations[location.id] = PendingLibraryLocationRefresh(
                        baseLocation: location,
                        refresh: refresh
                    )
                }
            }
            await Task.yield()
        }

        for pendingRefresh in refreshedLocations.values {
            _ = await persistLibraryLocationRefresh(pendingRefresh)
        }

        let updatesSnapshot = updates
        let applyResult = await MainActor.run { () -> (didChange: Bool, hydratedURLs: [URL]) in
            var changed = false
            var hydratedURLs: [URL] = []
            guard self.latestExternalTopologyGeneration == acceptedGeneration else {
                return (false, [])
            }
            for update in updatesSnapshot {
                guard let index = self.queueEntryIDs.firstIndex(
                    of: update.candidate.entryID
                ), self.audioFiles.indices.contains(index),
                self.pathKey(self.audioFiles[index].url)
                    == self.pathKey(update.candidate.file.url) else { continue }
                let oldFile = self.audioFiles[index]
                switch update.availability {
                case .available(let resolvedURL):
                    let oldKey = self.pathKey(oldFile.url)
                    let newKey = self.pathKey(resolvedURL)
                    if oldKey != newKey {
                        self.audioFiles[index] = AudioFile(
                            id: oldFile.id,
                            url: resolvedURL,
                            metadata: oldFile.metadata,
                            lyricsTimeline: oldFile.lyricsTimeline,
                            duration: oldFile.duration
                        )
                        if let signature = self.loadedSignatureByPath.removeValue(
                            forKey: oldFile.url.path
                        ) {
                            self.loadedSignatureByPath[resolvedURL.path] = signature
                        }
                        changed = true
                    }
                    if self.unplayableReasons.removeValue(forKey: oldKey) != nil {
                        changed = true
                        hydratedURLs.append(resolvedURL)
                    }
                    self.unplayableReasons.removeValue(forKey: newKey)
                default:
                    let reason = Self.externalAvailabilityMessage(update.availability)
                    let key = self.pathKey(oldFile.url)
                    if self.unplayableReasons[key] != reason {
                        self.unplayableReasons[key] = reason
                        changed = true
                    }
                }
            }
            if changed {
                self.invalidateQueueIndexCache()
                self.updateFilteredFiles()
                self.resetShuffleQueue()
                self.savePlaylist()
            }
            return (changed, hydratedURLs)
        }
        if applyResult.didChange, !applyResult.hydratedURLs.isEmpty {
            await hydrateRestoredMetadata(
                urls: applyResult.hydratedURLs,
                audioPlayer: nil
            )
        }
        if let playlistsStore {
            await refreshActivePlaylistScopeAfterTopologyChange(
                playlistsStore: playlistsStore,
                topologyGeneration: acceptedGeneration
            )
        }
        await MainActor.run {
            guard self.latestExternalTopologyGeneration == acceptedGeneration else { return }
            NotificationCenter.default.post(
                name: .externalMediaTopologyDidChange,
                object: self,
                userInfo: ["generation": acceptedGeneration]
            )
        }
    }

    private func refreshActivePlaylistScopeAfterTopologyChange(
        playlistsStore: PlaylistsStore,
        topologyGeneration: UInt64
    ) async {
        let playlist: UserPlaylist? = await MainActor.run {
            guard self.latestExternalTopologyGeneration == topologyGeneration,
                  case .playlist(let playlistID) = self.playbackScope else { return nil }
            return playlistsStore.playlist(for: playlistID)
        }
        guard let playlist else { return }
        let resolved = await resolvePlaylistTrackLocations(playlist.tracks)
        guard resolved.count == playlist.tracks.count else { return }

        await MainActor.run {
            guard self.latestExternalTopologyGeneration == topologyGeneration,
                  case .playlist(let activeID) = self.playbackScope,
                  activeID == playlist.id else { return }
            let playableIndices = playlist.tracks.indices.filter {
                resolved[$0].offlineReason == nil
                    && FileManager.default.fileExists(atPath: resolved[$0].url.path)
            }
            let urls = playableIndices.map { resolved[$0].url }
            let files = playableIndices.map { index -> AudioFile in
                let url = resolved[index].url
                if let existing = self.audioFiles.first(where: {
                    self.pathKey($0.url) == self.pathKey(url)
                }) {
                    return existing
                }
                return AudioFile(
                    id: playlist.tracks[index].id.uuidString,
                    url: url,
                    metadata: AudioMetadata(
                        title: url.deletingPathExtension().lastPathComponent,
                        artist: "未知艺术家",
                        album: "未知专辑",
                        year: nil,
                        genre: nil,
                        artwork: nil
                    )
                )
            }
            let storedByPath = Dictionary(
                playableIndices.map {
                    (resolved[$0].url.path, playlist.tracks[$0])
                },
                uniquingKeysWith: { first, _ in first }
            )
            let signatures = Dictionary(
                playableIndices.compactMap { index in
                    playlist.tracks[index].signature.map {
                        (resolved[index].url.path, $0)
                    }
                },
                uniquingKeysWith: { first, _ in first }
            )
            if !files.isEmpty {
                _ = self.ensureInQueue(
                    files,
                    signatures: signatures,
                    storedTracksByResolvedPath: storedByPath
                )
            }
            self.setPlaybackScopePlaylist(
                playlist.id,
                trackURLsInOrder: urls,
                trackIDsInOrder: playableIndices.map {
                    playlist.tracks[$0].id.uuidString
                }
            )
        }
    }

    func resolvePlaylistTrackLocations(
        _ tracks: [UserPlaylist.Track]
    ) async -> [ResolvedPlaylistTrack] {
        let locations = await loadLibraryLocationsOffMain()
        var output: [ResolvedPlaylistTrack] = []
        output.reserveCapacity(tracks.count)
        var refreshedLocations: [UUID: PendingLibraryLocationRefresh] = [:]
        for start in stride(from: 0, to: tracks.count, by: 256) {
            guard !Task.isCancelled else { return output }
            for track in tracks[start..<min(start + 256, tracks.count)] {
                let fallback = URL(fileURLWithPath: track.path)
                guard let locationID = track.locationID else {
                    output.append(ResolvedPlaylistTrack(url: fallback, offlineReason: nil))
                    continue
                }
                guard let location = locations[locationID],
                      let reference = try? LibraryTrackReference(
                          id: track.id,
                          locationID: locationID,
                          relativePath: track.relativePath,
                          legacyAbsolutePath: track.path,
                          signature: track.signature
                      ) else {
                    output.append(ResolvedPlaylistTrack(
                        url: fallback,
                        offlineReason: "保存的音乐位置引用无效"
                    ))
                    continue
                }
                let resolution = await libraryLocationResolver.resolve(reference, in: location)
                switch resolution.availability {
                case .available(let url):
                    output.append(ResolvedPlaylistTrack(url: url, offlineReason: nil))
                default:
                    output.append(ResolvedPlaylistTrack(
                        url: fallback,
                        offlineReason: Self.externalAvailabilityMessage(
                            resolution.availability
                        )
                    ))
                }
                if let refresh = resolution.bookmarkRefresh {
                    refreshedLocations[location.id] = PendingLibraryLocationRefresh(
                        baseLocation: location,
                        refresh: refresh
                    )
                }
            }
            await Task.yield()
        }
        for pendingRefresh in refreshedLocations.values {
            _ = await persistLibraryLocationRefresh(pendingRefresh)
        }
        return output
    }

    /// Invalidates resolver leases before an external volume disappears and
    /// marks matching rows offline immediately. Returns whether the installed
    /// queue selection belongs to that volume so the caller can pause audio.
    func handleExternalVolumeWillUnmount(_ volume: MountedLibraryVolume?) async -> Bool {
        guard let volume else { return false }
        let locations = await loadLibraryLocationsOffMain()
        let affectedLocationIDs = Set(locations.values.compactMap { location -> UUID? in
            if let expected = location.volumeIdentifier,
               let actual = volume.identifier {
                return expected == actual ? location.id : nil
            }
            let root = location.fallbackURL.standardizedFileURL.path
            let mounted = volume.url.standardizedFileURL.path
            return root == mounted || root.hasPrefix(mounted + "/") ? location.id : nil
        })
        guard !affectedLocationIDs.isEmpty else { return false }
        for id in affectedLocationIDs {
            await libraryLocationResolver.invalidateActiveResolution(for: id)
        }
        return await MainActor.run {
            self.ensureQueueEntryIDAlignment()
            var currentIsAffected = false
            for index in self.audioFiles.indices {
                guard let reference = self.queueLocationReferences[index],
                      affectedLocationIDs.contains(reference.locationID) else { continue }
                self.unplayableReasons[self.pathKey(self.audioFiles[index].url)] =
                    "所在磁盘正在断开"
                if index == self.currentIndex { currentIsAffected = true }
            }
            if !affectedLocationIDs.isEmpty {
                self.resetShuffleQueue()
            }
            return currentIsAffected
        }
    }

    private func loadLibraryLocationsOffMain() async -> [UUID: LibraryLocation] {
        guard let libraryDatabase else { return [:] }
        return await Task.detached(priority: .utility) {
            var result: [UUID: LibraryLocation] = [:]
            do {
                _ = try libraryDatabase.forEachLibraryLocation { record in
                    result[record.location.id] = record.location
                    return true
                }
            } catch {
                PersistenceLogger.log("读取音乐位置失败：\(error.localizedDescription)")
            }
            return result
        }.value
    }

    func playbackAccessRequest(for file: AudioFile) -> AudioPlaybackAccessRequest? {
        let lookup = { () -> AudioPlaybackAccessRequest? in
            self.ensureQueueEntryIDAlignment()
            let key = self.pathKey(file.url)
            let index: Int?
            if self.audioFiles.indices.contains(self.currentIndex),
               self.pathKey(self.audioFiles[self.currentIndex].url) == key {
                index = self.currentIndex
            } else {
                index = self.indexInQueue(forPathKey: key)
            }
            guard let index,
                  self.queueEntryIDs.indices.contains(index),
                  self.queueLocationReferences.indices.contains(index),
                  let stored = self.queueLocationReferences[index] else { return nil }
            return AudioPlaybackAccessRequest(
                referenceID: self.queueEntryIDs[index],
                locationID: stored.locationID,
                relativePath: stored.relativePath,
                legacyAbsolutePath: file.url.path
            )
        }
        if Thread.isMainThread { return lookup() }
        return DispatchQueue.main.sync(execute: lookup)
    }

    func acquirePlaybackAccessLease(
        for request: AudioPlaybackAccessRequest
    ) async throws -> any AudioPlaybackAccessLease {
        guard let libraryDatabase else {
            throw LibraryLocationResolverError.unavailable(
                .invalidReference("音乐库位置存储不可用")
            )
        }
        let record = try await Task.detached(priority: .userInitiated) {
            try libraryDatabase.loadLibraryLocation(id: request.locationID)
        }.value
        guard let location = record?.location else {
            throw LibraryLocationResolverError.unavailable(
                .invalidReference("保存的音乐位置不存在")
            )
        }
        let reference = try LibraryTrackReference(
            id: request.referenceID,
            locationID: request.locationID,
            relativePath: request.relativePath,
            legacyAbsolutePath: request.legacyAbsolutePath,
            signature: nil
        )
        let lease = try await libraryLocationResolver.acquireAccess(
            to: reference,
            in: location
        )
        if let refresh = lease.bookmarkRefresh {
            _ = await persistLibraryLocationRefresh(
                PendingLibraryLocationRefresh(
                    baseLocation: location,
                    refresh: refresh
                )
            )
        }
        return lease
    }

    @discardableResult
    private func persistLibraryLocationRefresh(
        _ pending: PendingLibraryLocationRefresh
    ) async -> Bool {
        guard let libraryDatabase, libraryDatabase.accessMode == .writable else { return false }
        return await Task.detached(priority: .utility) {
            let desired: LibraryLocation
            do {
                desired = try pending.baseLocation.applying(pending.refresh)
            } catch {
                return false
            }

            for _ in 0..<3 {
                do {
                    let revision = try libraryDatabase.libraryLocationsRevision()
                    guard let current = try libraryDatabase.loadLibraryLocation(
                        id: pending.baseLocation.id
                    ) else { return false }
                    if current.location == desired { return true }
                    guard current.location == pending.baseLocation else { return false }
                    let refreshed = try current.location.applying(pending.refresh)
                    if try libraryDatabase.upsertLibraryLocation(
                        LibraryLocationRecord(location: refreshed, updatedAt: Date()),
                        expectedRevision: revision,
                        nextRevision: revision &+ 1
                    ) {
                        return true
                    }
                } catch {
                    PersistenceLogger.log("刷新音乐位置书签失败：\(error.localizedDescription)")
                    return false
                }
            }
            return false
        }.value
    }

    private static func externalAvailabilityMessage(
        _ availability: LibraryLocationAvailability
    ) -> String {
        switch availability {
        case .available:
            return ""
        case .volumeUnavailable:
            return "所在磁盘当前未连接"
        case .authorizationRequired:
            return "需要重新授权此音乐位置"
        case .rootMissing:
            return "保存的音乐根目录已移动"
        case .fileMissing:
            return "歌曲在音乐位置中不存在"
        case .invalidReference(let detail), .indeterminate(let detail):
            return detail
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

        struct RefreshIdentity: Hashable, Sendable {
            let queueEntryID: UUID
            let pathKey: String
        }
        struct RefreshCandidate: @unchecked Sendable {
            let identity: RefreshIdentity
            let file: AudioFile
        }
        let candidates: [RefreshCandidate] = await MainActor.run {
            self.ensureQueueEntryIDAlignment()
            return self.audioFiles.indices.map { index in
                RefreshCandidate(
                    identity: RefreshIdentity(
                        queueEntryID: self.queueEntryIDs[index],
                        pathKey: self.pathKey(self.audioFiles[index].url)
                    ),
                    file: self.audioFiles[index]
                )
            }
        }
        let completedRefreshes = await BoundedWorkerPool.map(
            items: candidates,
            maxConcurrent: Self.maximumConcurrentMetadataRefreshTasks
        ) { [weak self] candidate -> (RefreshIdentity, AudioMetadata)? in
            guard let self, !Task.isCancelled else { return nil }
            let file = candidate.file
            let newMetadata = await self.loadFreshMetadata(from: file.url)
            guard !Task.isCancelled else { return nil }
            await MetadataCache.shared.storeBasicMetadata(newMetadata, for: file.url)
            return (candidate.identity, newMetadata)
        }
        var metadataByIdentity: [RefreshIdentity: AudioMetadata] = [:]
        metadataByIdentity.reserveCapacity(completedRefreshes.count)
        for case let (identity, metadata)? in completedRefreshes {
            metadataByIdentity[identity] = metadata
        }
        let metadataSnapshot = metadataByIdentity

        await MainActor.run {
            self.ensureQueueEntryIDAlignment()
            for index in self.audioFiles.indices {
                let identity = RefreshIdentity(
                    queueEntryID: self.queueEntryIDs[index],
                    pathKey: self.pathKey(self.audioFiles[index].url)
                )
                guard let metadata = metadataSnapshot[identity] else { continue }
                let current = self.audioFiles[index]
                self.audioFiles[index] = AudioFile(
                    id: current.id,
                    url: current.url,
                    metadata: metadata,
                    lyricsTimeline: nil,
                    duration: current.duration
                )
            }
            self.updateFilteredFiles()

            // 如果有正在播放的文件，更新AudioPlayer中的引用
            if let currentURL = currentFileURL,
                let audioPlayer = audioPlayer,
               audioPlayer.currentFile?.url == currentURL,
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
        if let currentURL = currentFileURL,
           let audioPlayer = audioPlayer,
           await MainActor.run(body: { audioPlayer.currentFile?.url == currentURL }) {
            let result = await LyricsService.shared.loadLyrics(for: currentURL)
            await MainActor.run {
                guard audioPlayer.currentFile?.url == currentURL else { return }
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
        ensureQueueEntryIDAlignment()
        audioFiles.remove(at: index)
        queueEntryIDs.remove(at: index)
        queueLocationReferences.remove(at: index)

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
                saveQueueCursor()
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
                saveQueueCursor()
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
        queueEntryIDs.removeAll()
        queueLocationReferences.removeAll()
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

    /// Explicit recovery for a protected legacy queue. The corrupt bytes must
    /// already have a verified diagnostic copy; recovery never applies to a
    /// future/foreign database and never silently falls back to stale state.
    @MainActor
    @discardableResult
    func recoverCorruptQueueStartingEmpty() -> Bool {
        guard libraryDatabase == nil,
              case .corrupt(let diagnosticURL) = queuePersistenceProtection,
              let diagnosticURL else { return false }
        playlistSaveStateLock.lock()
        let sourceURL = protectedQueueSourceURL
        playlistSaveStateLock.unlock()
        guard let sourceURL,
              let original = try? DerivedCacheFileIO.readBoundedRegularFile(
                  at: sourceURL,
                  maximumBytes: maximumPlaylistStoreBytes
              ),
              let diagnostic = try? DerivedCacheFileIO.readBoundedRegularFile(
                  at: diagnosticURL,
                  maximumBytes: maximumPlaylistStoreBytes
              ),
              original == diagnostic else { return false }

        let empty = SavedPlaylist(
            version: playlistFormatVersion,
            tracks: [],
            paths: [],
            currentIndex: 0
        )
        do {
            try writePlaylistSnapshot(empty, to: sourceURL)
        } catch {
            PersistenceLogger.log("重建空队列失败：\(error.localizedDescription)")
            return false
        }

        cancelDurationPrefetch()
        audioFiles.removeAll(keepingCapacity: false)
        queueEntryIDs.removeAll(keepingCapacity: false)
        queueLocationReferences.removeAll(keepingCapacity: false)
        filteredFiles.removeAll(keepingCapacity: false)
        retainedMissingWithOriginalIndex.removeAll(keepingCapacity: false)
        fullOrderIndexForAudioFile.removeAll(keepingCapacity: false)
        loadedSignatureByPath.removeAll(keepingCapacity: false)
        pendingQueueWeightRekeys.removeAll(keepingCapacity: false)
        unplayableReasons.removeAll(keepingCapacity: false)
        currentIndex = 0
        searchText = ""
        invalidateQueueIndexCache()
        resetShuffleQueue()
        setPlaylistPersistenceReadOnly(nil)
        playlistSaveStateLock.lock()
        playlistDurableRevision = playlistSaveRevision
        playlistSaveStateLock.unlock()
        PersistenceLogger.notifyUser(
            title: "队列已重建",
            subtitle: "损坏数据仍保留在诊断副本中"
        )
        return true
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
    func ensureInQueue(
        _ files: [AudioFile],
        focusURL: URL? = nil,
        signatures: [String: FileSignature] = [:],
        storedTracksByResolvedPath: [String: UserPlaylist.Track] = [:]
    ) -> Int? {
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

        var storedTrackByKey: [String: UserPlaylist.Track] = [:]
        var conflictingStoredTrackKeys = Set<String>()
        for (path, track) in storedTracksByResolvedPath {
            let key = pathKey(URL(fileURLWithPath: path))
            if let existing = storedTrackByKey[key],
               existing.locationID != track.locationID
                || existing.relativePath != track.relativePath {
                conflictingStoredTrackKeys.insert(key)
                storedTrackByKey.removeValue(forKey: key)
            } else if !conflictingStoredTrackKeys.contains(key) {
                storedTrackByKey[key] = track
            }
        }
        var signatureByKey: [String: FileSignature] = [:]
        var conflictingSignatureKeys = Set<String>()
        for (path, signature) in signatures {
            let key = pathKey(URL(fileURLWithPath: path))
            if let existing = signatureByKey[key], existing != signature {
                conflictingSignatureKeys.insert(key)
                signatureByKey.removeValue(forKey: key)
            } else if !conflictingSignatureKeys.contains(key) {
                signatureByKey[key] = signature
            }
        }

        var toAppend: [AudioFile] = []
        toAppend.reserveCapacity(files.count)
        var signatureUpdates: [String: FileSignature] = [:]
        var locationUpdates: [Int: QueueLocationReference] = [:]

        for f in files {
            let key = pathKey(f.url)
            if let existing = indexByKey[key] {
                if focusIndex == nil, let focusKey, focusKey == key { focusIndex = existing }
                if loadedSignatureByPath[audioFiles[existing].url.path] == nil,
                   let signature = signatureByKey[key] {
                    signatureUpdates[audioFiles[existing].url.path] = signature
                }
                if let storedTrack = storedTrackByKey[key],
                   let locationID = storedTrack.locationID {
                    let proposed = QueueLocationReference(
                        locationID: locationID,
                        relativePath: storedTrack.relativePath
                    )
                    let existingReference = queueLocationReferences.indices.contains(existing)
                        ? queueLocationReferences[existing]
                        : nil
                    if existingReference == nil
                        || (existingReference?.locationID == locationID
                            && existingReference?.relativePath == nil
                            && proposed.relativePath != nil) {
                        locationUpdates[existing] = proposed
                    }
                }
                continue
            }

            let newIndex = audioFiles.count + toAppend.count
            indexByKey[key] = newIndex
            if focusIndex == nil, let focusKey, focusKey == key { focusIndex = newIndex }
            toAppend.append(f)
        }

        let additions = toAppend.map { file in
            (file: file, signature: signatureByKey[pathKey(file.url)])
        }
        let additionLocations: [QueueLocationReference?] = toAppend.map { file in
            guard let track = storedTrackByKey[pathKey(file.url)],
                  let locationID = track.locationID else { return nil }
            return QueueLocationReference(
                locationID: locationID,
                relativePath: track.relativePath
            )
        }
        guard !toAppend.isEmpty || !signatureUpdates.isEmpty || !locationUpdates.isEmpty else {
            return focusIndex
        }
        guard queueStateFitsPersistenceBounds(
            addingFiles: additions,
            signatureOverrides: signatureUpdates,
            locationOverrides: locationUpdates,
            addingLocationReferences: additionLocations
        ) else {
            notifyQueueCapacityRejected()
            return existingFocusIndex
        }

        ensureQueueEntryIDAlignment()
        for (path, signature) in signatureUpdates {
            loadedSignatureByPath[path] = signature
        }
        for (index, reference) in locationUpdates where queueLocationReferences.indices.contains(index) {
            queueLocationReferences[index] = reference
        }
        for f in toAppend {
            if let sig = signatureByKey[pathKey(f.url)] {
                loadedSignatureByPath[f.url.path] = sig
            }
        }

        let oldCount = audioFiles.count
        audioFiles.append(contentsOf: toAppend)
        queueEntryIDs.append(contentsOf: toAppend.map { _ in UUID() })
        queueLocationReferences.append(contentsOf: additionLocations)
        invalidateQueueIndexCache()
        updateFilteredFiles()
        if !toAppend.isEmpty {
            enqueueDurationPrefetch(for: toAppend.map(\.url))
            integrateNewQueueIndicesIntoShuffleQueue(oldCount: oldCount)
        }
        savePlaylist()

        return focusIndex
    }

    @MainActor
    func makePlaylistTracks(from files: [AudioFile]) -> [UserPlaylist.Track] {
        ensureQueueEntryIDAlignment()
        return files.map { file in
            let index = audioFiles.firstIndex {
                pathKey($0.url) == pathKey(file.url)
            }
            let location = index.flatMap { queueLocationReferences[$0] }
            return UserPlaylist.Track(
                path: file.url.path,
                signature: loadedSignatureByPath[file.url.path],
                locationID: location?.locationID,
                relativePath: location?.relativePath
            )
        }
    }

    func playbackSessionTrackIdentity(
        for url: URL
    ) -> PlaybackSessionStore.InstalledTrack {
        ensureQueueEntryIDAlignment()
        let key = pathKey(url)
        let queueIndex = audioFiles.firstIndex { pathKey($0.url) == key }
        let queueEntryID = queueIndex.flatMap {
            queueEntryIDs.indices.contains($0) ? queueEntryIDs[$0] : nil
        }
        let scopeTrackID: UUID?
        switch playbackScope {
        case .queue:
            scopeTrackID = nil
        case .playlist:
            let occurrence = currentPlaybackPlaylistOccurrenceKey
                ?? playbackPlaylistTrackKeys.first {
                    pathKeyForPlaylistOccurrence($0) == key
                }
            if let occurrence,
               occurrence.hasPrefix("id:"),
               let component = occurrence.dropFirst(3)
                   .split(separator: "#", maxSplits: 1).first {
                let raw = String(component)
                scopeTrackID = UUID(uuidString: raw)
            } else {
                scopeTrackID = nil
            }
        }
        return PlaybackSessionStore.InstalledTrack(
            queueEntryID: queueEntryID,
            scopeTrackID: scopeTrackID,
            fallbackPath: url.path
        )
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
        guard audioFiles.indices.contains(index), !isUnplayableIndex(index) else { return nil }
        currentIndex = index
        saveQueueCursor()
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
                saveQueueCursor()
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
                saveQueueCursor()
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
            saveQueueCursor()
            return audioFiles[currentIndex]
        }
        return nil
    }

    private func getRandomFileExcludingCurrentInQueue() -> AudioFile? {
        guard audioFiles.count > 1 else { return nil }

        let candidates = audioFiles.indices.filter { $0 != currentIndex && !isUnplayableIndex($0) }
        guard let idx = weightedRandomIndex(indices: candidates, scope: .queue) else { return nil }

        currentIndex = idx
        saveQueueCursor()
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
            saveQueueCursor()
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
            saveQueueCursor()
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
        saveQueueCursor()
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
        saveQueueCursor()
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

    private func ensureQueueEntryIDAlignment() {
        if queueEntryIDs.count > audioFiles.count {
            queueEntryIDs.removeLast(queueEntryIDs.count - audioFiles.count)
        } else if queueEntryIDs.count < audioFiles.count {
            queueEntryIDs.append(
                contentsOf: (queueEntryIDs.count..<audioFiles.count).map { _ in UUID() }
            )
        }
        if queueLocationReferences.count > audioFiles.count {
            queueLocationReferences.removeLast(queueLocationReferences.count - audioFiles.count)
        } else if queueLocationReferences.count < audioFiles.count {
            queueLocationReferences.append(
                contentsOf: repeatElement(
                    Optional<QueueLocationReference>.none,
                    count: audioFiles.count - queueLocationReferences.count
                )
            )
        }
    }

    private func seedLibraryQueueRevision(_ revision: UInt64) {
        guard libraryDatabase != nil else { return }
        playlistSaveStateLock.lock()
        libraryQueueRevision = revision
        playlistSaveRevision = max(playlistSaveRevision, revision)
        playlistDurableRevision = max(playlistDurableRevision, revision)
        playlistSaveStateLock.unlock()
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
            saveQueueCursor()
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
                saveQueueCursor()
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
                saveQueueCursor()
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
                saveQueueCursor()
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
        isRestoringScanSubfoldersPreference = true
        scanSubfolders = appPreferencesStore.load().scanSubfolders
        isRestoringScanSubfoldersPreference = false
    }

    private func saveScanSubfoldersPreference() {
        guard !isRunningRegressionTests else { return }
        let authoritativeValue = appPreferencesStore.load().scanSubfolders
        guard appPreferencesStore.persistenceState == .writable else {
            restoreScanSubfoldersPreference(authoritativeValue)
            return
        }
        _ = appPreferencesStore.update { $0.scanSubfolders = scanSubfolders }
        if case .failure = appPreferencesStore.persist() {
            _ = appPreferencesStore.update { $0.scanSubfolders = authoritativeValue }
            restoreScanSubfoldersPreference(authoritativeValue)
        }
    }

    private func restoreScanSubfoldersPreference(_ value: Bool) {
        guard scanSubfolders != value else { return }
        isRestoringScanSubfoldersPreference = true
        scanSubfolders = value
        isRestoringScanSubfoldersPreference = false
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
    /// Persists navigation without rebuilding the queue. Legacy JSON backends
    /// retain their historical snapshot behavior until migration succeeds.
    private func saveQueueCursor() {
        guard let libraryDatabase else {
            savePlaylist()
            return
        }
        ensureQueueEntryIDAlignment()
        guard audioFiles.indices.contains(currentIndex),
              queueEntryIDs.indices.contains(currentIndex) else { return }
        let selectedID = queueEntryIDs[currentIndex]

        playlistSaveStateLock.lock()
        let hasStructuralDebt = playlistSaveRevision > playlistDurableRevision
            || playlistSaveWorkItem != nil
            || pendingPlaylistWrite != nil
            || isPlaylistWriteDrainScheduled
        if hasStructuralDebt {
            playlistSaveStateLock.unlock()
            // The selected occurrence may not exist in SQLite yet. Coalesce the
            // cursor into the pending structural snapshot instead.
            savePlaylist()
            return
        }
        cursorSaveGeneration &+= 1
        let generation = cursorSaveGeneration
        let expectedRevision = libraryQueueRevision
        let previous = cursorSaveWorkItem
        let work = DispatchWorkItem { [weak self, weak libraryDatabase] in
            guard let self, let libraryDatabase else { return }
            self.playlistSaveStateLock.lock()
            let isCurrent = generation == self.cursorSaveGeneration
            if isCurrent { self.cursorSaveWorkItem = nil }
            self.playlistSaveStateLock.unlock()
            guard isCurrent else { return }
            do {
                let updated = try libraryDatabase.updateQueueCursor(
                    currentEntryID: selectedID,
                    expectedQueueRevision: expectedRevision
                )
                self.playlistSaveStateLock.lock()
                if updated {
                    self.cursorDurableGeneration = max(
                        self.cursorDurableGeneration,
                        generation
                    )
                }
                self.playlistSaveStateLock.unlock()
                if !updated {
                    DispatchQueue.main.async { [weak self] in
                        self?.savePlaylist()
                    }
                }
            } catch {
                PersistenceLogger.log("保存队列游标失败：\(error.localizedDescription)")
            }
        }
        cursorSaveWorkItem = work
        playlistSaveStateLock.unlock()
        previous?.cancel()
        playlistIOQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func flushLibraryCursorIfStructureIsCurrent(
        timeout: TimeInterval
    ) -> QueuePersistenceFlushResult? {
        guard let libraryDatabase else { return nil }
        ensureQueueEntryIDAlignment()

        playlistSaveStateLock.lock()
        let hasStructuralDebt = playlistSaveRevision > playlistDurableRevision
            || playlistSaveWorkItem != nil
            || pendingPlaylistWrite != nil
            || isPlaylistWriteDrainScheduled
        guard !hasStructuralDebt else {
            playlistSaveStateLock.unlock()
            return nil
        }
        let readOnly = isPlaylistPersistenceReadOnly
        let canPersist = canBuildPlaylistPersistenceSnapshot
        let revision = playlistSaveRevision
        let expectedQueueRevision = libraryQueueRevision
        cursorSaveGeneration &+= 1
        let cursorGeneration = cursorSaveGeneration
        let pendingCursor = cursorSaveWorkItem
        cursorSaveWorkItem = nil
        let selectedID = audioFiles.indices.contains(currentIndex)
            && queueEntryIDs.indices.contains(currentIndex)
            ? queueEntryIDs[currentIndex]
            : nil
        playlistSaveStateLock.unlock()
        pendingCursor?.cancel()

        guard !readOnly, canPersist else {
            return QueuePersistenceFlushResult(
                outcome: readOnly ? .protectedReadOnly : .skippedBeforeRestore,
                attemptedRevision: revision,
                durableRevision: playlistDurableRevision
            )
        }

        var didPersist = false
        let operation = {
            do {
                didPersist = try libraryDatabase.updateQueueCursor(
                    currentEntryID: selectedID,
                    expectedQueueRevision: expectedQueueRevision
                )
            } catch {
                PersistenceLogger.log("同步保存队列游标失败：\(error.localizedDescription)")
            }
        }
        let drained: Bool
        if DispatchQueue.getSpecific(key: playlistIOQueueKey) != nil {
            operation()
            drained = true
        } else {
            let completion = DispatchSemaphore(value: 0)
            playlistIOQueue.async {
                operation()
                completion.signal()
            }
            drained = completion.wait(timeout: .now() + max(0, timeout)) == .success
        }
        if didPersist {
            playlistSaveStateLock.lock()
            cursorDurableGeneration = max(cursorDurableGeneration, cursorGeneration)
            playlistSaveStateLock.unlock()
        }
        return QueuePersistenceFlushResult(
            outcome: didPersist ? .durable : (drained ? .failed : .timedOut),
            attemptedRevision: revision,
            durableRevision: playlistDurableRevision
        )
    }

    func savePlaylist() {
        if isRunningRegressionTests {
            debugLog("回归测试模式：跳过播放列表持久化写盘")
            return
        }
        playlistSnapshotStateGeneration &+= 1
        let previousWorkItem: DispatchWorkItem?
        let previousCursorWorkItem: DispatchWorkItem?
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
        cursorSaveGeneration &+= 1
        previousCursorWorkItem = cursorSaveWorkItem
        cursorSaveWorkItem = nil
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
            let stateGeneration = self.playlistSnapshotStateGeneration
            self.debugLog(
                "保存播放列表: \(snapshot.paths.count) 个文件, 当前索引: \(snapshot.currentIndex)"
            )
            self.enqueuePlaylistWrite(
                snapshot,
                revision: revision,
                stateGeneration: stateGeneration
            )
        }
        playlistSaveWorkItem = workItem
        playlistSaveStateLock.unlock()
        previousWorkItem?.cancel()
        previousCursorWorkItem?.cancel()
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

        if let cursorResult = flushLibraryCursorIfStructureIsCurrent(timeout: timeout) {
            return cursorResult
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
        playlistSaveStateLock.lock()
        let stateGeneration = playlistSnapshotStateGeneration
        let reusableSnapshot = latestCapturedPlaylistSnapshot.flatMap {
            $0.stateGeneration == stateGeneration ? $0.snapshot : nil
        }
        let preparationTimedOut = isTerminating
            && terminationSnapshotPreparation?.result.outcome == .timedOut
        if preparationTimedOut {
            let attemptedRevision = playlistSaveRevision
            let durableRevision = playlistDurableRevision
            playlistSaveStateLock.unlock()
            return QueuePersistenceFlushResult(
                outcome: .timedOut,
                attemptedRevision: attemptedRevision,
                durableRevision: durableRevision
            )
        }
        playlistSaveStateLock.unlock()
        let snapshot = reusableSnapshot ?? buildPlaylistSnapshot()
        playlistSaveStateLock.lock()
        playlistSaveRevision &+= 1
        let revision = playlistSaveRevision
        let pending = playlistSaveWorkItem
        playlistSaveWorkItem = nil
        cursorSaveGeneration &+= 1
        let pendingCursor = cursorSaveWorkItem
        cursorSaveWorkItem = nil
        playlistRetryWorkItem?.cancel()
        playlistRetryWorkItem = nil
        playlistRetryAttempt = 0
        pendingPlaylistWrite = (revision, snapshot)
        latestCapturedPlaylistSnapshot = (stateGeneration, revision, snapshot)
        isPlaylistWriteDrainScheduled = true
        playlistSaveStateLock.unlock()
        pending?.cancel()
        pendingCursor?.cancel()

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

    private func enqueuePlaylistWrite(
        _ snapshot: SavedPlaylist,
        revision: UInt64,
        stateGeneration: UInt64
    ) {
        playlistSaveStateLock.lock()
        guard revision == playlistSaveRevision else {
            playlistSaveStateLock.unlock()
            return
        }
        playlistRetryWorkItem?.cancel()
        playlistRetryWorkItem = nil
        playlistRetryAttempt = 0
        pendingPlaylistWrite = (revision, snapshot)
        latestCapturedPlaylistSnapshot = (stateGeneration, revision, snapshot)
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
            let didPersist = savePlaylistToDisk(
                pending.snapshot,
                revision: pending.revision
            )
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
        ensureQueueEntryIDAlignment()
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
            let locationReference = queueLocationReferences.indices.contains(runtimeIndex)
                ? queueLocationReferences[runtimeIndex]
                : nil
            let record = SavedPlaylist.TrackRecord(
                id: queueEntryIDs[runtimeIndex],
                path: path,
                signature: sig,
                locationID: locationReference?.locationID,
                relativePath: locationReference?.relativePath
            )

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
            storeRevision: libraryQueueRevision,
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
        let decodedRecords: [SavedPlaylist.TrackRecord]
        if let tracks = saved.tracks, !tracks.isEmpty || saved.paths.isEmpty {
            decodedRecords = tracks
        } else {
            decodedRecords = saved.paths.map {
                SavedPlaylist.TrackRecord(path: $0, signature: nil)
            }
        }
        let records = decodedRecords.map { record in
            record.id == nil
                ? SavedPlaylist.TrackRecord(
                    id: UUID(),
                    path: record.path,
                    signature: record.signature,
                    locationID: record.locationID,
                    relativePath: record.relativePath
                )
                : record
        }

        let fileManager = FileManager.default
        var validEntries: [(
            url: URL,
            snapshot: FileValidationSnapshot,
            signature: FileSignature?,
            entryID: UUID,
            originalIndex: Int,
            locationReference: QueueLocationReference?,
            offlineReason: String?
        )] = []
        var missingWithIndex: [(originalIndex: Int, record: SavedPlaylist.TrackRecord)] = []

        var locationsByID: [UUID: LibraryLocation] = [:]
        if let libraryDatabase {
            do {
                _ = try libraryDatabase.forEachLibraryLocation { record in
                    locationsByID[record.location.id] = record.location
                    return true
                }
            } catch {
                PersistenceLogger.log("读取媒体位置失败：\(error.localizedDescription)")
            }
        }

        for (originalIndex, record) in records.enumerated() {
            if Task.isCancelled { return }
            var url = URL(fileURLWithPath: record.path)
            var offlineReason: String?
            let locationReference = record.locationID.map {
                QueueLocationReference(locationID: $0, relativePath: record.relativePath)
            }

            if let locationID = record.locationID {
                if let location = locationsByID[locationID],
                   let reference = try? LibraryTrackReference(
                       id: record.id ?? UUID(),
                       locationID: locationID,
                       relativePath: record.relativePath,
                       legacyAbsolutePath: record.path,
                       signature: record.signature
                   ) {
                    let resolution = await libraryLocationResolver.resolve(
                        reference,
                        in: location
                    )
                    switch resolution.availability {
                    case .available(let resolvedURL):
                        url = resolvedURL
                    case .volumeUnavailable:
                        offlineReason = "所在磁盘当前未连接"
                    case .authorizationRequired:
                        offlineReason = "需要重新授权此音乐位置"
                    case .rootMissing:
                        offlineReason = "保存的音乐根目录已移动"
                    case .fileMissing:
                        offlineReason = "歌曲在音乐位置中不存在"
                    case .invalidReference(let detail), .indeterminate(let detail):
                        offlineReason = detail
                    }
                } else {
                    offlineReason = "保存的音乐位置引用无效"
                }
            }
            let snapshot = FileValidationSnapshot.load(for: url, fileManager: fileManager)
            if snapshot.exists || offlineReason != nil {
                validEntries.append((
                    url,
                    snapshot,
                    record.signature,
                    record.id ?? UUID(),
                    originalIndex,
                    locationReference,
                    offlineReason
                ))
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
                self.queueEntryIDs = []
                self.loadedSignatureByPath = sigMapSnapshot
                self.seedLibraryQueueRevision(saved.storeRevision ?? 0)
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
            if entry.offlineReason != nil {
                let title = url.deletingPathExtension().lastPathComponent
                restoredFiles.append(AudioFile(
                    url: url,
                    metadata: AudioMetadata(
                        title: title.isEmpty ? "未知标题" : title,
                        artist: "离线媒体",
                        album: "等待磁盘重新连接",
                        year: nil,
                        genre: nil,
                        artwork: nil
                    ),
                    duration: nil
                ))
                continue
            }
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
        let queueEntryIDSnapshot = validEntries.map(\.entryID)
        let queueLocationReferenceSnapshot = validEntries.map(\.locationReference)
        let offlineReasonsSnapshot = validEntries.reduce(into: [String: String]()) {
            if let reason = $1.offlineReason {
                $0[self.pathKey($1.url)] = reason
            }
        }
        guard !Task.isCancelled else { return }
        let installed = await MainActor.run { () -> Bool in
            guard !Task.isCancelled, !self.isTerminating else { return false }
            self.retainedMissingWithOriginalIndex = missingSnapshot
            self.fullOrderIndexForAudioFile = fullOrderSnapshot
            self.queueEntryIDs = queueEntryIDSnapshot
            self.queueLocationReferences = queueLocationReferenceSnapshot
            self.loadedSignatureByPath = sigMapSnapshot
            self.seedLibraryQueueRevision(saved.storeRevision ?? 0)
            self.audioFiles = restoredFilesSnapshot
            self.unplayableReasons.merge(offlineReasonsSnapshot) { _, new in new }
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
        let d = legacyUserDefaults
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
        if let libraryDatabase {
            do {
                let queue = try libraryDatabase.loadQueue()
                let records = queue.entries.map {
                    SavedPlaylist.TrackRecord(
                        id: $0.id,
                        path: $0.path,
                        signature: $0.signature,
                        locationID: $0.locationID,
                        relativePath: $0.relativePath
                    )
                }
                let currentIndex = queue.currentEntryID.flatMap { selectedID in
                    queue.entries.firstIndex(where: { $0.id == selectedID })
                } ?? 0
                let rekeys = queue.pendingRekeys.map {
                    SavedPlaylist.WeightRekeyRecord(
                        id: $0.id,
                        oldPath: $0.oldPath,
                        newPath: $0.newPath,
                        createdAt: $0.createdAt
                    )
                }
                switch libraryDatabase.accessMode {
                case .writable:
                    break
                case .readOnlyFuture(let version):
                    setPlaylistPersistenceReadOnly(.future(version: version))
                    PersistenceLogger.log(
                        "Library.sqlite 版本 \(version) 过新，队列进入只读保护"
                    )
                case .readOnlyForeign:
                    setPlaylistPersistenceReadOnly(.foreignDatabase)
                    PersistenceLogger.log("Library.sqlite 标识不匹配，队列进入只读保护")
                }
                return .loaded(
                    SavedPlaylist(
                        version: playlistFormatVersion,
                        storeRevision: queue.revision,
                        tracks: records,
                        paths: [],
                        currentIndex: records.isEmpty ? 0 : min(currentIndex, records.count - 1),
                        pendingWeightRekeys: rekeys.isEmpty ? nil : rekeys
                    )
                )
            } catch {
                setPlaylistPersistenceReadOnly(
                    .unreadable(message: "音乐库队列无法读取：\(error.localizedDescription)")
                )
                PersistenceLogger.log("读取 Library.sqlite 队列失败：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(
                        title: "音乐库无法读取",
                        subtitle: "队列已进入只读保护模式"
                    )
                }
                return .protectedUnreadable
            }
        }
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
            setPlaylistPersistenceReadOnly(
                .unreadable(message: "队列文件无法读取：\(error.localizedDescription)")
            )
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
            setPlaylistPersistenceReadOnly(.future(version: v))
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
                let diagnosticURL = preserveCorruptedPlaylistDiagnostic(
                    at: url,
                    originalData: data
                )
                setPlaylistPersistenceReadOnly(
                    .corrupt(diagnosticURL: diagnosticURL),
                    sourceURL: url
                )
                return .protectedCorrupt
            }
            return .loaded(snapshot)
        } catch {
            debugLog("队列文件损坏: \(error)，保留原文件并写入有界诊断副本")
            let diagnosticURL = preserveCorruptedPlaylistDiagnostic(
                at: url,
                originalData: data
            )
            setPlaylistPersistenceReadOnly(
                .corrupt(diagnosticURL: diagnosticURL),
                sourceURL: url
            )
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

    private func setPlaylistPersistenceReadOnly(
        _ protection: QueuePersistenceProtection?,
        sourceURL: URL? = nil
    ) {
        let value = protection != nil
        playlistSaveStateLock.lock()
        isPlaylistPersistenceReadOnly = value
        protectedQueueSourceURL = sourceURL
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
        DispatchQueue.main.async { [weak self] in
            self?.queuePersistenceProtection = protection
        }
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

    @discardableResult
    private func preserveCorruptedPlaylistDiagnostic(
        at url: URL,
        originalData: Data
    ) -> URL? {
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
                return quarantineURL
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
            return quarantineURL
        } catch {
            debugLog("写入队列诊断副本失败: \(error)，原文件仍保持只读")
            PersistenceLogger.log("写入队列诊断副本失败: \(error)，原文件: \(url.path)")
            return nil
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

    private func savePlaylistToDisk(
        _ snapshot: SavedPlaylist,
        revision: UInt64? = nil
    ) -> Bool {
        if isRunningRegressionTests {
            return true
        }

        // Check write protection before entering IO queue
        guard isPlaylistPersistenceWritable() else { return false }

        if let libraryDatabase {
            let records: [SavedPlaylist.TrackRecord]
            if let tracks = snapshot.tracks, !tracks.isEmpty || snapshot.paths.isEmpty {
                records = tracks
            } else {
                records = snapshot.paths.map {
                    SavedPlaylist.TrackRecord(path: $0, signature: nil)
                }
            }
            let entries = records.enumerated().map { index, record in
                LibraryQueueEntry(
                    id: record.id ?? UUID(),
                    sortKey: Int64(index) * 1_024,
                    path: record.path,
                    signature: record.signature,
                    locationID: record.locationID,
                    relativePath: record.relativePath
                )
            }
            let currentEntryID = entries.indices.contains(snapshot.currentIndex)
                ? entries[snapshot.currentIndex].id
                : nil
            let rekeys = (snapshot.pendingWeightRekeys ?? []).map {
                LibraryQueueRekeyIntent(
                    id: $0.id,
                    oldPath: $0.oldPath,
                    newPath: $0.newPath,
                    createdAt: $0.createdAt
                )
            }
            playlistSaveStateLock.lock()
            let expectedRevision = libraryQueueRevision
            playlistSaveStateLock.unlock()
            let targetRevision = max(
                max(revision ?? 0, snapshot.storeRevision ?? 0),
                expectedRevision &+ 1
            )
            do {
                let result = try libraryDatabase.replaceQueue(
                    LibraryQueueSnapshot(
                        revision: targetRevision,
                        entries: entries,
                        currentEntryID: currentEntryID,
                        pendingRekeys: rekeys
                    ),
                    expectedRevision: expectedRevision
                )
                switch result {
                case .committed(let durableRevision), .alreadyCurrent(let durableRevision):
                    playlistSaveStateLock.lock()
                    libraryQueueRevision = durableRevision
                    playlistSaveStateLock.unlock()
                    return true
                case .stale(let storedRevision):
                    setPlaylistPersistenceReadOnly(
                        .unreadable(
                            message: "队列已被另一写入更新（磁盘版本 \(storedRevision)），已停止自动覆盖"
                        )
                    )
                    return false
                case .conflict(let conflictingRevision):
                    setPlaylistPersistenceReadOnly(
                        .unreadable(
                            message: "队列版本 \(conflictingRevision) 存在内容冲突，已停止自动覆盖"
                        )
                    )
                    return false
                }
            } catch {
                debugLog("保存 Library.sqlite 队列失败: \(error)")
                PersistenceLogger.log("保存 Library.sqlite 队列失败: \(error)")
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(
                        title: "队列保存失败",
                        subtitle: "请检查磁盘权限或空间"
                    )
                }
                return false
            }
        }

        guard let url = playlistFileURL() else { return false }

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
    static let externalMediaTopologyDidChange = Notification.Name(
        "externalMediaTopologyDidChange"
    )
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
