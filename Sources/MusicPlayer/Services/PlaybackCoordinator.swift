import Foundation
import Combine

/// 常驻于应用生命周期内的协调器：
/// - 负责在曲目播放完成后，自动切到下一首（不依赖任何视图是否在前台）
/// - 负责在首次添加歌曲时自动开始播放（随机或顺序）
final class PlaybackCoordinator {
    private let audioPlayer: AudioPlayer
    private let playlistManager: PlaylistManager
    private var cancellables: Set<AnyCancellable> = []
    private var idleVolumePreanalysisTask: Task<Void, Never>?
    private let idlePreanalysisDelaySeconds: TimeInterval = 10

    init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        observeNotifications()
        observeIdleVolumePreanalysis()
    }

    private func observeNotifications() {
        // 播放完成 → 自动下一首
        NotificationCenter.default.publisher(for: .audioPlayerDidFinish)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // 临时播放（外部打开文件）时，不进行播放列表的自动切换
                if self.audioPlayer.persistPlaybackState == false { return }
                if let nextFile = self.playlistManager.nextFile(isShuffling: self.audioPlayer.isShuffling) {
                    self.audioPlayer.play(nextFile, bypassConfirm: true)
                }
            }
            .store(in: &cancellables)

        // 播放失败/解码失败 → 标记不可播放（仅对播放列表模式生效）
        NotificationCenter.default.publisher(for: .audioPlayerDidFailToPlay)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                // 临时播放（外部打开文件）不进入播放列表，也不标记
                if self.audioPlayer.persistPlaybackState == false { return }
                guard
                    let userInfo = notification.userInfo,
                    let url = userInfo["url"] as? URL
                else { return }
                let raw = (userInfo["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "播放失败"
                let reason = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
                Task { @MainActor [weak self] in
                    self?.playlistManager.markUnplayable(url, reason: reason)
                }
            }
            .store(in: &cancellables)

        // 读取成功 → 自动清除不可播放标记（便于“修复文件后重试”）
        NotificationCenter.default.publisher(for: .audioPlayerDidLoadFile)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if self.audioPlayer.persistPlaybackState == false { return }
                guard
                    let userInfo = notification.userInfo,
                    let url = userInfo["url"] as? URL
                else { return }
                Task { @MainActor [weak self] in
                    self?.playlistManager.clearUnplayable(url)
                }
            }
            .store(in: &cancellables)

        // 首次添加歌曲 → 自动开始播放
        NotificationCenter.default.publisher(for: .playlistDidAddFirstFiles)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.audioPlayer.isShuffling {
                    if let randomFile = self.playlistManager.getRandomFile() {
                        self.audioPlayer.play(randomFile, bypassConfirm: true)
                    }
                } else {
                    if let first = self.playlistManager.selectFile(at: 0) {
                        self.audioPlayer.play(first, bypassConfirm: true)
                    }
                }
            }
            .store(in: &cancellables)
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
            .sink { [weak self] _ in
                self?.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)

        playlistManager.$audioFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleIdleVolumePreanalysisIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func scheduleIdleVolumePreanalysisIfNeeded() {
        guard audioPlayer.autoPreanalyzeVolumesWhenIdle else { return }
        guard audioPlayer.isNormalizationEnabled else { return }
        guard !playlistManager.audioFiles.isEmpty else { return }
        guard !audioPlayer.isVolumePreanalysisRunning else { return }

        idleVolumePreanalysisTask?.cancel()
        idleVolumePreanalysisTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.idlePreanalysisDelaySeconds * 1_000_000_000))
            } catch {
                return
            }
            if Task.isCancelled { return }
            let idleFor = Date().timeIntervalSince(self.audioPlayer.lastUserInteractionAt)
            if idleFor < self.idlePreanalysisDelaySeconds { return }
            if !self.audioPlayer.autoPreanalyzeVolumesWhenIdle { return }
            if !self.audioPlayer.isNormalizationEnabled { return }
            if self.audioPlayer.isVolumePreanalysisRunning { return }

            let urls = self.playlistManager.audioFiles.map { $0.url }
            self.audioPlayer.startVolumeNormalizationPreanalysis(urls: urls, reason: .autoIdle)
        }
    }
}
