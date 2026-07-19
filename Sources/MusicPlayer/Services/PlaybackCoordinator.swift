import Foundation
import Combine

protocol AutomaticVolumePreanalysisClient: Sendable {
    func eligibleCandidates(in urls: [URL], limit: Int) async -> [URL]
    func nextRetryDate() -> Date?
    func runAutomaticPreanalysis(for url: URL) async throws
    func cancelAutomaticPreanalysis()
}

final class AutomaticVolumePreanalysisSnapshot: @unchecked Sendable {
    let audioFiles: [AudioFile]

    init(audioFiles: [AudioFile]) {
        // Array assignment keeps the publisher's copy-on-write storage. URL
        // extraction happens later on a detached utility task.
        self.audioFiles = audioFiles
    }
}

enum AutomaticVolumePreanalysisCandidateBuilder {
    static let maximumPageSize = 256
    static let maximumCandidatesPerRound = 2

    static func start(
        snapshot: AutomaticVolumePreanalysisSnapshot,
        client: AutomaticVolumePreanalysisClient,
        pageSize requestedPageSize: Int = maximumPageSize,
        candidateLimit requestedCandidateLimit: Int = maximumCandidatesPerRound
    ) -> Task<[URL], Never> {
        let pageSize = min(max(1, requestedPageSize), maximumPageSize)
        let candidateLimit = min(
            max(0, requestedCandidateLimit),
            maximumCandidatesPerRound
        )
        return Task.detached(priority: .utility) {
            guard candidateLimit > 0 else { return [] }
            var candidates: [URL] = []
            candidates.reserveCapacity(candidateLimit)
            var candidateKeys = Set<String>()
            candidateKeys.reserveCapacity(candidateLimit)

            var startIndex = 0
            while startIndex < snapshot.audioFiles.count {
                guard !Task.isCancelled else { return [] }
                let endIndex = min(startIndex + pageSize, snapshot.audioFiles.count)
                let page = Array(
                    snapshot.audioFiles[startIndex..<endIndex].lazy.map(\.url)
                )
                let remaining = candidateLimit - candidates.count
                let eligible = await client.eligibleCandidates(in: page, limit: remaining)
                for url in eligible {
                    guard !Task.isCancelled else { return [] }
                    let key = PathKey.canonical(for: url)
                    guard candidateKeys.insert(key).inserted else { continue }
                    candidates.append(url)
                    if candidates.count == candidateLimit { return candidates }
                }
                startIndex = endIndex
            }
            return candidates
        }
    }
}

enum AutomaticVolumePreanalysisJobs {
    static let deduplicationNamespace = "automatic-volume-preanalysis"

    static func submit(
        url: URL,
        client: AutomaticVolumePreanalysisClient,
        scheduler: BackgroundJobScheduler,
        requirements: AutomaticJobRequirements = .backgroundAnalysis
    ) async -> BackgroundJobSubmission {
        await scheduler.submit(
            lane: .audioDecode,
            priority: .background,
            mode: .automatic(requirements),
            deduplicationKey: BackgroundJobDeduplicationKey(
                namespace: deduplicationNamespace,
                value: PathKey.canonical(for: url)
            )
        ) {
            try await client.runAutomaticPreanalysis(for: url)
        }
    }
}

private final class AudioPlayerAutomaticVolumePreanalysisClient:
    AutomaticVolumePreanalysisClient,
    @unchecked Sendable
{
    private weak var audioPlayer: AudioPlayer?

    init(audioPlayer: AudioPlayer) {
        self.audioPlayer = audioPlayer
    }

    func eligibleCandidates(in urls: [URL], limit: Int) async -> [URL] {
        guard let audioPlayer, limit > 0 else { return [] }
        let validKeys = await audioPlayer.volumeNormalizationValidCacheKeysAsync(for: urls)
        var result: [URL] = []
        result.reserveCapacity(limit)
        for url in urls {
            guard !Task.isCancelled else { return [] }
            guard !validKeys.contains(PathKey.canonical(for: url)) else { continue }
            if audioPlayer.hasMissingVolumeNormalizationCache(in: CollectionOfOne(url)) {
                result.append(url)
                if result.count == limit { break }
            }
        }
        return result
    }

    func nextRetryDate() -> Date? {
        audioPlayer?.nextVolumeNormalizationRetryDate
    }

    func runAutomaticPreanalysis(for url: URL) async throws {
        guard let audioPlayer else { throw CancellationError() }
        let didStart = await MainActor.run { () -> Bool in
            guard !audioPlayer.isVolumePreanalysisRunning else { return false }
            audioPlayer.startVolumeNormalizationPreanalysis(
                urls: CollectionOfOne(url),
                reason: .autoIdle
            )
            return audioPlayer.isAutoIdleVolumePreanalysisActive
        }
        guard didStart else { return }

        do {
            while await MainActor.run(body: {
                audioPlayer.isAutoIdleVolumePreanalysisActive
            }) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
        } catch {
            await MainActor.run {
                audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
            }
            throw error
        }
    }

    func cancelAutomaticPreanalysis() {
        audioPlayer?.cancelVolumeNormalizationPreanalysisIfAutoIdle()
    }
}

