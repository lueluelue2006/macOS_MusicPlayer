import Foundation
import Combine
import CoreGraphics

/// 常驻于应用生命周期内的协调器：
/// - 负责在曲目播放完成后，自动切到下一首（不依赖任何视图是否在前台）
/// - 负责在首次添加歌曲时自动开始播放（随机或顺序）
final class PlaybackCoordinator {
    private let audioPlayer: AudioPlayer
    private let playlistManager: PlaylistManager
    private weak var playlistsStore: PlaylistsStore?
    private var cancellables: Set<AnyCancellable> = []
    private var idleVolumePreanalysisTask: Task<Void, Never>?
    private var automaticAnalysisActivityMonitorTask: Task<Void, Never>?
    private let idlePreanalysisDelaySeconds: TimeInterval = 60
    private var nextPreloadCandidatePathKey: String? = nil
    private var nextPreloadRetryCount = 0
    private var lastHandledCompletionEventID: UInt64?
    private var playlistRelocationTask: Task<Void, Never>?

    init(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        playlistsStore: PlaylistsStore? = nil
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
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

    private func observeNotifications() {
        // 首次添加歌曲 → 自动开始播放
        NotificationCenter.default.publisher(for: .playlistDidAddFirstFiles)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
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
        if persist {
            playlistManager.clearUnplayable(url)
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
                    self.idleVolumePreanalysisTask?.cancel()
                    self.idleVolumePreanalysisTask = nil
                    self.audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
                }
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        audioPlayer.$lastUserInteractionAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // 用户有操作：取消“空闲等待计时”，并停止自动空闲预分析（手动预分析不受影响）
                self.idleVolumePreanalysisTask?.cancel()
                self.idleVolumePreanalysisTask = nil
                self.audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
                self.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        audioPlayer.$isNormalizationEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.idleVolumePreanalysisTask?.cancel()
                    self.idleVolumePreanalysisTask = nil
                    self.audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
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
                guard let self else { return }
                if isRunning, self.audioPlayer.isAutoIdleVolumePreanalysisActive {
                    self.startAutomaticAnalysisActivityMonitor()
                } else {
                    self.automaticAnalysisActivityMonitorTask?.cancel()
                    self.automaticAnalysisActivityMonitorTask = nil
                }
                if !isRunning {
                    self.scheduleIdleVolumePreanalysisIfNeeded()
                }
            }
            .store(in: &cancellables)

        playlistManager.$audioFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleIdleVolumePreanalysisIfNeeded()
                self?.schedulePlaylistRelocationIfNeeded()
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
        guard playlistsStore != nil else { return }
        playlistRelocationTask?.cancel()
        playlistRelocationTask = Task { @MainActor [weak self] in
            guard let self, let playlistsStore = self.playlistsStore else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await playlistsStore.ensureLoaded()
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
        idleVolumePreanalysisTask?.cancel()
        idleVolumePreanalysisTask = nil
        if audioPlayer.isPlaying || audioPlayer.isPlaybackRequested {
            audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
        }
        scheduleIdleVolumePreanalysisIfNeeded()
    }

    private func handleSystemResourceStateChanged() {
        idleVolumePreanalysisTask?.cancel()
        idleVolumePreanalysisTask = nil
        if !systemAllowsAutomaticAnalysis() {
            audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
        }
        scheduleIdleVolumePreanalysisIfNeeded()
    }

    private func startAutomaticAnalysisActivityMonitor() {
        automaticAnalysisActivityMonitorTask?.cancel()
        automaticAnalysisActivityMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.audioPlayer.isAutoIdleVolumePreanalysisActive {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard self.audioPlayer.isAutoIdleVolumePreanalysisActive else { return }
                if self.systemIdleDuration() < 1.5 {
                    self.audioPlayer.cancelVolumeNormalizationPreanalysisIfAutoIdle()
                    return
                }
            }
        }
    }

