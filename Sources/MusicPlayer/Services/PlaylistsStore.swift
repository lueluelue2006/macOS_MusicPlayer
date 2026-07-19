import Combine
import Foundation

struct PlaylistCommitReceipt: Hashable, Sendable {
    let revision: UInt64
}

enum PlaylistPersistenceFailure: Error, Equatable, Sendable {
    case storageUnavailable
    case encodingFailed(String)
    case writeFailed(String)
    case capacityExceeded(maximumBytes: Int)

    var diagnosticMessage: String {
        switch self {
        case .storageUnavailable:
            return "歌单存储目录不可访问"
        case .encodingFailed(let message):
            return "歌单编码失败：\(message)"
        case .writeFailed(let message):
            return "歌单写入失败：\(message)"
        case .capacityExceeded(let maximumBytes):
            return "歌单数据超过 \(maximumBytes / 1_024 / 1_024) MB 安全上限"
        }
    }
}

enum PlaylistReadOnlyReason: Equatable, Sendable {
    case futureVersion(found: Int, supported: Int)
    case unsupportedVersion(Int)
    case corrupt(backupURL: URL?)
    case oversized(maximumBytes: Int)
    case unreadable

    var diagnosticMessage: String {
        switch self {
        case .futureVersion(let found, let supported):
            return "歌单文件版本 v\(found) 高于当前支持的 v\(supported)"
        case .unsupportedVersion(let version):
            return "歌单文件版本 v\(version) 不受支持"
        case .corrupt(let backupURL):
            if let backupURL {
                return "歌单文件损坏，原始数据已备份为 \(backupURL.lastPathComponent)"
            }
            return "歌单文件损坏，原始数据仍在原位置只读保护"
        case .oversized(let maximumBytes):
            return "歌单文件超过安全读取上限（\(maximumBytes / 1_024 / 1_024) MB）"
        case .unreadable:
            return "歌单文件不可读"
        }
    }
}

enum PlaylistPersistenceState: Equatable, Sendable {
    case notLoaded
    case loading
    case ready(durableRevision: UInt64)
    case dirty(revision: UInt64, lastError: PlaylistPersistenceFailure?)
    case readOnly(PlaylistReadOnlyReason)
    case terminating
}

enum PlaylistMutationRejection: Error, Equatable, Sendable {
    case loading
    case readOnly(PlaylistReadOnlyReason)
    case terminating
    case playlistNotFound(UserPlaylist.ID)
    case invalidInput(String)
    case storageUnavailable

    var diagnosticMessage: String {
        switch self {
        case .loading: return "歌单仍在加载，请稍后重试"
        case .readOnly(let reason): return reason.diagnosticMessage
        case .terminating: return "应用正在退出，未接受新的歌单修改"
        case .playlistNotFound: return "目标歌单不存在"
        case .invalidInput(let message): return message
        case .storageUnavailable: return "歌单存储目录不可访问"
        }
    }
}

enum PlaylistMutationResult<Value: Sendable>: Sendable {
    case applied(Value, receipt: PlaylistCommitReceipt)
    case unchanged(Value)
    case rejected(PlaylistMutationRejection)
}

enum PlaylistDurableCommitResult: Equatable, Sendable {
    case committed(throughRevision: UInt64)
    case failed(
        revision: UInt64,
        failure: PlaylistPersistenceFailure,
        retryable: Bool
    )
}

enum PlaylistDurableMutationResult<Value: Sendable>: Sendable {
    case committed(Value)
    case unchanged(Value)
    case rejected(PlaylistMutationRejection)
    case persistenceFailed(PlaylistPersistenceFailure)
}

struct PlaylistTrackMutationSummary: Equatable, Sendable {
    let playlistID: UserPlaylist.ID
    let affectedCount: Int
    let paths: [String]
}

struct PlaylistDeletionSummary: Equatable, Sendable {
    let playlistID: UserPlaylist.ID
    let removedTrackPaths: [String]
}

struct PlaylistCleanupIntent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case deletePlaylist
        case removeTracks
        case relocateTracks
    }

    struct TrackRelocation: Codable, Equatable, Sendable {
        let trackID: UUID?
        let oldPath: String
        let newPath: String

        init(trackID: UUID? = nil, oldPath: String, newPath: String) {
            self.trackID = trackID
            self.oldPath = oldPath
            self.newPath = newPath
        }
    }

    let id: UUID
    let kind: Kind
    let playlistID: UserPlaylist.ID
    let trackPaths: [String]
    let trackIDs: [UUID]?
    let trackRelocations: [TrackRelocation]?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        playlistID: UserPlaylist.ID,
        trackPaths: [String],
        trackIDs: [UUID]? = nil,
        trackRelocations: [TrackRelocation]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.playlistID = playlistID
        self.trackPaths = trackPaths
        self.trackIDs = trackIDs
        self.trackRelocations = trackRelocations
        self.createdAt = createdAt
    }
}

struct PlaylistCleanupReport: Equatable, Sendable {
    let processedIntentCount: Int
    let remainingIntentCount: Int
    let sidecarsDurable: Bool
}

struct PlaylistTrackRelocationSummary: Equatable, Sendable {
    let relocatedTrackCount: Int
    let relocations: [PlaylistCleanupIntent.TrackRelocation]
}

private struct PlaylistWeightRekeyBatch: Sendable {
    let playlistID: UserPlaylist.ID
    let changes: [PlaybackWeights.TrackRekey]
}

private struct PlaylistWeightCleanupPlan: Sendable {
    let rekeyBatches: [PlaylistWeightRekeyBatch]
    let removals: [PlaybackWeights.PlaylistTrackRemoval]
}

private struct PlaylistTrackCleanupKey: Hashable, Sendable {
    let playlistID: UserPlaylist.ID
    let trackID: UUID
}

private struct PlaylistCleanupMembership: Equatable, Sendable {
    let playlistExists: Bool
    let trackPathsByID: [UUID: String]
}

private enum PlaylistWeightCleanupOutcome: Sendable {
    case durable
    case failed
}

private enum PlaylistStoreLimits {
    static let maximumPlaylistCount = 2_000
    static let maximumTrackCount = 50_000
    static let maximumCleanupIntentCount = 10_000
    static let maximumNameBytes = 512
    static let maximumPathBytes = 16 * 1_024
    static let maximumAggregatePathBytes = 8 * 1_024 * 1_024
}

@MainActor
final class PlaylistsStore: ObservableObject {
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published var selectedPlaylistID: UserPlaylist.ID?
    @Published private(set) var isReady = false
    @Published private(set) var persistenceState: PlaylistPersistenceState = .notLoaded
    @Published private(set) var pendingCleanupIntents: [PlaylistCleanupIntent] = []

    var isPersistenceReadOnly: Bool {
        readOnlyReason != nil
    }

    private let playlistsFileName = "user-playlists.json"
    private let formatVersion = 2
    private let maximumStoreBytes = 16 * 1_024 * 1_024
    private let playlistsFileURLOverride: URL?

    private struct StoreFile: Codable, @unchecked Sendable {
        let version: Int
        let storeRevision: UInt64
        let playlists: [UserPlaylist]
        let pendingCleanup: [PlaylistCleanupIntent]
    }

    private struct LegacyStoreFileV1: Decodable {
        let version: Int
        let playlists: [UserPlaylist]
    }

    private struct StoreVersionProbe: Decodable {
        let version: Int?
    }

    private final class SnapshotWriter: @unchecked Sendable {
        private static let maximumPayloadBytes = 16 * 1_024 * 1_024
        private struct Snapshot: @unchecked Sendable {
            let revision: UInt64
            let payload: StoreFile
            let url: URL
        }

        private struct Waiter {
            let revision: UInt64
            let continuation: CheckedContinuation<PlaylistDurableCommitResult, Never>
        }

        private let queue: DispatchQueue
        private let lock = NSLock()
        private let completion: @Sendable (
            UInt64,
            Result<Void, PlaylistPersistenceFailure>
        ) -> Void

        private var pendingSnapshot: Snapshot?
        private var isDrainScheduled = false
        private var durableRevision: UInt64 = 0
        private var highestSubmittedRevision: UInt64 = 0
        private var lastFailure: (revision: UInt64, failure: PlaylistPersistenceFailure)?
        private var waiters: [Waiter] = []
        private var retryAttemptsByRevision: [UInt64: Int] = [:]

        init(
            queue: DispatchQueue,
            completion: @escaping @Sendable (
                UInt64,
                Result<Void, PlaylistPersistenceFailure>
            ) -> Void
        ) {
            self.queue = queue
            self.completion = completion
        }

        func seedDurableRevision(_ revision: UInt64) {
            lock.lock()
            durableRevision = max(durableRevision, revision)
            highestSubmittedRevision = max(highestSubmittedRevision, revision)
            if let lastFailure, lastFailure.revision <= durableRevision {
                self.lastFailure = nil
            }
            lock.unlock()
        }

        func submit(revision: UInt64, payload: StoreFile, url: URL) {
            let snapshot = Snapshot(revision: revision, payload: payload, url: url)
            let shouldSchedule: Bool

            lock.lock()
            let isRetry = lastFailure?.revision == revision
            guard revision > durableRevision,
                  revision > highestSubmittedRevision || isRetry else {
                lock.unlock()
                return
            }
            highestSubmittedRevision = max(highestSubmittedRevision, revision)
            if pendingSnapshot == nil || revision >= pendingSnapshot!.revision {
                pendingSnapshot = snapshot
            }
            if let lastFailure, lastFailure.revision <= revision {
                self.lastFailure = nil
            }
            shouldSchedule = !isDrainScheduled
            if shouldSchedule {
                isDrainScheduled = true
            }
            lock.unlock()

            if shouldSchedule {
                queue.async { [weak self] in
                    self?.drain()
                }
            }
        }

        func awaitCommit(_ revision: UInt64) async -> PlaylistDurableCommitResult {
            await withCheckedContinuation { continuation in
                lock.lock()
                if durableRevision >= revision {
                    let durable = durableRevision
                    lock.unlock()
                    continuation.resume(returning: .committed(throughRevision: durable))
                    return
                }
                if let lastFailure, lastFailure.revision >= revision {
                    lock.unlock()
                    continuation.resume(
                        returning: .failed(
                            revision: revision,
                            failure: lastFailure.failure,
                            retryable: true
                        )
                    )
                    return
                }
                waiters.append(Waiter(revision: revision, continuation: continuation))
                lock.unlock()
            }
        }