/// 常驻于应用生命周期内的协调器：
/// - 负责在曲目播放完成后，自动切到下一首（不依赖任何视图是否在前台）
/// - 负责在首次添加歌曲时自动开始播放（随机或顺序）
final class PlaybackCoordinator {
    private let audioPlayer: AudioPlayer
    private let playlistManager: PlaylistManager
    private let playbackSessionStore: PlaybackSessionStore?
    private weak var playlistsStore: PlaylistsStore?
    private var cancellables: Set<AnyCancellable> = []
    private var idleVolumePreanalysisTask: Task<Void, Never>?
    private var automaticAnalysisResourceMonitorTask: Task<Void, Never>?
    private let idlePreanalysisDelaySeconds: TimeInterval
    private let backgroundJobScheduler: BackgroundJobScheduler
    private let automaticVolumeClient: AutomaticVolumePreanalysisClient
    private var automaticVolumeSnapshot = AutomaticVolumePreanalysisSnapshot(audioFiles: [])
    private var automaticVolumeSnapshotGeneration: UInt64 = 0
    private var automaticAnalysisGeneration: UInt64 = 0
    private var automaticCandidateScanExhausted = false
    private var automaticJobHandles: [UUID: BackgroundJobHandle] = [:]
    private var automaticJobWaiters: [UUID: Task<Void, Never>] = [:]
    private var nextPreloadCandidatePathKey: String? = nil
    private var nextPreloadRetryCount = 0
    private var lastHandledCompletionEventID: UInt64?
    private var playlistRelocationTask: Task<Void, Never>?
    private(set) var terminationStopGeneration: UInt64?
    private var isStoppedForTermination: Bool {
        terminationStopGeneration != nil
    }

    init(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        playlistsStore: PlaylistsStore? = nil,
        playbackSessionStore: PlaybackSessionStore? = nil,
        backgroundJobScheduler: BackgroundJobScheduler = .shared,
        idlePreanalysisDelaySeconds: TimeInterval = 60
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
        self.playbackSessionStore = playbackSessionStore
        self.backgroundJobScheduler = backgroundJobScheduler
        automaticVolumeClient = AudioPlayerAutomaticVolumePreanalysisClient(
            audioPlayer: audioPlayer
        )
        self.idlePreanalysisDelaySeconds = max(0.01, idlePreanalysisDelaySeconds)
        SystemResourceActivityState.shared.recordApplicationInteraction(
            at: audioPlayer.lastUserInteractionAt
        )
        audioPlayer.playbackFinishedHandler = { [weak self] generation, eventID, url, persist in
            self?.handlePlaybackFinished(
                generation: generation,
                completionEventID: eventID,
                url: url,
                persist: persist
            )
        }
        audioPlayer.playbackFailedHandler = { [weak self] url, message, persist in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated {
                self?.handlePlaybackFailed(url: url, message: message, persist: persist)
            }
        }
        audioPlayer.playbackLoadedHandler = { [weak self] url, persist in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated {
                self?.handlePlaybackLoaded(url: url, persist: persist)
            }
        }
        observeNotifications()
        observeIdleVolumePreanalysis()
        observeNextTrackPreloading()
    }

