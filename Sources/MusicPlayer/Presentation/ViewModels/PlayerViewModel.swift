import Combine
import SwiftUI

/// 左侧“正在播放”面板的展示层状态与命令集合。
///
/// 不持有业务持久化逻辑，只把 `AudioPlayer`、`PlaylistManager` 和 `PlaybackWeights`
/// 的状态转发给 PlayerView，并提供与 UI 直接对应的便捷方法。
@MainActor
final class PlayerViewModel: ObservableObject {
    let audioPlayer: AudioPlayer
    let playlistManager: PlaylistManager
    let weights: PlaybackWeights

    @Published private(set) var nextUpFile: AudioFile?

    private var cancellables = Set<AnyCancellable>()

    init(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        weights: PlaybackWeights = .shared
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.weights = weights

        Publishers.MergeMany([
            audioPlayer.objectWillChange,
            playlistManager.objectWillChange,
            weights.objectWillChange
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.refreshNextUpFile()
        }
        .store(in: &cancellables)

        refreshNextUpFile()
    }

    // MARK: - Presentation Helpers

    var isAddingFiles: Bool { playlistManager.isAddingFiles }
    var addFilesPhase: String { playlistManager.addFilesPhase }
    var addFilesDetail: String { playlistManager.addFilesDetail }
    var addFilesProgressCurrent: Int { playlistManager.addFilesProgressCurrent }
    var addFilesProgressTotal: Int { playlistManager.addFilesProgressTotal }

    var currentFile: AudioFile? { audioPlayer.currentFile }
    var persistPlaybackState: Bool { audioPlayer.persistPlaybackState }

    var showLyrics: Bool {
        get { audioPlayer.showLyrics }
        set { audioPlayer.showLyrics = newValue }
    }

    var hasLyrics: Bool { audioPlayer.lyricsTimeline != nil }

    func weightScope() -> PlaybackWeights.Scope {
        switch playlistManager.playbackScope {
        case .queue:
            return .queue
        case .playlist(let id):
            return .playlist(id)
        }
    }

    func weightScopeLabel() -> String {
        switch playlistManager.playbackScope {
        case .queue:
            return "队列"
        case .playlist:
            return "歌单"
        }
    }

    func weightLevel() -> PlaybackWeights.Level {
        guard let current = audioPlayer.currentFile else { return .defaultLevel }
        return weights.level(for: current.url, scope: weightScope())
    }

    func setWeightLevel(_ level: PlaybackWeights.Level) {
        guard let current = audioPlayer.currentFile else { return }
        let result = weights.setLevel(level, for: current.url, scope: weightScope())
        WeightCommands.handleSetWeightResult(result)
    }

    func cancelAddFiles() {
        playlistManager.cancelAddFiles()
    }

    func seek(to time: TimeInterval) {
        audioPlayer.seek(to: time)
    }

    func setPlaybackRate(_ rate: Float) {
        audioPlayer.setPlaybackRate(rate)
    }

    func playRandomTrack() {
        guard audioPlayer.persistPlaybackState else { return }
        if let randomFile = playlistManager.getRandomFileExcludingCurrent() {
            audioPlayer.play(randomFile)
        }
    }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }

    func playNext() {
        if let next = playlistManager.nextFile(isShuffling: audioPlayer.playbackMode == .shuffle) {
            audioPlayer.play(next)
        }
    }

    func playPrevious() {
        if let previous = playlistManager.previousFile(isShuffling: audioPlayer.playbackMode == .shuffle) {
            audioPlayer.play(previous)
        }
    }

    // MARK: - Next Up

    func refreshNextUpFile() {
        guard audioPlayer.persistPlaybackState, let current = audioPlayer.currentFile else {
            nextUpFile = nil
            return
        }

        if audioPlayer.playbackMode == .repeatOne {
            nextUpFile = current
            return
        }

        nextUpFile = playlistManager.peekNextFile(isShuffling: true)
    }
}
