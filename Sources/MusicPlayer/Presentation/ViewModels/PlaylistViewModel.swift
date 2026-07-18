import Combine
import SwiftUI

/// 右侧“队列 / 歌单”面板的展示层状态与命令集合。
@MainActor
final class PlaylistViewModel: ObservableObject {
    let audioPlayer: AudioPlayer
    let playlistManager: PlaylistManager
    let playlistsStore: PlaylistsStore
    let sortState: SearchSortState
    let weights: PlaybackWeights

    @AppStorage("userPlaylistPanelMode") private var panelModeRaw: Int = PanelMode.queue.rawValue
    @Published private(set) var queueVisibleFiles: [AudioFile] = []
    @Published private(set) var queueVisibleRevision: UInt64 = 0
    @Published var queueScrollTargetID: String?

    private var queueRefreshTask: Task<Void, Never>?
    private var queueScrollTask: Task<Void, Never>?

    private enum PanelMode: Int {
        case queue = 0
        case playlists = 1
    }

    var panelMode: PanelMode {
        get { PanelMode(rawValue: panelModeRaw) ?? .queue }
        set { panelModeRaw = newValue.rawValue }
    }

    var isQueueSelected: Bool { panelMode == .queue }
    var isPlaylistsSelected: Bool { panelMode == .playlists }

    var scanSubfoldersBinding: Binding<Bool> {
        Binding(
            get: { playlistManager.scanSubfolders },
            set: { playlistManager.scanSubfolders = $0 }
        )
    }

    var queueSearchTextBinding: Binding<String> {
        Binding(
            get: { playlistManager.searchText },
            set: { updateQueueSearch($0) }
        )
    }

    var queueSourceFiles: [AudioFile] {
        playlistManager.searchText.isEmpty ? playlistManager.audioFiles : playlistManager.filteredFiles
    }

    var displayedQueueFiles: [AudioFile] {
        if !queueVisibleFiles.isEmpty || queueSourceFiles.isEmpty {
            return queueVisibleFiles
        }
        return sortState.option(for: .queue).applying(to: queueSourceFiles, weightScope: .queue)
    }

    var currentHighlightedURL: URL? {
        if audioPlayer.persistPlaybackState,
           playlistManager.currentIndex >= 0,
           playlistManager.currentIndex < playlistManager.audioFiles.count
        {
            return playlistManager.audioFiles[playlistManager.currentIndex].url
        }
        return audioPlayer.currentFile?.url
    }

    struct PlaybackScopeBadge {
        let title: String
        let targetPanel: PanelMode
        let help: String
    }

    var activePlaybackScopeBadge: PlaybackScopeBadge? {
        guard audioPlayer.playbackTargetURL != nil, audioPlayer.persistPlaybackState else { return nil }

        switch playlistManager.playbackScope {
        case .queue:
            return PlaybackScopeBadge(
                title: "播放中：队列",
                targetPanel: .queue,
                help: "当前播放范围为队列，下一首/随机将作用于队列"
            )
        case .playlist(let id):
            let name = playlistsStore.playlist(for: id)?.name ?? "歌单"
            return PlaybackScopeBadge(
                title: "播放中：\(name)",
                targetPanel: .playlists,
                help: "当前播放范围为歌单，下一首/随机将作用于该歌单"
            )
        }
    }

    var scopeIndicatorSystemName: String {
        audioPlayer.playbackMode == .repeatOne ? "repeat" : "shuffle"
    }