    /// Disconnects every event source first, then publishes cancellation to all
    /// background work owned by this coordinator. Cancellation of scheduler jobs
    /// is fire-and-forget because the termination hook must never await an actor.
    func stopForTermination(generation: UInt64) {
        if let stoppedGeneration = terminationStopGeneration,
           generation <= stoppedGeneration {
            return
        }
        terminationStopGeneration = generation

        audioPlayer.playbackFinishedHandler = nil
        audioPlayer.playbackFailedHandler = nil
        audioPlayer.playbackLoadedHandler = nil
        for cancellable in cancellables {
            cancellable.cancel()
        }
        cancellables.removeAll(keepingCapacity: false)

        playlistRelocationTask?.cancel()
        playlistRelocationTask = nil
        cancelAutomaticVolumeAnalysisWork()
        invalidateNextPreload()
        automaticVolumeSnapshot = AutomaticVolumePreanalysisSnapshot(audioFiles: [])
        automaticVolumeSnapshotGeneration &+= 1
        automaticCandidateScanExhausted = true
    }

    private func observeNotifications() {
        // 首次添加歌曲 → 自动开始播放
        NotificationCenter.default.publisher(for: .playlistDidAddFirstFiles)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.isStoppedForTermination else { return }
                if self.audioPlayer.isShuffling {
                    if let randomFile = self.playlistManager.getRandomFile() {
                        self.audioPlayer.play(randomFile)
                    }
                } else {
                    if let first = self.playlistManager.selectFile(at: 0) {
                        self.audioPlayer.play(first)
                    }
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func handlePlaybackFailed(url: URL, message: String, persist: Bool) {
        guard !isStoppedForTermination else { return }
        guard persist else { return }
        let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = raw
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "播放失败"
        playlistManager.markUnplayable(url, reason: reason)
    }

    @MainActor
    private func handlePlaybackLoaded(url: URL, persist: Bool) {
        guard !isStoppedForTermination else { return }
        if persist {
            playlistManager.clearUnplayable(url)
            if let playbackSessionStore {
                _ = playbackSessionStore.mergeInstalledTrack(
                    playlistManager.playbackSessionTrackIdentity(for: url)
                )
                let milliseconds = Self.positionMilliseconds(
                    audioPlayer.playbackClock.currentTime
                )
                _ = playbackSessionStore.mergePosition(milliseconds: milliseconds)
            }
        }
        // A successful install starts a fresh playback cycle even when the URL is
        // unchanged (for example, a one-track queue). Reset the bounded retry state
        // so that cycle can preload its next handoff normally.
        invalidateNextPreload()
    }

    private func handlePlaybackFinished(
        generation: UInt64,
        completionEventID: UInt64,
        url _: URL?,
        persist: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isStoppedForTermination else { return }
        guard generation == audioPlayer.playbackRequestGeneration else { return }
        guard completionEventID != lastHandledCompletionEventID else { return }
        lastHandledCompletionEventID = completionEventID
        guard persist else { return }
        if let nextFile = playlistManager.nextFile(isShuffling: audioPlayer.isShuffling) {
            audioPlayer.play(nextFile, bypassConfirm: true)
        }
    }

    private func observeIdleVolumePreanalysis() {
        audioPlayer.$autoPreanalyzeVolumesWhenIdle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled {
                    self.cancelAutomaticVolumeAnalysisWork()
                }
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        audioPlayer.$lastUserInteractionAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.isStoppedForTermination else { return }
                SystemResourceActivityState.shared.recordApplicationInteraction(
                    at: self.audioPlayer.lastUserInteractionAt
                )
                // User activity invalidates rebuildable automatic work. Manual
                // analysis remains owned exclusively by AudioPlayer.
                self.cancelAutomaticVolumeAnalysisWork()
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        audioPlayer.$isNormalizationEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.cancelAutomaticVolumeAnalysisWork()
                }
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        audioPlayer.$isPlaying
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handlePlaybackActivityChanged() }
            .store(in: &cancellables)

        audioPlayer.$isPlaybackRequested
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handlePlaybackActivityChanged() }
            .store(in: &cancellables)