        func drainSynchronously(timeout: TimeInterval) -> Bool {
            let completion = DispatchSemaphore(value: 0)
            queue.async { [self] in
                drain()
                completion.signal()
            }
            return completion.wait(timeout: .now() + max(0, timeout)) == .success
        }

        func status(for revision: UInt64) -> PlaylistDurableCommitResult? {
            lock.lock()
            defer { lock.unlock() }
            if durableRevision >= revision {
                return .committed(throughRevision: durableRevision)
            }
            if let lastFailure, lastFailure.revision >= revision {
                return .failed(
                    revision: revision,
                    failure: lastFailure.failure,
                    retryable: true
                )
            }
            return nil
        }

        private func takeNextSnapshot() -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let snapshot = pendingSnapshot else {
                isDrainScheduled = false
                return nil
            }
            pendingSnapshot = nil
            return snapshot
        }

        private func drain() {
            while let snapshot = takeNextSnapshot() {
                let result = Self.persist(snapshot.payload, to: snapshot.url)
                if case .failure = result,
                   scheduleAutomaticRetryIfEligible(snapshot) {
                    return
                }
                finish(snapshot: snapshot, result: result)
                completion(snapshot.revision, result)
            }
        }

        private func scheduleAutomaticRetryIfEligible(_ snapshot: Snapshot) -> Bool {
            lock.lock()
            if let newer = pendingSnapshot, newer.revision > snapshot.revision {
                lock.unlock()
                return false
            }
            let attempt = retryAttemptsByRevision[snapshot.revision, default: 0]
            guard attempt < 3 else {
                retryAttemptsByRevision.removeValue(forKey: snapshot.revision)
                lock.unlock()
                return false
            }
            retryAttemptsByRevision[snapshot.revision] = attempt + 1
            pendingSnapshot = snapshot
            isDrainScheduled = true
            lock.unlock()

            let delays: [TimeInterval] = [0.25, 0.75, 2.0]
            queue.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
                self?.drain()
            }
            return true
        }

        private func finish(
            snapshot: Snapshot,
            result: Result<Void, PlaylistPersistenceFailure>
        ) {
            let completedWaiters: [Waiter]
            let completionResult: PlaylistDurableCommitResult

            lock.lock()
            switch result {
            case .success:
                retryAttemptsByRevision.removeValue(forKey: snapshot.revision)
                durableRevision = max(durableRevision, snapshot.revision)
                if let lastFailure, lastFailure.revision <= durableRevision {
                    self.lastFailure = nil
                }
                completedWaiters = waiters.filter { $0.revision <= durableRevision }
                waiters.removeAll { $0.revision <= durableRevision }
                completionResult = .committed(throughRevision: durableRevision)

            case .failure(let failure):
                lastFailure = (snapshot.revision, failure)
                let newerSnapshotWillRetryState = (pendingSnapshot?.revision ?? 0) > snapshot.revision
                if newerSnapshotWillRetryState {
                    completedWaiters = []
                } else {
                    completedWaiters = waiters.filter { $0.revision <= snapshot.revision }
                    waiters.removeAll { $0.revision <= snapshot.revision }
                }
                completionResult = .failed(
                    revision: snapshot.revision,
                    failure: failure,
                    retryable: true
                )
            }
            lock.unlock()

            for waiter in completedWaiters {
                switch completionResult {
                case .committed(let throughRevision):
                    waiter.continuation.resume(
                        returning: .committed(throughRevision: throughRevision)
                    )
                case .failed(_, let failure, let retryable):
                    waiter.continuation.resume(
                        returning: .failed(
                            revision: waiter.revision,
                            failure: failure,
                            retryable: retryable
                        )
                    )
                }
            }
        }

        private static func persist(
            _ payload: StoreFile,
            to url: URL
        ) -> Result<Void, PlaylistPersistenceFailure> {
            if let failure = PlaylistsStore.validationFailure(in: payload) {
                return .failure(.encodingFailed(failure))
            }
            let data: Data
            do {
                data = try JSONEncoder().encode(payload)
            } catch {
                return .failure(.encodingFailed(error.localizedDescription))
            }
            guard data.count <= maximumPayloadBytes else {
                return .failure(.capacityExceeded(maximumBytes: maximumPayloadBytes))
            }

            do {
                try DerivedCacheFileIO.atomicWrite(data, to: url)
                return .success(())
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }
    }

    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "playlists.persistence", qos: .utility)
    private let ioQueueKey = DispatchSpecificKey<Void>()
    private var currentRevision: UInt64 = 0
    private var durableRevision: UInt64 = 0
    private var readOnlyReason: PlaylistReadOnlyReason?
    private var isTerminating = false
    private var trackGenerations: [UUID: UInt64] = [:]
    private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]
    private var scheduledEnrichmentTargets: Set<SignatureCaptureTarget> = []
    private var cleanupTask: Task<Void, Never>?
    private var cleanupRetryAttempt = 0
    private var isCleanupProcessing = false

    private let signatureCaptureCoordinator: SignatureCaptureCoordinator
    private let playbackWeights: PlaybackWeights
    private let artworkStore: PlaylistArtworkStore
    private let automaticallyProcessesCleanup: Bool
    private let cleanupRetryDelaysNanoseconds: [UInt64]
    private let cleanupMaintenanceRetryDelayNanoseconds: UInt64

    private lazy var snapshotWriter = SnapshotWriter(queue: ioQueue) { [weak self] revision, result in
        Task { @MainActor [weak self] in
            self?.handlePersistenceCompletion(revision: revision, result: result)
        }
    }

    init(
        playlistsFileURLOverride: URL? = nil,
        signatureCaptureService: SignatureCaptureService? = nil,
        playbackWeights: PlaybackWeights = .shared,
        artworkStore: PlaylistArtworkStore = .shared,
        automaticallyProcessesCleanup: Bool = true,
        cleanupRetryDelays: [TimeInterval] = [5, 30, 120],
        cleanupMaintenanceRetryDelay: TimeInterval = 15 * 60
    ) {
        self.playlistsFileURLOverride = playlistsFileURLOverride
        let service = signatureCaptureService ?? SignatureCaptureService()
        self.signatureCaptureCoordinator = SignatureCaptureCoordinator(service: service)
        self.playbackWeights = playbackWeights
        self.artworkStore = artworkStore
        self.automaticallyProcessesCleanup = automaticallyProcessesCleanup
        self.cleanupRetryDelaysNanoseconds = cleanupRetryDelays.map(
            Self.retryDelayNanoseconds
        )
        self.cleanupMaintenanceRetryDelayNanoseconds = Self.retryDelayNanoseconds(
            cleanupMaintenanceRetryDelay
        )
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        persistenceState = .loading
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
            persistenceState = .dirty(revision: 0, lastError: .storageUnavailable)
            return
        }

        enum LoadOutcome {
            case missing
            case loaded(StoreFile)
            case migratedV1([UserPlaylist])
            case protected(PlaylistReadOnlyReason)
        }

        let supportedVersion = formatVersion
        let maximumStoreBytes = maximumStoreBytes
        let outcome: LoadOutcome = await withCheckedContinuation { continuation in
            ioQueue.async {
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: url.path) else {
                    continuation.resume(returning: .missing)
                    return
                }

                do {
                    if try DerivedCacheFileIO.fileSize(at: url) > maximumStoreBytes {
                        continuation.resume(
                            returning: .protected(
                                .oversized(maximumBytes: maximumStoreBytes)
                            )
                        )
                        return
                    }
                } catch {
                    continuation.resume(returning: .protected(.unreadable))
                    return
                }

                let data: Data
                do {
                    data = try DerivedCacheFileIO.readBoundedRegularFile(
                        at: url,
                        maximumBytes: maximumStoreBytes
                    )
                } catch {
                    Self.notifyCorruptStore(reason: "unreadable")
                    continuation.resume(returning: .protected(.unreadable))
                    return
                }

                guard let probe = try? JSONDecoder().decode(StoreVersionProbe.self, from: data),
                      let version = probe.version else {
                    let backupURL = Self.quarantineCorruptedFile(
                        url: url,
                        data: data,
                        reason: "missing-version"
                    )
                    continuation.resume(returning: .protected(.corrupt(backupURL: backupURL)))
                    return
                }

                if version > supportedVersion {
                    continuation.resume(
                        returning: .protected(
                            .futureVersion(found: version, supported: supportedVersion)
                        )
                    )
                    return
                }

                switch version {
                case 1:
                    guard let legacy = try? JSONDecoder().decode(LegacyStoreFileV1.self, from: data) else {
                        let backupURL = Self.quarantineCorruptedFile(
                            url: url,
                            data: data,
                            reason: "v1-decode-failed"
                        )
                        continuation.resume(
                            returning: .protected(.corrupt(backupURL: backupURL))
                        )
                        return
                    }
                    let migrated = StoreFile(
                        version: supportedVersion,
                        storeRevision: 0,
                        playlists: legacy.playlists,
                        pendingCleanup: []
                    )
                    guard Self.validationFailure(in: migrated) == nil else {
                        let backupURL = Self.quarantineCorruptedFile(
                            url: url,
                            data: data,
                            reason: "v1-invalid-structure"
                        )
                        continuation.resume(
                            returning: .protected(.corrupt(backupURL: backupURL))
                        )
                        return
                    }
                    continuation.resume(returning: .migratedV1(legacy.playlists))

                case supportedVersion:
                    guard let store = try? JSONDecoder().decode(StoreFile.self, from: data),
                          Self.validationFailure(in: store) == nil else {
                        let backupURL = Self.quarantineCorruptedFile(
                            url: url,
                            data: data,
                            reason: "v2-decode-failed"
                        )
                        continuation.resume(
                            returning: .protected(.corrupt(backupURL: backupURL))
                        )
                        return
                    }
                    continuation.resume(returning: .loaded(store))

                default:
                    continuation.resume(returning: .protected(.unsupportedVersion(version)))
                }
            }
        }

        var needsMigrationWrite = false
        switch outcome {
        case .missing:
            currentRevision = 0
            durableRevision = 0
            pendingCleanupIntents = []

        case .loaded(let store):
            playlists = store.playlists
            pendingCleanupIntents = store.pendingCleanup
            currentRevision = store.storeRevision
            durableRevision = store.storeRevision

        case .migratedV1(let legacyPlaylists):
            playlists = legacyPlaylists
            pendingCleanupIntents = []
            currentRevision = 0
            durableRevision = 0
            needsMigrationWrite = true

        case .protected(let reason):
            readOnlyReason = reason
            persistenceState = .readOnly(reason)
            switch reason {
            case .futureVersion(let found, let supported):
                PersistenceLogger.log(
                    "检测到未来歌单文件版本 \(found)（当前支持 \(supported)），进入只读模式保护数据"
                )
                DispatchQueue.main.async {
                    PersistenceLogger.notifyUser(
                        title: "歌单文件版本过新",
                        subtitle: "可能由新版本创建，当前版本只读保护"
                    )
                }
            case .unsupportedVersion(let version):
                PersistenceLogger.log("歌单文件版本 \(version) 不受支持，进入只读模式")
            case .corrupt, .oversized, .unreadable:
                break
            }
        }

        if selectedPlaylistID == nil {
            selectedPlaylistID = playlists.first?.id
        }

        loadTask = nil
        isReady = true
        rebuildTrackGenerations(revision: currentRevision)
        snapshotWriter.seedDurableRevision(durableRevision)

        guard readOnlyReason == nil else { return }
        persistenceState = .ready(durableRevision: durableRevision)

        let receipt: PlaylistCommitReceipt
        if needsMigrationWrite {
            receipt = enqueueCurrentSnapshot(to: url)
            rebuildTrackGenerations(revision: receipt.revision)
        } else {
            receipt = PlaylistCommitReceipt(revision: currentRevision)
        }
        scheduleAllMissingSignatureEnrichment(after: receipt)
        scheduleCleanupProcessingIfNeeded()
    }

    // MARK: - Mutation result API

    func createEmptyPlaylistResult(
        name: String
    ) -> PlaylistMutationResult<UserPlaylist.ID> {
        loadIfNeeded()
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名歌单" : trimmed
        if let rejection = capacityRejection(
            addingPlaylists: 1,
            candidateName: finalName
        ) {
            return .rejected(rejection)
        }
        let playlist = UserPlaylist(name: finalName, tracks: [])
        playlists.insert(playlist, at: 0)
        selectedPlaylistID = playlist.id
        let receipt = enqueueCurrentSnapshot(to: url)
        return .applied(playlist.id, receipt: receipt)
    }

    func createPlaylistResult(
        name: String,
        trackURLs: [URL]
    ) async -> PlaylistMutationResult<UserPlaylist.ID> {
        await ensureLoaded()
        guard trackURLs.allSatisfy({
            $0.isFileURL
                && $0.standardizedFileURL.path.hasPrefix("/")
                && !$0.standardizedFileURL.path.isEmpty
                && $0.standardizedFileURL.path.utf8.count <= PlaylistStoreLimits.maximumPathBytes
        }) else {
            return .rejected(.invalidInput("歌曲路径无效或过长"))
        }
        return createPlaylistWithTracksResult(
            name: name,
            tracks: normalizeTracks(from: trackURLs)
        )
    }

    func createPlaylistResult(
        name: String,
        tracks: [UserPlaylist.Track]
    ) async -> PlaylistMutationResult<UserPlaylist.ID> {
        await ensureLoaded()
        guard tracks.allSatisfy(Self.isValidInputTrack) else {
            return .rejected(.invalidInput("歌曲路径无效或过长"))
        }
        return createPlaylistWithTracksResult(
            name: name,
            tracks: normalizeTracks(tracks)
        )
    }

    private func createPlaylistWithTracksResult(
        name: String,
        tracks: [UserPlaylist.Track]
    ) -> PlaylistMutationResult<UserPlaylist.ID> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名歌单" : trimmed
        let preparedTracks = assigningUniqueTrackIDs(to: tracks)
        if let rejection = capacityRejection(
            addingPlaylists: 1,
            addingTracks: preparedTracks.count,
            addingPathBytes: preparedTracks.reduce(into: 0) { $0 += $1.path.utf8.count },
            candidateName: finalName
        ) {
            return .rejected(rejection)
        }
        let playlist = UserPlaylist(name: finalName, tracks: preparedTracks)
        playlists.insert(playlist, at: 0)
        selectedPlaylistID = playlist.id

        let receipt = enqueueCurrentSnapshot(to: url)
        setTrackGenerations(for: preparedTracks, revision: receipt.revision)
        scheduleSignatureEnrichment(
            playlistID: playlist.id,
            tracks: preparedTracks,
            after: receipt
        )
        return .applied(playlist.id, receipt: receipt)
    }

    func renamePlaylistResult(
        _ playlist: UserPlaylist,
        to newName: String
    ) -> PlaylistMutationResult<UserPlaylist.ID> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            return .rejected(.playlistNotFound(playlist.id))
        }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(.invalidInput("歌单名称不能为空"))
        }
        if let rejection = capacityRejection(candidateName: trimmed) {
            return .rejected(rejection)
        }
        guard playlists[index].name != trimmed else {
            return .unchanged(playlist.id)
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }

        playlists[index].name = trimmed
        playlists[index].updatedAt = Date()
        let receipt = enqueueCurrentSnapshot(to: url)
        return .applied(playlist.id, receipt: receipt)
    }

    func deletePlaylistResult(
        _ playlist: UserPlaylist
    ) -> PlaylistMutationResult<PlaylistDeletionSummary> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            return .rejected(.playlistNotFound(playlist.id))
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }

        let existingIntentCount = pendingCleanupIntents.reduce(into: 0) {
            if $1.playlistID == playlist.id { $0 += 1 }
        }
        if let rejection = capacityRejection(
            addingCleanupIntents: max(0, 1 - existingIntentCount)
        ) {
            return .rejected(rejection)
        }

        let removed = playlists.remove(at: index)
        let removedPaths = removed.tracks.map(\.path)
        for track in removed.tracks {
            trackGenerations.removeValue(forKey: track.id)
        }
        if selectedPlaylistID == removed.id {
            selectedPlaylistID = playlists.first?.id
        }

        let previouslyRemovedPaths = pendingCleanupIntents
            .filter { $0.playlistID == removed.id }
            .flatMap(\.trackPaths)
        let previouslyRemovedTrackIDs = pendingCleanupIntents
            .filter { $0.playlistID == removed.id }
            .flatMap { $0.trackIDs ?? [] }
        pendingCleanupIntents.removeAll { $0.playlistID == removed.id }
        var cleanupPathKeys = Set<String>()
        let allCleanupPaths = (previouslyRemovedPaths + removedPaths).filter {
            cleanupPathKeys.insert(pathKey($0)).inserted
        }
        pendingCleanupIntents.append(
            PlaylistCleanupIntent(
                kind: .deletePlaylist,
                playlistID: removed.id,
                trackPaths: allCleanupPaths,
                trackIDs: Array(Set(previouslyRemovedTrackIDs + removed.tracks.map(\.id)))
            )
        )
        cleanupRetryAttempt = 0

        let receipt = enqueueCurrentSnapshot(to: url)
        return .applied(
            PlaylistDeletionSummary(
                playlistID: removed.id,
                removedTrackPaths: removedPaths
            ),
            receipt: receipt
        )
    }

    func addTracksResult(
        _ urls: [URL],
        to playlistID: UserPlaylist.ID
    ) async -> PlaylistMutationResult<PlaylistTrackMutationSummary> {
        await ensureLoaded()
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return .rejected(.playlistNotFound(playlistID))
        }

        let newTracks = normalizeTracks(from: urls)
        guard newTracks.count == urls.count else {
            return .rejected(.invalidInput("歌曲路径无效或过长"))
        }
        guard !newTracks.isEmpty else {
            return .unchanged(
                PlaylistTrackMutationSummary(
                    playlistID: playlistID,
                    affectedCount: 0,
                    paths: []
                )
            )
        }

        let accepted = assigningUniqueTrackIDs(to: newTracks)
        guard !accepted.isEmpty else {
            return .unchanged(
                PlaylistTrackMutationSummary(
                    playlistID: playlistID,
                    affectedCount: 0,
                    paths: []
                )
            )
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }
        if let rejection = capacityRejection(
            addingTracks: accepted.count,
            addingPathBytes: accepted.reduce(into: 0) { $0 += $1.path.utf8.count }
        ) {
            return .rejected(rejection)
        }

        playlists[index].tracks.append(contentsOf: accepted)
        playlists[index].updatedAt = Date()
        let receipt = enqueueCurrentSnapshot(to: url)
        setTrackGenerations(for: accepted, revision: receipt.revision)
        scheduleSignatureEnrichment(
            playlistID: playlistID,
            tracks: accepted,
            after: receipt
        )

        return .applied(
            PlaylistTrackMutationSummary(
                playlistID: playlistID,
                affectedCount: accepted.count,
                paths: accepted.map(\.path)
            ),
            receipt: receipt
        )
    }

    func removeTracksResult(
        paths: [String],
        from playlistID: UserPlaylist.ID
    ) -> PlaylistMutationResult<PlaylistTrackMutationSummary> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let playlist = playlist(for: playlistID) else {
            return .rejected(.playlistNotFound(playlistID))
        }
        var available = playlist.tracks
        var selectedIDs: [UUID] = []
        selectedIDs.reserveCapacity(paths.count)
        for path in paths {
            let key = pathKey(path)
            guard let index = available.firstIndex(where: { pathKey($0.path) == key }) else {
                continue
            }
            selectedIDs.append(available.remove(at: index).id)
        }
        guard !selectedIDs.isEmpty else {
            return .unchanged(
                PlaylistTrackMutationSummary(
                    playlistID: playlistID,
                    affectedCount: 0,
                    paths: []
                )
            )
        }
        return removeTracksResult(trackIDs: selectedIDs, from: playlistID)
    }

    func removeTracksResult(
        trackIDs: [UUID],
        from playlistID: UserPlaylist.ID
    ) -> PlaylistMutationResult<PlaylistTrackMutationSummary> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return .rejected(.playlistNotFound(playlistID))
        }

        let targetIDs = Set(trackIDs)
        guard !targetIDs.isEmpty else {
            return .rejected(.invalidInput("没有要移除的歌曲"))
        }

        var removed: [UserPlaylist.Track] = []
        let retained = playlists[index].tracks.filter { track in
            if targetIDs.contains(track.id) {
                removed.append(track)
                return false
            }
            return true
        }
        guard !removed.isEmpty else {
            return .unchanged(
                PlaylistTrackMutationSummary(
                    playlistID: playlistID,
                    affectedCount: 0,
                    paths: []
                )
            )
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }
        if let rejection = capacityRejection(addingCleanupIntents: 1) {
            return .rejected(rejection)
        }

        playlists[index].tracks = retained
        playlists[index].updatedAt = Date()
        for track in removed {
            trackGenerations.removeValue(forKey: track.id)
        }
        let removedPaths = removed.map(\.path)
        pendingCleanupIntents.append(
            PlaylistCleanupIntent(
                kind: .removeTracks,
                playlistID: playlistID,
                trackPaths: removedPaths,
                trackIDs: removed.map(\.id)
            )
        )
        cleanupRetryAttempt = 0

        let receipt = enqueueCurrentSnapshot(to: url)
        return .applied(
            PlaylistTrackMutationSummary(
                playlistID: playlistID,
                affectedCount: removed.count,
                paths: removedPaths
            ),
            receipt: receipt
        )
    }

    /// Relocates missing tracks only when their persisted signature has exactly
    /// one candidate match. The path changes and a durable weight-rekey intent
    /// share the same playlist snapshot.
    func relocateMissingTracksResult(
        using candidates: [FileRelocationCandidate]
    ) -> PlaylistMutationResult<PlaylistTrackRelocationSummary> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }

        guard candidates.count <= PlaylistStoreLimits.maximumTrackCount else {
            return .rejected(.invalidInput("重定位候选数量超过安全上限"))
        }
        var seenCandidateKeys = Set<String>()
        let uniqueCandidates = candidates.filter {
            let path = $0.url.standardizedFileURL.path
            return $0.url.isFileURL
                && path.hasPrefix("/")
                && path.utf8.count <= PlaylistStoreLimits.maximumPathBytes
                && Self.isValidInputTrack(
                    UserPlaylist.Track(path: path, signature: $0.signature)
                )
                && seenCandidateKeys.insert(pathKey(path)).inserted
        }
        guard !uniqueCandidates.isEmpty else {
            return .unchanged(
                PlaylistTrackRelocationSummary(relocatedTrackCount: 0, relocations: [])
            )
        }

        var candidateIndex: [FileSignatureMatcher.IdentityKey: [FileRelocationCandidate]] = [:]
        for candidate in uniqueCandidates {
            guard let key = FileSignatureMatcher.identityKey(for: candidate.signature) else {
                continue
            }
            candidateIndex[key, default: []].append(candidate)
        }

        struct ProposedRelocation {
            let playlistIndex: Int
            let trackIndex: Int
            let track: UserPlaylist.Track
            let candidate: FileRelocationCandidate
            let newPath: String
        }

        let fileManager = FileManager.default
        var proposals: [ProposedRelocation] = []
        for playlistIndex in playlists.indices {
            for trackIndex in playlists[playlistIndex].tracks.indices {
                let track = playlists[playlistIndex].tracks[trackIndex]
                guard !fileManager.fileExists(atPath: track.path),
                      let originalSignature = track.signature,
                      let identity = FileSignatureMatcher.identityKey(for: originalSignature),
                      let matches = candidateIndex[identity],
                      matches.count == 1,
                      let candidate = matches.first else { continue }
                let newPath = candidate.url.standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping
                guard pathKey(track.path) != pathKey(newPath) else { continue }
                proposals.append(
                    ProposedRelocation(
                        playlistIndex: playlistIndex,
                        trackIndex: trackIndex,
                        track: track,
                        candidate: candidate,
                        newPath: newPath
                    )
                )
            }
        }

        let affectedPlaylistCount = Set(proposals.map(\.playlistIndex)).count
        if let rejection = capacityRejection(
            addingPathBytes: proposals.reduce(into: 0) {
                $0 += 2 * $1.newPath.utf8.count
            },
            addingCleanupIntents: affectedPlaylistCount
        ) {
            return .rejected(rejection)
        }

        var relocationsByPlaylist: [Int: [PlaylistCleanupIntent.TrackRelocation]] = [:]
        var allRelocations: [PlaylistCleanupIntent.TrackRelocation] = []
        var changedTrackIDs = Set<UUID>()
        for proposal in proposals {
            playlists[proposal.playlistIndex].tracks[proposal.trackIndex] = UserPlaylist.Track(
                id: proposal.track.id,
                path: proposal.newPath,
                signature: proposal.candidate.signature
            )
            let relocation = PlaylistCleanupIntent.TrackRelocation(
                trackID: proposal.track.id,
                oldPath: proposal.track.path,
                newPath: proposal.newPath
            )
            relocationsByPlaylist[proposal.playlistIndex, default: []].append(relocation)
            allRelocations.append(relocation)
            changedTrackIDs.insert(proposal.track.id)
        }

        for (playlistIndex, playlistRelocations) in relocationsByPlaylist {
            playlists[playlistIndex].updatedAt = Date()
            pendingCleanupIntents.append(
                PlaylistCleanupIntent(
                    kind: .relocateTracks,
                    playlistID: playlists[playlistIndex].id,
                    trackPaths: playlistRelocations.map(\.oldPath),
                    trackIDs: playlistRelocations.compactMap(\.trackID),
                    trackRelocations: playlistRelocations
                )
            )
        }
        if !relocationsByPlaylist.isEmpty {
            cleanupRetryAttempt = 0
        }

        guard !allRelocations.isEmpty else {
            return .unchanged(
                PlaylistTrackRelocationSummary(relocatedTrackCount: 0, relocations: [])
            )
        }
        let receipt = enqueueCurrentSnapshot(to: url)
        for trackID in changedTrackIDs {
            trackGenerations[trackID] = receipt.revision
        }
        return .applied(
            PlaylistTrackRelocationSummary(
                relocatedTrackCount: allRelocations.count,
                relocations: allRelocations
            ),
            receipt: receipt
        )
    }

    func acknowledgeCleanupIntents(
        _ intentIDs: Set<UUID>
    ) -> PlaylistMutationResult<Int> {
        if let rejection = mutationRejection() {
            return .rejected(rejection)
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }
        let before = pendingCleanupIntents.count
        pendingCleanupIntents.removeAll { intentIDs.contains($0.id) }
        let removedCount = before - pendingCleanupIntents.count
        guard removedCount > 0 else { return .unchanged(0) }
        if pendingCleanupIntents.isEmpty {
            cleanupRetryAttempt = 0
        }
        let receipt = enqueueCurrentSnapshot(to: url)
        return .applied(removedCount, receipt: receipt)
    }

    func awaitDurableCommit(
        _ receipt: PlaylistCommitReceipt
    ) async -> PlaylistDurableCommitResult {
        let result = await snapshotWriter.awaitCommit(receipt.revision)
        switch result {
        case .committed(let throughRevision):
            handlePersistenceCompletion(
                revision: throughRevision,
                result: .success(())
            )
        case .failed(_, let failure, _):
            handlePersistenceCompletion(
                revision: receipt.revision,
                result: .failure(failure)
            )
        }
        return result
    }

    func awaitDurability<Value: Sendable>(
        of result: PlaylistMutationResult<Value>
    ) async -> PlaylistDurableMutationResult<Value> {
        switch result {
        case .unchanged(let value):
            if case .ready(let stateDurableRevision) = persistenceState,
               stateDurableRevision >= currentRevision,
               durableRevision >= currentRevision {
                return .unchanged(value)
            }
            if let readOnlyReason {
                return .rejected(.readOnly(readOnlyReason))
            }
            if isTerminating {
                return .rejected(.terminating)
            }
            guard isReady, loadTask == nil else {
                return .rejected(.loading)
            }
            guard let receipt = retryPersistence() else {
                if case .dirty(_, let failure?) = persistenceState {
                    return .persistenceFailed(failure)
                }
                return .persistenceFailed(.storageUnavailable)
            }
            switch await awaitDurableCommit(receipt) {
            case .committed:
                return .unchanged(value)
            case .failed(_, let failure, _):
                return .persistenceFailed(failure)
            }
        case .rejected(let rejection):
            return .rejected(rejection)
        case .applied(let value, let receipt):
            switch await awaitDurableCommit(receipt) {
            case .committed:
                return .committed(value)
            case .failed(_, let failure, _):
                return .persistenceFailed(failure)
            }
        }
    }

    @discardableResult
    func retryPersistence() -> PlaylistCommitReceipt? {
        guard isReady, loadTask == nil, readOnlyReason == nil, !isTerminating else {
            return nil
        }
        guard let url = playlistsFileURL() else {
            persistenceState = .dirty(
                revision: currentRevision,
                lastError: .storageUnavailable
            )
            return nil
        }
        guard currentRevision > durableRevision else { return nil }
        submitCurrentSnapshot(revision: currentRevision, to: url)
        return PlaylistCommitReceipt(revision: currentRevision)
    }

    /// Explicit recovery entry point. The corrupt bytes remain preserved in the
    /// deterministic quarantine file until a caller chooses this operation.
    func recoverCorruptStoreStartingEmpty() -> PlaylistMutationResult<Int> {
        guard case .some(.corrupt(let backupURL)) = readOnlyReason else {
            return .rejected(.invalidInput("当前歌单存储不处于可恢复损坏状态"))
        }
        guard let backupURL,
              FileManager.default.fileExists(atPath: backupURL.path) else {
            return .rejected(.invalidInput("损坏歌单的隔离备份不可用"))
        }
        guard let url = playlistsFileURL() else {
            return .rejected(.storageUnavailable)
        }

        readOnlyReason = nil
        playlists = []
        selectedPlaylistID = nil
        pendingCleanupIntents = []
        trackGenerations = [:]
        let receipt = enqueueCurrentSnapshot(to: url)
        return .applied(0, receipt: receipt)
    }

    // MARK: - Compatibility API

    func createEmptyPlaylist(name: String) -> UserPlaylist.ID? {
        switch createEmptyPlaylistResult(name: name) {
        case .applied(let id, _), .unchanged(let id): return id
        case .rejected: return nil
        }
    }

    func createPlaylist(name: String, trackURLs: [URL]) async -> UserPlaylist.ID? {
        switch await createPlaylistResult(name: name, trackURLs: trackURLs) {
        case .applied(let id, _), .unchanged(let id): return id
        case .rejected: return nil
        }
    }

    func createPlaylist(
        name: String,
        tracks: [UserPlaylist.Track]
    ) async -> UserPlaylist.ID? {
        switch await createPlaylistResult(name: name, tracks: tracks) {
        case .applied(let id, _), .unchanged(let id): return id
        case .rejected: return nil
        }
    }

    func deletePlaylist(_ playlist: UserPlaylist) {
        _ = deletePlaylistResult(playlist)
    }

    func renamePlaylist(_ playlist: UserPlaylist, to newName: String) {
        _ = renamePlaylistResult(playlist, to: newName)
    }

    func addTracks(_ urls: [URL], to playlistID: UserPlaylist.ID) async -> Int {
        switch await addTracksResult(urls, to: playlistID) {
        case .applied(let summary, _), .unchanged(let summary):
            return summary.affectedCount
        case .rejected:
            return 0
        }
    }

    func removeTrack(path: String, from playlistID: UserPlaylist.ID) {
        _ = removeTracksResult(paths: [path], from: playlistID)
    }

    func playlist(for id: UserPlaylist.ID?) -> UserPlaylist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    func importArtwork(
        from sourceURL: URL,
        for playlistID: UserPlaylist.ID
    ) async throws {
        if let rejection = mutationRejection() { throw rejection }
        guard playlist(for: playlistID) != nil else {
            throw PlaylistMutationRejection.playlistNotFound(playlistID)
        }
        try await artworkStore.importArtwork(from: sourceURL, for: playlistID)
        guard playlist(for: playlistID) != nil,
              !pendingCleanupIntents.contains(where: {
                  $0.kind == .deletePlaylist && $0.playlistID == playlistID
              }) else {
            try? await artworkStore.removeArtworkForDeletedPlaylist(playlistID)
            throw PlaylistMutationRejection.playlistNotFound(playlistID)
        }
    }

    func resetArtwork(for playlistID: UserPlaylist.ID) async throws {
        if let rejection = mutationRejection() { throw rejection }
        guard playlist(for: playlistID) != nil else {
            throw PlaylistMutationRejection.playlistNotFound(playlistID)
        }
        try await artworkStore.removeCustomArtwork(for: playlistID)
    }

    // MARK: - Signature enrichment

    private func scheduleAllMissingSignatureEnrichment(
        after receipt: PlaylistCommitReceipt
    ) {
        for playlist in playlists {
            scheduleSignatureEnrichment(
                playlistID: playlist.id,
                tracks: playlist.tracks,
                after: receipt
            )
        }
    }

    private func scheduleSignatureEnrichment(
        playlistID: UserPlaylist.ID,
        tracks: [UserPlaylist.Track],
        after receipt: PlaylistCommitReceipt
    ) {
        let targets = tracks.compactMap { track -> SignatureCaptureTarget? in
            guard track.signature == nil else { return nil }
            let target = SignatureCaptureTarget(
                playlistID: playlistID,
                trackID: track.id,
                expectedPath: track.path,
                generation: trackGenerations[track.id] ?? receipt.revision
            )
            return scheduledEnrichmentTargets.insert(target).inserted ? target : nil
        }
        guard !targets.isEmpty else { return }

        let batch = SignatureCaptureBatch(targets: targets)
        let coordinator = signatureCaptureCoordinator
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var commitFailed = false
            defer {
                self.enrichmentTasks.removeValue(forKey: batch.id)
                self.scheduledEnrichmentTargets.subtract(batch.targets)
                if commitFailed,
                   !Task.isCancelled,
                   !self.isTerminating,
                   self.readOnlyReason == nil,
                   self.durableRevision >= self.currentRevision {
                    self.scheduleAllMissingSignatureEnrichment(
                        after: PlaylistCommitReceipt(revision: self.durableRevision)
                    )
                }
            }

            let durableResult = await self.awaitDurableCommit(receipt)
            guard case .committed = durableResult else {
                commitFailed = true
                return
            }
            guard
                  !Task.isCancelled,
                  !self.isTerminating,
                  self.readOnlyReason == nil else { return }

            guard let captureTask = await coordinator.submitBatch(batch) else { return }
            let result = await captureTask.value
            await coordinator.finishBatch(batch.id)

            guard !Task.isCancelled,
                  !self.isTerminating,
                  self.readOnlyReason == nil else { return }
            self.mergeSignatureCaptureResult(result)
        }
        enrichmentTasks[batch.id] = task
    }

    private func mergeSignatureCaptureResult(_ result: SignatureCaptureResult) {
        guard readOnlyReason == nil, !isTerminating else { return }
        guard currentRevision < UInt64.max - 1 else { return }
        guard let url = playlistsFileURL() else { return }

        var changedTrackIDs = Set<UUID>()
        for entry in result.entries {
            guard let signature = entry.signature else { continue }
            let target = entry.target
            guard trackGenerations[target.trackID] == target.generation,
                  let playlistIndex = playlists.firstIndex(where: {
                      $0.id == target.playlistID
                  }),
                  let trackIndex = playlists[playlistIndex].tracks.firstIndex(where: {
                      $0.id == target.trackID
                  }) else { continue }

            let currentTrack = playlists[playlistIndex].tracks[trackIndex]
            guard currentTrack.path == target.expectedPath,
                  currentTrack.signature != signature else { continue }

            playlists[playlistIndex].tracks[trackIndex] = UserPlaylist.Track(
                id: currentTrack.id,
                path: currentTrack.path,
                signature: signature
            )
            changedTrackIDs.insert(currentTrack.id)
        }

        guard !changedTrackIDs.isEmpty else { return }
        let receipt = enqueueCurrentSnapshot(to: url)
        for trackID in changedTrackIDs {
            trackGenerations[trackID] = receipt.revision
        }
    }

    // MARK: - Persistence

    private func enqueueCurrentSnapshot(to url: URL) -> PlaylistCommitReceipt {
        precondition(currentRevision < UInt64.max - 1, "playlist revision exhausted")
        currentRevision += 1
        submitCurrentSnapshot(revision: currentRevision, to: url)
        return PlaylistCommitReceipt(revision: currentRevision)
    }

    private func submitCurrentSnapshot(revision: UInt64, to url: URL) {
        let payload = StoreFile(
            version: formatVersion,
            storeRevision: revision,
            playlists: playlists,
            pendingCleanup: pendingCleanupIntents
        )
        persistenceState = .dirty(revision: currentRevision, lastError: nil)
        snapshotWriter.submit(revision: revision, payload: payload, url: url)
    }

    private func handlePersistenceCompletion(
        revision: UInt64,
        result: Result<Void, PlaylistPersistenceFailure>
    ) {
        guard readOnlyReason == nil else { return }
        switch result {
        case .success:
            let previousDurableRevision = durableRevision
            durableRevision = max(durableRevision, revision)
            if isTerminating {
                persistenceState = .terminating
            } else if durableRevision >= currentRevision {
                persistenceState = .ready(durableRevision: durableRevision)
            } else {
                persistenceState = .dirty(revision: currentRevision, lastError: nil)
            }
            if durableRevision > previousDurableRevision,
               durableRevision >= currentRevision,
               !isTerminating {
                scheduleAllMissingSignatureEnrichment(
                    after: PlaylistCommitReceipt(revision: durableRevision)
                )
            }
            scheduleCleanupProcessingIfNeeded()

        case .failure(let failure):
            guard revision > durableRevision else { return }
            if case .dirty(let revision, .some(let existingFailure)) = persistenceState,
               revision == currentRevision,
               existingFailure == failure {
                return
            }
            persistenceState = isTerminating
                ? .terminating
                : .dirty(revision: currentRevision, lastError: failure)
            PersistenceLogger.log("保存歌单失败: \(failure.diagnosticMessage)")
            PersistenceLogger.notifyUser(
                title: "歌单保存失败",
                subtitle: "请检查磁盘权限或空间"
            )
        }
    }

    /// Cancels reconstructable signature enrichment without waiting for file IO.
    /// The latest path snapshot can still be flushed independently.
    func prepareForImmediateTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        persistenceState = .terminating
        let tasks = Array(enrichmentTasks.values)
        enrichmentTasks.removeAll()
        scheduledEnrichmentTargets.removeAll()
        for task in tasks {
            task.cancel()
        }
        cleanupTask?.cancel()
        cleanupTask = nil
        let coordinator = signatureCaptureCoordinator
        Task {
            await coordinator.cancelForTermination()
        }
    }

    // MARK: - Durable sidecar cleanup

    /// Applies cleanup intents only after the playlist snapshot containing
    /// those intents is durable. The intent is acknowledged in a second durable
    /// commit, so a crash at any point resumes idempotently on the next launch.
    @discardableResult
    func processPendingCleanupIntents() async -> PlaylistCleanupReport {
        guard isReady,
              loadTask == nil,
              readOnlyReason == nil,
              !isTerminating,
              !isCleanupProcessing,
              !pendingCleanupIntents.isEmpty else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: pendingCleanupIntents.isEmpty
            )
        }
        isCleanupProcessing = true
        defer { isCleanupProcessing = false }

        // Signature enrichment or a concurrent playlist mutation may have
        // published a newer snapshot after the caller observed a durable
        // receipt. Bring that snapshot to the same durability boundary before
        // constructing a cleanup plan. Marking the pass single-flight first
        // prevents the completion callback from scheduling a duplicate pass.
        if durableRevision < currentRevision, !flushPersistence() {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }
        guard durableRevision >= currentRevision else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }

        let cleanupRevision = currentRevision
        let intents = pendingCleanupIntents
        let currentPlaylists = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        let cleanupMembership = cleanupMembershipSnapshot(
            intents: intents,
            playlistsByID: currentPlaylists
        )
        let deletedPlaylistIDs: Set<UserPlaylist.ID> = Set(
            intents.compactMap { intent -> UserPlaylist.ID? in
                intent.kind == .deletePlaylist && currentPlaylists[intent.playlistID] == nil
                    ? intent.playlistID
                    : nil
            }
        )
        guard let weightPlan = makeWeightCleanupPlan(
            intents: intents,
            currentPlaylists: currentPlaylists,
            deletedPlaylistIDs: deletedPlaylistIDs
        ) else {
            PersistenceLogger.log("歌单关联权重清理计划存在歧义，保留 intent 等待人工恢复")
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: intents.count,
                sidecarsDurable: false
            )
        }

        // Apply the in-memory sidecar mutations before the first suspension.
        // This makes playlist mutations linearize either before this plan or
        // after it; a later weight edit is detected by flushPersistence's
        // generation receipt and cannot be acknowledged by this pass.
        let weights = playbackWeights
        let maximumSidecarBatchSize = PlaylistStoreLimits.maximumTrackCount
        for batch in weightPlan.rekeyBatches {
            for start in stride(
                from: 0,
                to: batch.changes.count,
                by: maximumSidecarBatchSize
            ) {
                let end = min(start + maximumSidecarBatchSize, batch.changes.count)
                let changes = Array(batch.changes[start..<end])
                if case .rejectedReadOnly(let reason) = weights.rekeyTracks(
                    changes,
                    scope: .playlist(batch.playlistID)
                ) {
                    return cleanupFailureReport(
                        remainingIntentCount: intents.count,
                        rejectionReason: reason.diagnosticMessage
                    )
                }
            }
        }
        if !deletedPlaylistIDs.isEmpty,
           case .rejectedReadOnly(let reason) = weights.removePlaylists(
               Array(deletedPlaylistIDs)
           ) {
            return cleanupFailureReport(
                remainingIntentCount: intents.count,
                rejectionReason: reason.diagnosticMessage
            )
        }
        for removal in weightPlan.removals {
            for start in stride(
                from: 0,
                to: removal.trackURLs.count,
                by: maximumSidecarBatchSize
            ) {
                let end = min(start + maximumSidecarBatchSize, removal.trackURLs.count)
                let chunk = PlaybackWeights.PlaylistTrackRemoval(
                    playlistID: removal.playlistID,
                    trackURLs: Array(removal.trackURLs[start..<end])
                )
                if case .rejectedReadOnly(let reason) = weights.removeTracks([chunk]) {
                    return cleanupFailureReport(
                        remainingIntentCount: intents.count,
                        rejectionReason: reason.diagnosticMessage
                    )
                }
            }
        }

        let weightOutcome = await Task.detached(priority: .utility) {
            weights.flushPersistence().isDurable
                ? PlaylistWeightCleanupOutcome.durable
                : PlaylistWeightCleanupOutcome.failed
        }.value
        guard case .durable = weightOutcome else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }
        guard cleanupBarrierIsCurrent(
            revision: cleanupRevision,
            intents: intents,
            expectedMembership: cleanupMembership
        ) else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }

        var artworkFailures = Set<UserPlaylist.ID>()
        for intent in intents {
            if intent.kind == .deletePlaylist,
               deletedPlaylistIDs.contains(intent.playlistID) {
                do {
                    try await artworkStore.removeArtworkForDeletedPlaylist(intent.playlistID)
                } catch {
                    PersistenceLogger.log("歌单封面关联清理失败：\(error.localizedDescription)")
                    artworkFailures.insert(intent.playlistID)
                }
            }
        }
        guard cleanupBarrierIsCurrent(
            revision: cleanupRevision,
            intents: intents,
            expectedMembership: cleanupMembership
        ) else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }
        let completedIDs: Set<UUID> = Set(intents.compactMap { intent -> UUID? in
            artworkFailures.contains(intent.playlistID) ? nil : intent.id
        })

        guard !completedIDs.isEmpty else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }
        var acknowledgementIsDurable = false
        for _ in 0..<3 {
            if await acknowledgeCleanupIntentsDurably(completedIDs) {
                acknowledgementIsDurable = true
                break
            }
            guard cleanupBarrierIsCurrent(
                revision: cleanupRevision,
                intents: intents,
                expectedMembership: cleanupMembership
            ) else { break }
        }
        guard acknowledgementIsDurable else {
            return PlaylistCleanupReport(
                processedIntentCount: 0,
                remainingIntentCount: pendingCleanupIntents.count,
                sidecarsDurable: false
            )
        }

        return PlaylistCleanupReport(
            processedIntentCount: completedIDs.count,
            remainingIntentCount: pendingCleanupIntents.count,
            sidecarsDurable: pendingCleanupIntents.isEmpty
        )
    }

    /// Persists an acknowledgement candidate before publishing it in memory.
    /// If another playlist mutation wins while the write is in flight, that
    /// newer snapshot still contains the intents and this pass reports no ack.
    private func acknowledgeCleanupIntentsDurably(_ intentIDs: Set<UUID>) async -> Bool {
        guard !intentIDs.isEmpty,
              currentRevision < UInt64.max - 1,
              let url = playlistsFileURL() else { return false }
        let remainingIntents = pendingCleanupIntents.filter {
            !intentIDs.contains($0.id)
        }
        guard remainingIntents.count < pendingCleanupIntents.count else { return true }

        currentRevision += 1
        let acknowledgementRevision = currentRevision
        let payload = StoreFile(
            version: formatVersion,
            storeRevision: acknowledgementRevision,
            playlists: playlists,
            pendingCleanup: remainingIntents
        )
        persistenceState = .dirty(revision: currentRevision, lastError: nil)
        snapshotWriter.submit(
            revision: acknowledgementRevision,
            payload: payload,
            url: url
        )

        let acknowledgementResult = await awaitDurableCommit(
            PlaylistCommitReceipt(revision: acknowledgementRevision)
        )
        guard case .committed(let throughRevision) = acknowledgementResult,
              throughRevision == acknowledgementRevision,
              currentRevision == acknowledgementRevision else {
            return false
        }

        pendingCleanupIntents = remainingIntents
        if pendingCleanupIntents.isEmpty {
            cleanupRetryAttempt = 0
        }
        return true
    }

    private func makeWeightCleanupPlan(
        intents: [PlaylistCleanupIntent],
        currentPlaylists: [UserPlaylist.ID: UserPlaylist],
        deletedPlaylistIDs: Set<UserPlaylist.ID>
    ) -> PlaylistWeightCleanupPlan? {
        struct RekeyProposal {
            let playlistID: UserPlaylist.ID
            let destinationPath: String
            let sourcePaths: [String]
        }

        let currentPathKeys = currentPlaylists.mapValues { playlist in
            Set(playlist.tracks.map { pathKey($0.path) })
        }
        var removalPaths: [UserPlaylist.ID: [String: String]] = [:]
        func addRemovalPath(_ path: String, playlistID: UserPlaylist.ID) {
            let key = pathKey(path)
            guard !(currentPathKeys[playlistID] ?? []).contains(key) else { return }
            removalPaths[playlistID, default: [:]][key] = path
        }

        for intent in intents where intent.kind == .removeTracks {
            guard !deletedPlaylistIDs.contains(intent.playlistID) else { continue }
            for path in intent.trackPaths {
                addRemovalPath(path, playlistID: intent.playlistID)
            }
        }

        var identifiedHistories: [
            PlaylistTrackCleanupKey: [PlaylistCleanupIntent.TrackRelocation]
        ] = [:]
        var legacyHistories: [
            UserPlaylist.ID: [PlaylistCleanupIntent.TrackRelocation]
        ] = [:]
        for intent in intents where intent.kind == .relocateTracks {
            guard !deletedPlaylistIDs.contains(intent.playlistID) else { continue }
            for (index, relocation) in (intent.trackRelocations ?? []).enumerated() {
                let persistedTrackID = intent.trackIDs.flatMap {
                    index < $0.count ? $0[index] : nil
                }
                if let trackID = relocation.trackID ?? persistedTrackID {
                    identifiedHistories[
                        PlaylistTrackCleanupKey(
                            playlistID: intent.playlistID,
                            trackID: trackID
                        ),
                        default: []
                    ].append(relocation)
                } else {
                    legacyHistories[intent.playlistID, default: []].append(relocation)
                }
            }
        }

        var proposals: [RekeyProposal] = []
        let sortedIdentities = identifiedHistories.keys.sorted {
            if $0.playlistID != $1.playlistID {
                return $0.playlistID.uuidString < $1.playlistID.uuidString
            }
            return $0.trackID.uuidString < $1.trackID.uuidString
        }
        for identity in sortedIdentities {
            guard let history = identifiedHistories[identity] else { continue }
            let historicalPaths = history.flatMap { [$0.oldPath, $0.newPath] }
            guard let currentPlaylist = currentPlaylists[identity.playlistID],
                  let currentTrack = currentPlaylist.tracks.first(where: {
                      $0.id == identity.trackID
                  }) else {
                for path in historicalPaths {
                    addRemovalPath(path, playlistID: identity.playlistID)
                }
                continue
            }

            guard let chainedSources = relocationSourceChain(
                endingAt: currentTrack.path,
                history: history
            ) else { return nil }
            var seenSourceKeys = Set<String>()
            let uniqueSources = chainedSources.filter { sourcePath in
                let sourceKey = pathKey(sourcePath)
                return !(currentPathKeys[identity.playlistID] ?? []).contains(sourceKey)
                    && seenSourceKeys.insert(sourceKey).inserted
            }
            if !uniqueSources.isEmpty {
                proposals.append(
                    RekeyProposal(
                        playlistID: identity.playlistID,
                        destinationPath: currentTrack.path,
                        sourcePaths: uniqueSources
                    )
                )
            }
            for path in historicalPaths where !seenSourceKeys.contains(pathKey(path)) {
                addRemovalPath(path, playlistID: identity.playlistID)
            }
        }

        for playlistID in legacyHistories.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let history = legacyHistories[playlistID] else { continue }
            var claimedSourceKeys = Set<String>()
            if let currentPlaylist = currentPlaylists[playlistID] {
                for track in currentPlaylist.tracks.sorted(by: {
                    $0.id.uuidString < $1.id.uuidString
                }) {
                    guard let chainedSources = relocationSourceChain(
                        endingAt: track.path,
                        history: history
                    ) else { return nil }
                    var uniqueSources: [String] = []
                    for sourcePath in chainedSources {
                        let sourceKey = pathKey(sourcePath)
                        guard !(currentPathKeys[playlistID] ?? []).contains(sourceKey),
                              claimedSourceKeys.insert(sourceKey).inserted else { continue }
                        uniqueSources.append(sourcePath)
                    }
                    if !uniqueSources.isEmpty {
                        proposals.append(
                            RekeyProposal(
                                playlistID: playlistID,
                                destinationPath: track.path,
                                sourcePaths: uniqueSources
                            )
                        )
                    }
                }
            }
            for relocation in history {
                for path in [relocation.oldPath, relocation.newPath]
                where !claimedSourceKeys.contains(pathKey(path)) {
                    addRemovalPath(path, playlistID: playlistID)
                }
            }
        }

        var destinationsBySource: [UserPlaylist.ID: [String: Set<String>]] = [:]
        for proposal in proposals {
            let destinationKey = pathKey(proposal.destinationPath)
            for sourcePath in proposal.sourcePaths {
                destinationsBySource[proposal.playlistID, default: [:]][
                    pathKey(sourcePath),
                    default: []
                ].insert(destinationKey)
            }
        }
        guard destinationsBySource.values.allSatisfy({ claims in
            claims.values.allSatisfy { $0.count == 1 }
        }) else { return nil }

        let rekeyBatches = proposals.map { proposal in
            PlaylistWeightRekeyBatch(
                playlistID: proposal.playlistID,
                changes: proposal.sourcePaths.map { sourcePath in
                    PlaybackWeights.TrackRekey(
                        oldURL: URL(fileURLWithPath: sourcePath),
                        newURL: URL(fileURLWithPath: proposal.destinationPath)
                    )
                }
            )
        }
        let removals = removalPaths.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }).compactMap { playlistID -> PlaybackWeights.PlaylistTrackRemoval? in
            guard let pathsByKey = removalPaths[playlistID], !pathsByKey.isEmpty else {
                return nil
            }
            let paths = pathsByKey.keys.sorted().compactMap { pathsByKey[$0] }
            return PlaybackWeights.PlaylistTrackRemoval(
                playlistID: playlistID,
                trackURLs: paths.map { URL(fileURLWithPath: $0) }
            )
        }
        return PlaylistWeightCleanupPlan(
            rekeyBatches: rekeyBatches,
            removals: removals
        )
    }

    /// Returns source paths in newest-to-oldest order so an override on the
    /// most recently used path wins when the final destination has no override.
    /// Multiple distinct predecessors for one path are treated as corrupt debt
    /// and left unacknowledged instead of guessing which value to keep.
    private func relocationSourceChain(
        endingAt destinationPath: String,
        history: [PlaylistCleanupIntent.TrackRelocation]
    ) -> [String]? {
        var cursorKey = pathKey(destinationPath)
        var seenKeys: Set<String> = [cursorKey]
        var sources: [String] = []

        while true {
            var predecessors: [String: String] = [:]
            for relocation in history.reversed()
            where pathKey(relocation.newPath) == cursorKey {
                let oldKey = pathKey(relocation.oldPath)
                guard oldKey != cursorKey, !seenKeys.contains(oldKey) else { continue }
                predecessors[oldKey] = relocation.oldPath
            }
            guard !predecessors.isEmpty else { break }
            guard predecessors.count == 1,
                  let predecessor = predecessors.first else { return nil }
            sources.append(predecessor.value)
            cursorKey = predecessor.key
            seenKeys.insert(cursorKey)
        }
        return sources
    }

    private func cleanupFailureReport(
        remainingIntentCount: Int,
        rejectionReason: String
    ) -> PlaylistCleanupReport {
        PersistenceLogger.log("歌单关联权重清理被拒绝：\(rejectionReason)")
        return PlaylistCleanupReport(
            processedIntentCount: 0,
            remainingIntentCount: remainingIntentCount,
            sidecarsDurable: false
        )
    }

    private func cleanupBarrierIsCurrent(
        revision: UInt64,
        intents: [PlaylistCleanupIntent],
        expectedMembership: [UserPlaylist.ID: PlaylistCleanupMembership]
    ) -> Bool {
        guard isReady,
              loadTask == nil,
              readOnlyReason == nil,
              !isTerminating else { return false }
        if currentRevision != revision,
           durableRevision < currentRevision,
           !flushPersistence() {
            return false
        }
        guard durableRevision >= currentRevision else { return false }
        let currentIntents = Dictionary(
            uniqueKeysWithValues: pendingCleanupIntents.map { ($0.id, $0) }
        )
        guard intents.allSatisfy({ currentIntents[$0.id] == $0 }) else { return false }
        let livePlaylists = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        return cleanupMembershipSnapshot(
            intents: intents,
            playlistsByID: livePlaylists
        ) == expectedMembership
    }

    private func cleanupMembershipSnapshot(
        intents: [PlaylistCleanupIntent],
        playlistsByID: [UserPlaylist.ID: UserPlaylist]
    ) -> [UserPlaylist.ID: PlaylistCleanupMembership] {
        let relevantPlaylistIDs = Set(intents.map(\.playlistID))
        return Dictionary(uniqueKeysWithValues: relevantPlaylistIDs.map { playlistID in
            guard let playlist = playlistsByID[playlistID] else {
                return (
                    playlistID,
                    PlaylistCleanupMembership(
                        playlistExists: false,
                        trackPathsByID: [:]
                    )
                )
            }
            return (
                playlistID,
                PlaylistCleanupMembership(
                    playlistExists: true,
                    trackPathsByID: Dictionary(uniqueKeysWithValues: playlist.tracks.map {
                        ($0.id, pathKey($0.path))
                    })
                )
            )
        })
    }

    private func scheduleCleanupProcessingIfNeeded() {
        guard automaticallyProcessesCleanup,
              cleanupTask == nil,
              !isCleanupProcessing,
              isReady,
              loadTask == nil,
              readOnlyReason == nil,
              !isTerminating,
              durableRevision >= currentRevision,
              !pendingCleanupIntents.isEmpty else { return }

        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.processPendingCleanupIntents()
            guard !Task.isCancelled, !self.isTerminating else {
                self.cleanupTask = nil
                return
            }
            if report.sidecarsDurable {
                self.cleanupRetryAttempt = 0
                self.cleanupTask = nil
                return
            }
            let delay: UInt64
            if self.cleanupRetryAttempt < self.cleanupRetryDelaysNanoseconds.count {
                delay = self.cleanupRetryDelaysNanoseconds[self.cleanupRetryAttempt]
                self.cleanupRetryAttempt += 1
            } else {
                // Keep one cancellable maintenance retry alive after the fast
                // recovery budget. A long fixed delay avoids both abandoned
                // cleanup debt and unbounded timer/backoff bookkeeping.
                delay = self.cleanupMaintenanceRetryDelayNanoseconds
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                self.cleanupTask = nil
                return
            }
            self.cleanupTask = nil
            self.scheduleCleanupProcessingIfNeeded()
        }
    }

    /// Compatibility entry point: termination no longer waits for enrichment.
    func drainAndFlushForTermination() async {
        prepareForImmediateTermination()
        await signatureCaptureCoordinator.cancelForTermination()
        flushPersistence()
    }

    func waitUntilTerminationStartedForTesting() async {
        await signatureCaptureCoordinator.waitUntilTerminationStartedForTesting()
    }

    nonisolated private static func retryDelayNanoseconds(
        _ seconds: TimeInterval
    ) -> UInt64 {
        let minimumDelay = 0.001
        let maximumDelay = TimeInterval(UInt64.max) / 1_000_000_000
        let sanitized = seconds.isFinite
            ? min(max(seconds, minimumDelay), maximumDelay)
            : minimumDelay
        return UInt64((sanitized * 1_000_000_000).rounded())
    }

    /// Drains only the latest coalesced snapshot. No signature capture is awaited.
    @discardableResult
    func flushPersistence(timeout: TimeInterval = 5) -> Bool {
        guard isLoaded, isReady, loadTask == nil, readOnlyReason == nil else {
            return false
        }
        guard let url = playlistsFileURL() else {
            if !isTerminating {
                persistenceState = .dirty(
                    revision: currentRevision,
                    lastError: .storageUnavailable
                )
            }
            return false
        }

        if currentRevision > durableRevision {
            submitCurrentSnapshot(revision: currentRevision, to: url)
        }
        guard DispatchQueue.getSpecific(key: ioQueueKey) == nil else { return false }
        guard snapshotWriter.drainSynchronously(timeout: timeout) else { return false }
        if let status = snapshotWriter.status(for: currentRevision) {
            switch status {
            case .committed(let throughRevision):
                handlePersistenceCompletion(
                    revision: throughRevision,
                    result: .success(())
                )
                return true
            case .failed(_, let failure, _):
                handlePersistenceCompletion(
                    revision: currentRevision,
                    result: .failure(failure)
                )
                return false
            }
        }
        return currentRevision <= durableRevision
    }

    // MARK: - Corruption recovery

    nonisolated private static func quarantineCorruptedFile(
        url: URL,
        data: Data,
        reason: String
    ) -> URL? {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let digest = stableDigest(data)
        var quarantineURL = directory.appendingPathComponent(
            "\(baseName).corrupted.\(digest).json"
        )

        if FileManager.default.fileExists(atPath: quarantineURL.path) {
            if (try? DerivedCacheFileIO.readBoundedRegularFile(
                at: quarantineURL,
                maximumBytes: data.count
            )) == data {
                PersistenceLogger.log(
                    "复用已存在的歌单损坏隔离文件: \(quarantineURL.lastPathComponent)"
                )
                notifyCorruptStore(reason: reason)
                return quarantineURL
            }
            quarantineURL = directory.appendingPathComponent(
                "\(baseName).corrupted.\(digest).\(UUID().uuidString).json"
            )
        }

        do {
            try DerivedCacheFileIO.atomicWrite(data, to: quarantineURL)
            PersistenceLogger.log(
                "已隔离损坏的歌单文件到: \(quarantineURL.path) (原因: \(reason))"
            )
            notifyCorruptStore(reason: reason)
            pruneCorruptDiagnostics(
                in: directory,
                baseName: baseName,
                preserving: quarantineURL
            )
            return quarantineURL
        } catch {
            PersistenceLogger.log("无法写入隔离文件 \(quarantineURL.path): \(error)")
            notifyCorruptStore(reason: reason)
            return nil
        }
    }

    nonisolated private static func pruneCorruptDiagnostics(
        in directory: URL,
        baseName: String,
        preserving preservedURL: URL
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }
        var matching: [(url: URL, modified: Date)] = []
        var inspected = 0
        for case let candidate as URL in enumerator {
            inspected += 1
            guard inspected <= 4_096 else { return }
            guard candidate.lastPathComponent.hasPrefix(baseName + ".corrupted."),
                  candidate.pathExtension == "json" else { continue }
            let modified = (try? candidate.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            matching.append((candidate, modified))
        }
        guard matching.count > 2 else { return }
        matching.sort {
            if $0.url == preservedURL { return false }
            if $1.url == preservedURL { return true }
            if $0.modified == $1.modified {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.modified < $1.modified
        }
        for item in matching.prefix(matching.count - 2) where item.url != preservedURL {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    nonisolated private static func notifyCorruptStore(reason: String) {
        DispatchQueue.main.async {
            PersistenceLogger.notifyUser(
                title: "歌单文件已损坏",
                subtitle: "原文件已保护，诊断信息: \(reason)"
            )
        }
    }

    nonisolated private static func stableDigest(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Paths and normalization

    private func playlistsFileURL() -> URL? {
        if let playlistsFileURLOverride {
            do {
                try DerivedCacheFileIO.ensureParentDirectory(for: playlistsFileURLOverride)
            } catch {
                return nil
            }
            return playlistsFileURLOverride
        }

        let fileManager = FileManager.default
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        let fileURL = directory.appendingPathComponent(playlistsFileName, isDirectory: false)
        do {
            try DerivedCacheFileIO.ensureParentDirectory(for: fileURL)
        } catch {
            return nil
        }
        return fileURL
    }

    private func normalizeTracks(from urls: [URL]) -> [UserPlaylist.Track] {
        normalizeTracks(
            urls.compactMap { url in
                guard url.isFileURL else { return nil }
                let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
                guard path.hasPrefix("/"),
                      !path.isEmpty,
                      path.utf8.count <= PlaylistStoreLimits.maximumPathBytes else { return nil }
                return UserPlaylist.Track(path: path)
            }
        )
    }

    private func normalizeTracks(
        _ tracks: [UserPlaylist.Track]
    ) -> [UserPlaylist.Track] {
        guard !tracks.isEmpty else { return [] }
        var results: [UserPlaylist.Track] = []
        results.reserveCapacity(tracks.count)
        for track in tracks {
            guard track.path.hasPrefix("/") else { continue }
            let path = URL(fileURLWithPath: track.path)
                .standardizedFileURL.path
                .precomposedStringWithCanonicalMapping
            guard !path.isEmpty,
                  path.utf8.count <= PlaylistStoreLimits.maximumPathBytes else { continue }
            results.append(
                UserPlaylist.Track(
                    id: track.id,
                    path: path,
                    signature: track.signature
                )
            )
        }
        return results
    }

    private func assigningUniqueTrackIDs(
        to tracks: [UserPlaylist.Track]
    ) -> [UserPlaylist.Track] {
        var usedIDs = Set(playlists.flatMap { $0.tracks.map(\.id) })
        return tracks.map { track in
            var id = track.id
            while !usedIDs.insert(id).inserted {
                id = UUID()
            }
            guard id != track.id else { return track }
            return UserPlaylist.Track(id: id, path: track.path, signature: track.signature)
        }
    }

    private func pathKey(_ path: String) -> String {
        PathKey.canonical(path: path)
    }

    private func mutationRejection() -> PlaylistMutationRejection? {
        if isTerminating { return .terminating }
        if let readOnlyReason { return .readOnly(readOnlyReason) }
        guard isReady, loadTask == nil else { return .loading }
        guard currentRevision < UInt64.max - 1 else {
            return .invalidInput("歌单修订号已达安全上限，请导出后重建歌单库")
        }
        return nil
    }

    nonisolated private static func isValidInputTrack(_ track: UserPlaylist.Track) -> Bool {
        let pathBytes = track.path.utf8.count
        guard track.path.hasPrefix("/"),
              pathBytes > 0,
              pathBytes <= PlaylistStoreLimits.maximumPathBytes else { return false }
        guard let signature = track.signature else { return true }
        return signature.size >= 0
            && signature.pathKey.utf8.count <= PlaylistStoreLimits.maximumPathBytes
            && (signature.fileResourceIdentifier?.utf8.count ?? 0) <= PlaylistStoreLimits.maximumPathBytes
            && (signature.volumeIdentifier?.utf8.count ?? 0) <= PlaylistStoreLimits.maximumPathBytes
    }

    nonisolated private static func validationFailure(in store: StoreFile) -> String? {
        guard store.version == 2,
              store.storeRevision < UInt64.max,
              store.playlists.count <= PlaylistStoreLimits.maximumPlaylistCount,
              store.pendingCleanup.count <= PlaylistStoreLimits.maximumCleanupIntentCount else {
            return "歌单 schema 超出安全边界"
        }

        var playlistIDs = Set<UUID>()
        var trackIDs = Set<UUID>()
        var intentIDs = Set<UUID>()
        var trackCount = 0
        var aggregatePathBytes = 0
        for playlist in store.playlists {
            guard playlistIDs.insert(playlist.id).inserted,
                  !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  playlist.name.utf8.count <= PlaylistStoreLimits.maximumNameBytes,
                  playlist.createdAt.timeIntervalSince1970.isFinite,
                  playlist.updatedAt.timeIntervalSince1970.isFinite else {
                return "歌单身份或名称无效"
            }
            trackCount += playlist.tracks.count
            guard trackCount <= PlaylistStoreLimits.maximumTrackCount else {
                return "歌曲数量超过上限"
            }
            for track in playlist.tracks {
                let bytes = track.path.utf8.count
                guard trackIDs.insert(track.id).inserted,
                      isValidInputTrack(track) else {
                    return "歌曲身份或路径无效"
                }
                aggregatePathBytes += bytes
                guard aggregatePathBytes <= PlaylistStoreLimits.maximumAggregatePathBytes else {
                    return "歌曲路径总量超过上限"
                }
            }
        }

        for intent in store.pendingCleanup {
            guard intentIDs.insert(intent.id).inserted,
                  intent.createdAt.timeIntervalSince1970.isFinite,
                  (intent.trackIDs?.count ?? 0) <= PlaylistStoreLimits.maximumTrackCount else {
                return "清理 intent 身份重复或字段无效"
            }
            if intent.kind == .deletePlaylist,
               playlistIDs.contains(intent.playlistID) {
                return "删除 intent 与当前歌单冲突"
            }
            if let trackIDs = intent.trackIDs,
               Set(trackIDs).count != trackIDs.count {
                return "清理 intent 含重复歌曲身份"
            }
            for path in intent.trackPaths {
                let bytes = path.utf8.count
                guard path.hasPrefix("/"),
                      bytes > 0,
                      bytes <= PlaylistStoreLimits.maximumPathBytes else {
                    return "清理 intent 路径无效"
                }
                aggregatePathBytes += bytes
                guard aggregatePathBytes <= PlaylistStoreLimits.maximumAggregatePathBytes else {
                    return "清理 intent 路径总量超过上限"
                }
            }
            switch intent.kind {
            case .deletePlaylist:
                guard intent.trackRelocations == nil else {
                    return "删除 intent 字段冲突"
                }
            case .removeTracks:
                guard intent.trackRelocations == nil,
                      intent.trackIDs == nil || intent.trackIDs?.count == intent.trackPaths.count else {
                    return "移除 intent 字段冲突"
                }
            case .relocateTracks:
                guard let relocations = intent.trackRelocations,
                      !relocations.isEmpty,
                      relocations.count <= PlaylistStoreLimits.maximumTrackCount,
                      relocations.count == intent.trackPaths.count,
                      intent.trackIDs == nil || intent.trackIDs?.count == relocations.count else {
                    return "重定位 intent 字段冲突"
                }
                let oldPathKeys = Set(intent.trackPaths.map { PathKey.canonical(path: $0) })
                for (index, relocation) in relocations.enumerated() {
                    let oldBytes = relocation.oldPath.utf8.count
                    let newBytes = relocation.newPath.utf8.count
                    guard relocation.oldPath.hasPrefix("/"),
                          relocation.newPath.hasPrefix("/"),
                          oldBytes > 0,
                          newBytes > 0,
                          oldBytes <= PlaylistStoreLimits.maximumPathBytes,
                          newBytes <= PlaylistStoreLimits.maximumPathBytes,
                          oldPathKeys.contains(PathKey.canonical(path: relocation.oldPath)) else {
                        return "重定位 intent 路径无效"
                    }
                    if let relocationTrackID = relocation.trackID,
                       let intentTrackIDs = intent.trackIDs,
                       intentTrackIDs[index] != relocationTrackID {
                        return "重定位 intent 歌曲身份冲突"
                    }
                    aggregatePathBytes += newBytes
                    guard aggregatePathBytes <= PlaylistStoreLimits.maximumAggregatePathBytes else {
                        return "重定位 intent 路径总量超过上限"
                    }
                }
            }
        }
        return nil
    }

    private func capacityRejection(
        addingPlaylists: Int = 0,
        addingTracks: Int = 0,
        addingPathBytes: Int = 0,
        addingCleanupIntents: Int = 0,
        candidateName: String? = nil
    ) -> PlaylistMutationRejection? {
        if let candidateName,
           (candidateName.utf8.count > PlaylistStoreLimits.maximumNameBytes
            || candidateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return .invalidInput("歌单名称过长或为空")
        }
        let currentTracks = playlists.reduce(into: 0) { $0 += $1.tracks.count }
        let currentPathBytes = playlists.reduce(into: 0) { total, playlist in
            total += playlist.tracks.reduce(into: 0) { $0 += $1.path.utf8.count }
        } + pendingCleanupIntents.reduce(into: 0) { total, intent in
            total += intent.trackPaths.reduce(into: 0) { $0 += $1.utf8.count }
            total += (intent.trackRelocations ?? []).reduce(into: 0) {
                $0 += $1.newPath.utf8.count
            }
        }
        guard addingPlaylists >= 0,
              addingTracks >= 0,
              addingPathBytes >= 0,
              addingCleanupIntents >= 0,
              playlists.count + addingPlaylists <= PlaylistStoreLimits.maximumPlaylistCount,
              currentTracks + addingTracks <= PlaylistStoreLimits.maximumTrackCount,
              pendingCleanupIntents.count + addingCleanupIntents <= PlaylistStoreLimits.maximumCleanupIntentCount,
              currentPathBytes + addingPathBytes <= PlaylistStoreLimits.maximumAggregatePathBytes else {
            return .invalidInput("歌单数据已达安全容量上限")
        }
        return nil
    }

    private func rebuildTrackGenerations(revision: UInt64) {
        trackGenerations.removeAll(keepingCapacity: true)
        for playlist in playlists {
            for track in playlist.tracks {
                trackGenerations[track.id] = revision
            }
        }
    }

    private func setTrackGenerations(
        for tracks: [UserPlaylist.Track],
        revision: UInt64
    ) {
        for track in tracks {
            trackGenerations[track.id] = revision
        }
    }
}

extension PlaylistsStore {
    func debugSetPlaylistsForTesting(
        _ items: [UserPlaylist],
        selectedID: UserPlaylist.ID? = nil
    ) {
        playlists = items
        selectedPlaylistID = selectedID ?? items.first?.id
        pendingCleanupIntents = []
        isLoaded = true
        loadTask = nil
        isReady = true
        isTerminating = false
        readOnlyReason = nil
        scheduledEnrichmentTargets = []
        currentRevision = 0
        durableRevision = 0
        rebuildTrackGenerations(revision: 0)
        snapshotWriter.seedDurableRevision(0)
        persistenceState = .ready(durableRevision: 0)
    }
}