    init(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        playlistsStore: PlaylistsStore,
        sortState: SearchSortState = .shared,
        weights: PlaybackWeights = .shared
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
        self.sortState = sortState
        self.weights = weights

        // 转发服务状态变化，让 SwiftUI 重新渲染；但不在这里刷新派生列表，
        // 避免 @Published 更新触发递归刷新。
        Publishers.MergeMany([
            audioPlayer.objectWillChange,
            playlistManager.objectWillChange,
            playlistsStore.objectWillChange,
            sortState.objectWillChange,
            weights.objectWillChange
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)

        // 队列可见列表只在真正影响它的数据变化时刷新。
        Publishers.MergeMany([
            playlistManager.$audioFiles.map { _ in () }.eraseToAnyPublisher(),
            playlistManager.$filteredFiles.map { _ in () }.eraseToAnyPublisher(),
            playlistManager.$isInitialRestorePending.map { _ in () }.eraseToAnyPublisher(),
            playlistManager.$isRestoringPlaylist.map { _ in () }.eraseToAnyPublisher(),
            sortState.$revision.map { _ in () }.eraseToAnyPublisher(),
            weights.$revision.map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshQueueVisibleFiles()
        }
        .store(in: &cancellables)

        refreshQueueVisibleFiles()
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Panel Switching

    func switchToQueue() {
        panelMode = .queue
        blurSearchField()
        refreshQueueVisibleFiles()
    }

    func switchToPlaylists() {
        panelMode = .playlists
        blurSearchField()
    }

    func handleScopeBadgeTap(_ badge: PlaybackScopeBadge) {
        panelMode = badge.targetPanel
        blurSearchField()
        if panelMode == .queue {
            refreshQueueVisibleFiles()
        }
    }

    // MARK: - Queue Actions

    func enqueueFiles(_ urls: [URL]) {
        playlistManager.enqueueAddFiles(urls)
    }

    func clearQueue() {
        playlistManager.clearAllFiles()
        audioPlayer.stopAndClearCurrent()
    }

    func refreshAllMetadata() {
        Task {
            await playlistManager.refreshAllMetadata(audioPlayer: audioPlayer)
        }
    }

    func playQueueTrack(_ file: AudioFile) {
        blurSearchField()
        playlistManager.setPlaybackScopeQueue()
        guard let index = playlistManager.audioFiles.firstIndex(of: file),
              let selected = playlistManager.selectFile(at: index)
        else { return }
        audioPlayer.selectOrResume(selected)
    }

    func removeQueueTrack(_ file: AudioFile) {
        blurSearchField()
        PlaylistCommands.removeTrackFromQueue(file, manager: playlistManager, player: audioPlayer)
    }

    func weightLevel(for file: AudioFile) -> PlaybackWeights.Level {
        weights.level(for: file.url, scope: .queue)
    }

    func setQueueWeightLevel(_ level: PlaybackWeights.Level, for file: AudioFile) {
        let result = weights.setLevel(level, for: file.url, scope: .queue)
        WeightCommands.handleSetWeightResult(result)
    }

    // MARK: - Scroll

    func nowPlayingIDInQueue() -> String? {
        guard let url = currentHighlightedURL else { return nil }
        let id = PathKey.canonical(for: url)
        let idLookup = Set(PathKey.lookupKeys(for: url))
        guard playlistManager.audioFiles.contains(where: {
            !idLookup.isDisjoint(with: Set(PathKey.lookupKeys(for: $0.url)))
        }) else { return nil }
        return id
    }

    func requestScrollToNowPlayingInQueue() {
        guard let id = nowPlayingIDInQueue() else { return }
        playlistManager.searchFiles("")
        queueScrollTargetID = id
    }

    func performQueueScrollSequence(targetID: String, proxy: ScrollViewProxy) {
        queueScrollTask?.cancel()
        queueScrollTask = Task { @MainActor in
            let retryIntervals: [UInt64] = [0, 120_000_000, 180_000_000, 260_000_000]

            for pause in retryIntervals {
                if pause > 0 {
                    try? await Task.sleep(nanoseconds: pause)
                }
                if Task.isCancelled { return }
                guard displayedQueueFiles.contains(where: { $0.id == targetID }) else {
                    continue
                }

                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }

            if Task.isCancelled { return }
            if queueScrollTargetID == targetID {
                queueScrollTargetID = nil
            }
        }
    }

    // MARK: - Playlist Creation

    func createPlaylist() {
        let name = TextInputPrompt.prompt(
            title: "新建歌单",
            message: "输入歌单名称",
            defaultValue: "",
            okTitle: "创建",
            cancelTitle: "取消"
        )
        _ = PlaylistCommands.createEmptyPlaylist(name: name ?? "", in: playlistsStore)
    }

    // MARK: - Search

    func updateQueueSearch(_ query: String) {
        playlistManager.searchText = query
        playlistManager.searchFiles(query)
    }

    // MARK: - Internal

    func refreshQueueVisibleFiles() {
        queueRefreshTask?.cancel()
        queueRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            queueVisibleFiles = sortState.option(for: .queue).applying(
                to: queueSourceFiles, weightScope: .queue)
            queueVisibleRevision &+= 1
        }
    }

    private func blurSearchField() {
        NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
}