        audioPlayer.$isVolumePreanalysisRunning
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self, !self.isStoppedForTermination else { return }
                if isRunning {
                    if self.audioPlayer.isAutoIdleVolumePreanalysisActive {
                        self.startAutomaticAnalysisResourceMonitorIfNeeded()
                    } else {
                        self.cancelAutomaticVolumeAnalysisWork()
                    }
                }
                if !isRunning, self.automaticJobHandles.isEmpty {
                    self.scheduleIdleVolumePreanalysisIfNeeded()
                }
            }
            .store(in: &cancellables)

        playlistManager.$audioFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioFiles in
                self?.replaceAutomaticVolumeSnapshot(with: audioFiles)
                self?.scheduleIdleVolumePreanalysisIfNeeded()
                self?.schedulePlaylistRelocationIfNeeded()
            }
            .store(in: &cancellables)

        audioPlayer.$volumeNormalizationCacheCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                guard let self, !self.isStoppedForTermination, count == 0,
                      self.automaticJobHandles.isEmpty else { return }
                self.automaticCandidateScanExhausted = false
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleSystemResourceStateChanged() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleSystemResourceStateChanged() }
            .store(in: &cancellables)
    }

    private func schedulePlaylistRelocationIfNeeded() {
        guard !isStoppedForTermination, playlistsStore != nil else { return }
        let lifecycleGeneration = terminationStopGeneration
        playlistRelocationTask?.cancel()
        playlistRelocationTask = Task { @MainActor [weak self] in
            guard let self, let playlistsStore = self.playlistsStore else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.terminationStopGeneration == lifecycleGeneration else { return }
            await playlistsStore.ensureLoaded()
            guard !Task.isCancelled,
                  self.terminationStopGeneration == lifecycleGeneration else { return }
            let candidates = self.playlistManager.fileRelocationCandidatesSnapshot()
            guard !candidates.isEmpty, !Task.isCancelled else { return }
            let mutation = playlistsStore.relocateMissingTracksResult(using: candidates)
            switch await playlistsStore.awaitDurability(of: mutation) {
            case .committed(let summary):
                if summary.relocatedTrackCount > 0 {
                    PersistenceLogger.log("已按文件身份恢复 \(summary.relocatedTrackCount) 个歌单路径")
                }
            case .unchanged:
                break
            case .rejected(let rejection):
                PersistenceLogger.log("歌单路径恢复未执行：\(rejection.diagnosticMessage)")
            case .persistenceFailed(let failure):
                PersistenceLogger.log("歌单路径恢复尚未持久化：\(failure.diagnosticMessage)")
            }
        }
    }

    private func handlePlaybackActivityChanged() {
        guard !isStoppedForTermination else { return }
        if audioPlayer.isPlaying || audioPlayer.isPlaybackRequested {
            cancelAutomaticVolumeAnalysisWork()
        }
        scheduleIdleVolumePreanalysisIfNeeded()
    }

    private func handleSystemResourceStateChanged() {
        guard !isStoppedForTermination else { return }
        let scheduler = backgroundJobScheduler
        Task {
            await scheduler.resourcesDidChange()
        }
        scheduleIdleVolumePreanalysisIfNeeded()
    }

    private func startAutomaticAnalysisResourceMonitorIfNeeded() {
        guard !isStoppedForTermination,
              automaticAnalysisResourceMonitorTask == nil,
              !automaticJobHandles.isEmpty else { return }
        let generation = automaticAnalysisGeneration
        automaticAnalysisResourceMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while generation == self.automaticAnalysisGeneration,
                  !self.automaticJobHandles.isEmpty {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.backgroundJobScheduler.resourcesDidChange()
            }
            if generation == self.automaticAnalysisGeneration {
                self.automaticAnalysisResourceMonitorTask = nil
            }
        }
    }

    private func systemIdleDuration() -> TimeInterval {
        SystemResourceSnapshotProvider.liveSystemIdleDuration()
    }

    private func replaceAutomaticVolumeSnapshot(with audioFiles: [AudioFile]) {
        guard !isStoppedForTermination else { return }
        cancelAutomaticVolumeAnalysisWork()
        automaticVolumeSnapshot = AutomaticVolumePreanalysisSnapshot(audioFiles: audioFiles)
        automaticVolumeSnapshotGeneration &+= 1
        automaticCandidateScanExhausted = false
    }

    private func cancelAutomaticVolumeAnalysisWork() {
        automaticAnalysisGeneration &+= 1
        idleVolumePreanalysisTask?.cancel()
        idleVolumePreanalysisTask = nil
        automaticAnalysisResourceMonitorTask?.cancel()
        automaticAnalysisResourceMonitorTask = nil

        let handles = Array(automaticJobHandles.values)
        automaticJobHandles.removeAll(keepingCapacity: false)
        let waiters = Array(automaticJobWaiters.values)
        automaticJobWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.cancel() }

        automaticVolumeClient.cancelAutomaticPreanalysis()
        guard !handles.isEmpty else { return }
        Task {
            for handle in handles {
                await handle.cancel()
            }
        }
    }

    private func automaticAnalysisStateAllowsScheduling() -> Bool {
        !isStoppedForTermination
            && audioPlayer.autoPreanalyzeVolumesWhenIdle
            && audioPlayer.isNormalizationEnabled
            && !audioPlayer.isPlaying
            && !audioPlayer.isPlaybackRequested
            && !audioPlayer.isVolumePreanalysisRunning
            && !automaticVolumeSnapshot.audioFiles.isEmpty
    }

    private func scheduleIdleVolumePreanalysisIfNeeded() {
        guard !isStoppedForTermination else { return }
        guard automaticAnalysisStateAllowsScheduling() else { return }
        guard automaticJobHandles.isEmpty,
              idleVolumePreanalysisTask == nil else { return }

        let waitSeconds: TimeInterval
        if automaticCandidateScanExhausted {
            guard let retryDate = automaticVolumeClient.nextRetryDate() else { return }
            waitSeconds = max(
                idlePreanalysisDelaySeconds,
                retryDate.timeIntervalSinceNow
            )
        } else {
            waitSeconds = idlePreanalysisDelaySeconds
        }

        let snapshot = automaticVolumeSnapshot
        let snapshotGeneration = automaticVolumeSnapshotGeneration
        let analysisGeneration = automaticAnalysisGeneration
        let sleepNanoseconds = UInt64(
            min(waitSeconds, 24 * 60 * 60) * 1_000_000_000
        )
        idleVolumePreanalysisTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  snapshotGeneration == self.automaticVolumeSnapshotGeneration,
                  analysisGeneration == self.automaticAnalysisGeneration,
                  self.automaticAnalysisStateAllowsScheduling() else { return }

            let applicationIdleFor = SystemResourceActivityState.shared
                .applicationIdleDuration()
            let systemIdleFor = self.systemIdleDuration()
            if min(applicationIdleFor, systemIdleFor) < self.idlePreanalysisDelaySeconds {
                self.idleVolumePreanalysisTask = nil
                self.scheduleIdleVolumePreanalysisIfNeeded()
                return
            }

            let builder = AutomaticVolumePreanalysisCandidateBuilder.start(
                snapshot: snapshot,
                client: self.automaticVolumeClient
            )
            let candidates = await withTaskCancellationHandler(operation: {
                await builder.value
            }, onCancel: {
                builder.cancel()
            })
            guard !Task.isCancelled,
                  snapshotGeneration == self.automaticVolumeSnapshotGeneration,
                  analysisGeneration == self.automaticAnalysisGeneration,
                  self.automaticAnalysisStateAllowsScheduling() else { return }

            guard !candidates.isEmpty else {
                self.automaticCandidateScanExhausted = true
                self.idleVolumePreanalysisTask = nil
                self.scheduleIdleVolumePreanalysisIfNeeded()
                return
            }
            self.automaticCandidateScanExhausted = false
            await self.submitAutomaticVolumeCandidates(
                candidates,
                analysisGeneration: analysisGeneration,
                snapshotGeneration: snapshotGeneration
            )
            guard analysisGeneration == self.automaticAnalysisGeneration,
                  snapshotGeneration == self.automaticVolumeSnapshotGeneration else {
                return
            }
            self.idleVolumePreanalysisTask = nil
            if self.automaticJobHandles.isEmpty {
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
        }
    }

    @MainActor
    private func submitAutomaticVolumeCandidates(
        _ candidates: [URL],
        analysisGeneration: UInt64,
        snapshotGeneration: UInt64
    ) async {
        for url in candidates.prefix(
            AutomaticVolumePreanalysisCandidateBuilder.maximumCandidatesPerRound
        ) {
            guard !isStoppedForTermination,
                  analysisGeneration == automaticAnalysisGeneration,
                  snapshotGeneration == automaticVolumeSnapshotGeneration,
                  automaticAnalysisStateAllowsScheduling() else { return }
            let submission = await AutomaticVolumePreanalysisJobs.submit(
                url: url,
                client: automaticVolumeClient,
                scheduler: backgroundJobScheduler
            )
            guard !isStoppedForTermination,
                  analysisGeneration == automaticAnalysisGeneration,
                  snapshotGeneration == automaticVolumeSnapshotGeneration else {
                if let handle = submission.handle { await handle.cancel() }
                return
            }
            guard let handle = submission.handle,
                  automaticJobHandles[handle.id] == nil else { continue }
            automaticJobHandles[handle.id] = handle
            automaticJobWaiters[handle.id] = Task { @MainActor [weak self] in
                let outcome = await handle.value()
                guard !Task.isCancelled else { return }
                self?.automaticVolumeJobFinished(
                    handleID: handle.id,
                    generation: analysisGeneration,
                    outcome: outcome
                )
            }
        }
        startAutomaticAnalysisResourceMonitorIfNeeded()
    }

    private func automaticVolumeJobFinished(
        handleID: UUID,
        generation: UInt64,
        outcome _: BackgroundJobOutcome
    ) {
        guard !isStoppedForTermination,
              generation == automaticAnalysisGeneration else { return }
        automaticJobHandles.removeValue(forKey: handleID)
        automaticJobWaiters.removeValue(forKey: handleID)
        guard automaticJobHandles.isEmpty else { return }
        automaticAnalysisResourceMonitorTask?.cancel()
        automaticAnalysisResourceMonitorTask = nil
        scheduleIdleVolumePreanalysisIfNeeded()
    }

    private func observeNextTrackPreloading() {
        // 当前曲目变化/列表变化：丢弃旧预加载（避免预加载到“已经不是下一首”的曲目）
        audioPlayer.$currentFile
            .map { file in file.map { PathKey.canonical(for: $0.url) } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        playlistManager.$audioFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        audioPlayer.$playbackMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        audioPlayer.$isImmersivePlaybackEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        playlistManager.$playbackScope
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        playlistManager.$unplayableReasons
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .playbackWeightsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStoppedForTermination else { return }
                self.invalidateNextPreload()
            }
            .store(in: &cancellables)

        // 播放接近结束时：预加载下一首
        audioPlayer.playbackClock.$currentTime
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] currentTime in
                guard let self else { return }
                self.maybePreloadNextTrack(currentTime: currentTime)
            }
            .store(in: &cancellables)

        audioPlayer.playbackClock.$currentTime
            .throttle(for: .seconds(10), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] currentTime in
                guard let self,
                      !self.isStoppedForTermination,
                      self.audioPlayer.persistPlaybackState,
                      self.audioPlayer.currentFile != nil,
                      let playbackSessionStore = self.playbackSessionStore else { return }
                _ = playbackSessionStore.mergePosition(
                    milliseconds: Self.positionMilliseconds(currentTime)
                )
            }
            .store(in: &cancellables)
    }

    private static func positionMilliseconds(_ seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(Double(Int64.max), seconds * 1_000).rounded())
    }

    private func invalidateNextPreload() {
        nextPreloadCandidatePathKey = nil
        nextPreloadRetryCount = 0
        audioPlayer.cancelNextPreload()
    }

    private func maybePreloadNextTrack(currentTime: TimeInterval) {
        guard !isStoppedForTermination, audioPlayer.isPlaying else { return }
        // A replacement load already holds the old installed player plus the new
        // target being constructed. Do not allocate a third AVAudioPlayer for a
        // speculative next track that will be invalidated as soon as the target
        // installs; this keeps the steady-state bound at current + one preload.
        guard audioPlayer.pendingPlaybackURL == nil else { return }
        // 临时播放（外部打开文件）时，不进行播放列表预加载
        guard audioPlayer.persistPlaybackState else { return }
        // 单曲循环：不会切歌
        guard !audioPlayer.isLooping else { return }
        guard audioPlayer.currentFile != nil else { return }

        let physicalDuration = audioPlayer.playbackClock.duration
        guard physicalDuration > 0, physicalDuration.isFinite else { return }
        let playbackEnd = audioPlayer.effectivePlaybackEndTime
        guard playbackEnd > 0, playbackEnd.isFinite else { return }

        let remaining = playbackEnd - currentTime
        guard remaining.isFinite else { return }

        // 预加载窗口：最少 8s、最多 30s，并随曲目长度适配（长歌不会太早触发）
        let threshold = min(30.0, max(8.0, playbackEnd * 0.1))
        guard remaining <= threshold else { return }

        guard let next = playlistManager.peekNextFile(isShuffling: audioPlayer.isShuffling) else { return }
        let key = PathKey.canonical(for: next.url)
        if nextPreloadCandidatePathKey != key {
            nextPreloadCandidatePathKey = key
            nextPreloadRetryCount = 0
            audioPlayer.preloadNextTrack(next)
        } else if !audioPlayer.hasNextPreloadPlan(for: next.url), nextPreloadRetryCount < 1 {
            nextPreloadRetryCount += 1
            audioPlayer.preloadNextTrack(next)
        }
    }
}