    private func systemIdleDuration() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .flagsChanged,
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        return eventTypes
            .map {
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: $0
                )
            }
            .min() ?? 0
    }

    private func systemAllowsAutomaticAnalysis() -> Bool {
        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled else { return false }
        switch processInfo.thermalState {
        case .nominal:
            return true
        case .fair, .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }

    private func scheduleIdleVolumePreanalysisIfNeeded() {
        guard audioPlayer.autoPreanalyzeVolumesWhenIdle else { return }
        guard audioPlayer.isNormalizationEnabled else { return }
        guard !audioPlayer.isPlaying, !audioPlayer.isPlaybackRequested else { return }
        guard !audioPlayer.isVolumePreanalysisRunning else { return }
        guard systemAllowsAutomaticAnalysis() else { return }
        guard !playlistManager.audioFiles.isEmpty else { return }
        let urls = playlistManager.audioFiles.lazy.map(\.url)
        let hasEligibleWork = audioPlayer.hasMissingVolumeNormalizationCache(in: urls)
        let waitSeconds: TimeInterval
        if hasEligibleWork {
            waitSeconds = idlePreanalysisDelaySeconds
        } else if let retryDate = audioPlayer.nextVolumeNormalizationRetryDate {
            waitSeconds = max(
                idlePreanalysisDelaySeconds,
                retryDate.timeIntervalSinceNow
            )
        } else {
            return
        }

        idleVolumePreanalysisTask?.cancel()
        idleVolumePreanalysisTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            } catch {
                return
            }
            if Task.isCancelled { return }
            self.idleVolumePreanalysisTask = nil
            let applicationIdleFor = Date().timeIntervalSince(self.audioPlayer.lastUserInteractionAt)
            let systemIdleFor = self.systemIdleDuration()
            if min(applicationIdleFor, systemIdleFor) < self.idlePreanalysisDelaySeconds {
                // Global activity may happen outside this app, so no local event will
                // reschedule us. Poll once per cooldown until the whole system is idle.
                self.scheduleIdleVolumePreanalysisIfNeeded()
                return
            }
            if !self.audioPlayer.autoPreanalyzeVolumesWhenIdle { return }
            if !self.audioPlayer.isNormalizationEnabled { return }
            if self.audioPlayer.isPlaying || self.audioPlayer.isPlaybackRequested { return }
            if !self.systemAllowsAutomaticAnalysis() { return }
            if self.audioPlayer.isVolumePreanalysisRunning { return }

            let urls = self.playlistManager.audioFiles.lazy.map(\.url)
            if !self.audioPlayer.hasMissingVolumeNormalizationCache(in: urls) {
                self.scheduleIdleVolumePreanalysisIfNeeded()
                return
            }
            self.audioPlayer.startVolumeNormalizationPreanalysis(urls: urls, reason: .autoIdle)
        }
    }

    private func observeNextTrackPreloading() {
        // 当前曲目变化/列表变化：丢弃旧预加载（避免预加载到“已经不是下一首”的曲目）
        audioPlayer.$currentFile
            .map { file in file.map { PathKey.canonical(for: $0.url) } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateNextPreload()
            }
            .store(in: &cancellables)

        playlistManager.$audioFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateNextPreload()
            }
            .store(in: &cancellables)

        audioPlayer.$playbackMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidateNextPreload() }
            .store(in: &cancellables)

        audioPlayer.$isImmersivePlaybackEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidateNextPreload() }
            .store(in: &cancellables)

        playlistManager.$playbackScope
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidateNextPreload() }
            .store(in: &cancellables)

        playlistManager.$unplayableReasons
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidateNextPreload() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .playbackWeightsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidateNextPreload() }
            .store(in: &cancellables)

        // 播放接近结束时：预加载下一首
        audioPlayer.playbackClock.$currentTime
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] currentTime in
                guard let self else { return }
                self.maybePreloadNextTrack(currentTime: currentTime)
            }
            .store(in: &cancellables)
    }

    private func invalidateNextPreload() {
        nextPreloadCandidatePathKey = nil
        nextPreloadRetryCount = 0
        audioPlayer.cancelNextPreload()
    }

    private func maybePreloadNextTrack(currentTime: TimeInterval) {
        guard audioPlayer.isPlaying else { return }
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
