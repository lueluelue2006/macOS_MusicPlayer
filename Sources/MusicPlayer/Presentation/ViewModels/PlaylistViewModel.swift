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
    private let stopPlaybackForQueueClear: () -> Void

    private static let panelModeDefaultsKey = "userPlaylistPanelMode"

    @Published private(set) var panelMode: PanelMode {
        didSet {
            UserDefaults.standard.set(panelMode.rawValue, forKey: Self.panelModeDefaultsKey)
        }
    }
    @Published private(set) var queueVisibleFiles: [AudioFile] = []
    @Published private(set) var queueVisibleRevision: UInt64 = 0
    @Published var queueScrollTargetID: String?

    private var queueRefreshTask: Task<Void, Never>?
    private var queueScrollTask: Task<Void, Never>?

    enum PanelMode: Int {
        case queue = 0
        case playlists = 1
    }

    var isQueueSelected: Bool { panelMode == .queue }
    var isPlaylistsSelected: Bool { panelMode == .playlists }

    var scanSubfoldersBinding: Binding<Bool> {
        Binding(
            get: { self.playlistManager.scanSubfolders },
            set: { self.playlistManager.scanSubfolders = $0 }
        )
    }

    var queueSearchTextBinding: Binding<String> {
        Binding(
            get: { self.playlistManager.searchText },
            set: { self.updateQueueSearch($0) }
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
        sortState: SearchSortState? = nil,
        weights: PlaybackWeights? = nil,
        stopPlaybackForQueueClear: (() -> Void)? = nil
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
        self.sortState = sortState ?? .shared
        self.weights = weights ?? .shared
        self.stopPlaybackForQueueClear = stopPlaybackForQueueClear ?? { [weak audioPlayer] in
            audioPlayer?.stopAndClearCurrent()
        }
        self.panelMode = PanelMode(
            rawValue: UserDefaults.standard.integer(forKey: Self.panelModeDefaultsKey)
        ) ?? .queue

        // 转发服务状态变化，让 SwiftUI 重新渲染；但不在这里刷新派生列表，
        // 避免 @Published 更新触发递归刷新。
        Publishers.MergeMany([
            audioPlayer.objectWillChange,
            playlistManager.objectWillChange,
            playlistsStore.objectWillChange,
            self.sortState.objectWillChange,
            self.weights.objectWillChange
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
            self.sortState.$revision.map { _ in () }.eraseToAnyPublisher(),
            self.weights.$revision.map { _ in () }.eraseToAnyPublisher()
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

    @discardableResult
    func clearQueue() -> PlaylistManager.QueueClearResult {
        let result = playlistManager.clearAllFiles()
        guard result.didApply else {
            PersistenceLogger.notifyUser(
                title: "无法清空队列",
                subtitle: "队列仍在恢复或处于只读保护，请稍后重试"
            )
            return result
        }

        stopPlaybackForQueueClear()
        queueVisibleFiles.removeAll()
        queueVisibleRevision &+= 1
        if !result.isDurable {
            PersistenceLogger.notifyUser(
                title: "队列已清空",
                subtitle: "磁盘保存尚未完成，应用会继续重试"
            )
        }
        return result
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
        let mutation = PlaylistCommands.createEmptyPlaylist(
            name: name ?? "",
            in: playlistsStore
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.playlistsStore.awaitDurability(of: mutation) {
            case .committed, .unchanged:
                break
            case .rejected(let rejection):
                PersistenceLogger.notifyUser(
                    title: "无法创建歌单",
                    subtitle: rejection.diagnosticMessage
                )
            case .persistenceFailed(let failure):
                PersistenceLogger.notifyUser(
                    title: "歌单尚未安全保存",
                    subtitle: failure.diagnosticMessage
                )
            }
        }
    }

    // MARK: - Search

    func updateQueueSearch(_ query: String) {
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
