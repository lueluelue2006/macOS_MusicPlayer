import SwiftUI

struct PlaylistsPanelView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var playlistsStore: PlaylistsStore

    let onRequestEditMetadata: (AudioFile) -> Void

    @State private var trackSearchText: String = ""
    @State private var loadedTracks: [AudioFile] = []
    @State private var trackUnplayableReasons: [String: String] = [:]
    @State private var isLoadingTracks: Bool = false
    @State private var loadTask: Task<Void, Never>?

    // Add-from-queue multi-select sheet
    @State private var showAddFromQueueSheet: Bool = false
    @State private var addFromQueueTargetPlaylistID: UserPlaylist.ID?
    @State private var addFromQueueSearchText: String = ""
    @State private var addFromQueueSelectedKeys: Set<String> = []

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    private var selectedPlaylist: UserPlaylist? {
        playlistsStore.playlist(for: playlistsStore.selectedPlaylistID)
    }

    private var filteredTracks: [AudioFile] {
        guard !trackSearchText.isEmpty else { return loadedTracks }
        let q = trackSearchText
        return loadedTracks.filter { f in
            f.metadata.title.localizedCaseInsensitiveContains(q) ||
                f.metadata.artist.localizedCaseInsensitiveContains(q) ||
                f.metadata.album.localizedCaseInsensitiveContains(q) ||
                f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            playlistsSidebar
                .frame(width: 190)

            Divider()
                .opacity(0.35)

            playlistDetail
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .sheet(isPresented: $showAddFromQueueSheet) {
            addFromQueueSheet
        }
        .onAppear {
            playlistsStore.loadIfNeeded()
            reloadSelectedPlaylist()
        }
        .onChange(of: playlistsStore.selectedPlaylistID) { _ in
            reloadSelectedPlaylist()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDismissAllSheets)) { _ in
            showAddFromQueueSheet = false
        }
    }

    private var playlistsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的歌单")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            if playlistsStore.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有歌单")
                        .font(.subheadline)
                        .foregroundColor(theme.mutedText)
                    Text("在上方切到“歌单”后，可新建歌单或保存当前队列。")
                        .font(.caption)
                        .foregroundColor(theme.mutedText.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.mutedSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                )
                Spacer()
            } else {
                List(selection: $playlistsStore.selectedPlaylistID) {
                    ForEach(playlistsStore.playlists) { playlist in
                        HStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(theme.accentGradient)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .lineLimit(1)
                                Text("\(playlist.tracks.count) 首")
                                    .font(.caption2)
                                    .foregroundColor(theme.mutedText)
                            }
                            Spacer(minLength: 0)
                            if audioPlayer.currentFile != nil,
                               audioPlayer.persistPlaybackState,
                               playlistManager.playbackScope == .playlist(playlist.id) {
                                ActivePlaybackScopeIndicator(
                                    systemName: audioPlayer.isShuffling ? "shuffle.circle.fill" : "play.circle.fill",
                                    isPlaying: audioPlayer.isPlaying
                                )
                                    .help("正在以该歌单作为播放范围")
                            }
                        }
                        .tag(playlist.id)
                        .contextMenu {
                            Button("重命名…") {
                                renamePlaylist(playlist)
                            }
                            Divider()
                            Button("删除歌单", role: .destructive) {
                                deletePlaylist(playlist)
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var playlistDetail: some View {
        if let playlist = selectedPlaylist {
            VStack(alignment: .leading, spacing: 14) {
                header(for: playlist)

                SearchBarView(searchText: $trackSearchText, onSearchChanged: { q in
                    trackSearchText = q
                }, focusTarget: .playlists)

                if isLoadingTracks {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("加载歌单…")
                            .font(.caption)
                            .foregroundColor(theme.mutedText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredTracks.isEmpty {
                    VStack(spacing: 10) {
                        Text(playlist.tracks.isEmpty ? "歌单为空" : "未找到匹配歌曲")
                            .font(.subheadline)
                            .foregroundColor(theme.mutedText)
                        Text(playlist.tracks.isEmpty ? "可在右上角“更多”里从队列添加。" : "试试更短的关键词。")
                            .font(.caption)
                            .foregroundColor(theme.mutedText.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredTracks) { file in
                        PlaylistItemView(
                            file: file,
                            isCurrentTrack: audioPlayer.currentFile?.url == file.url,
                            isVolumeAnalyzed: audioPlayer.hasVolumeNormalizationCache(for: file.url),
                            unplayableReason: trackUnplayableReasons[pathKey(file.url)],
                            searchText: trackSearchText
                        ) { selectedFile in
                            NotificationCenter.default.post(name: .blurSearchField, object: nil)
                            playTrackInPlaylist(selectedFile, playlist: playlist)
                        } deleteAction: { fileToDelete in
                            NotificationCenter.default.post(name: .blurSearchField, object: nil)
                            playlistsStore.removeTrack(path: fileToDelete.url.path, from: playlist.id)
                            reloadSelectedPlaylist()
                        } editAction: { fileToEdit in
                            NotificationCenter.default.post(name: .blurSearchField, object: nil)
                            if trackUnplayableReasons[pathKey(fileToEdit.url)] != nil {
                                postToast(title: "文件不存在，无法编辑", subtitle: fileToEdit.url.lastPathComponent, kind: "warning")
                                return
                            }
                            onRequestEditMetadata(fileToEdit)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listStyle(PlainListStyle())
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                NotificationCenter.default.post(name: .blurSearchField, object: nil)
            }
        } else {
            VStack(spacing: 10) {
                Text("请选择一个歌单")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("在左侧选择歌单，或新建一个歌单开始使用。")
                    .font(.caption)
                    .foregroundColor(theme.mutedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for playlist: UserPlaylist) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(playlist.tracks.count) 首")
                    .font(.caption)
                    .foregroundColor(theme.mutedText)
            }

            Spacer()

            Button("加入队列") {
                appendPlaylistToQueue(playlist, autostart: false)
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingTracks || loadedTracks.isEmpty)

            Button("播放（追加）") {
                appendPlaylistToQueue(playlist, autostart: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoadingTracks || loadedTracks.isEmpty)

            Menu {
                Button("从当前队列添加") {
                    openAddFromQueueSheet(targetPlaylistID: playlist.id)
                }
                Button("添加正在播放") {
                    if let url = audioPlayer.currentFile?.url {
                        playlistsStore.addTracks([url], to: playlist.id)
                        reloadSelectedPlaylist()
                    } else {
                        postToast(title: "没有正在播放的歌曲", subtitle: nil, kind: "info")
                    }
                }
                Divider()
                Button("重命名歌单…") {
                    renamePlaylist(playlist)
                }
                Button("删除歌单", role: .destructive) {
                    deletePlaylist(playlist)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundColor(theme.mutedText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    @MainActor
    private func openAddFromQueueSheet(targetPlaylistID: UserPlaylist.ID) {
        guard !playlistManager.audioFiles.isEmpty else {
            postToast(title: "队列为空", subtitle: "先在“队列”里导入一些歌曲", kind: "info")
            return
        }
        addFromQueueTargetPlaylistID = targetPlaylistID
        addFromQueueSearchText = ""
        addFromQueueSelectedKeys.removeAll(keepingCapacity: true)
        showAddFromQueueSheet = true
    }

    @MainActor
    private func renamePlaylist(_ playlist: UserPlaylist) {
        if let name = TextInputPrompt.prompt(
            title: "重命名歌单",
            message: "输入新的歌单名称",
            defaultValue: playlist.name,
            okTitle: "确定",
            cancelTitle: "取消"
        ) {
            playlistsStore.renamePlaylist(playlist, to: name)
        }
    }

    @MainActor
    private func deletePlaylist(_ playlist: UserPlaylist) {
        let confirmed = DestructiveConfirmation.confirm(
            title: "删除歌单？",
            message: "将删除歌单“\(playlist.name)”。不会删除任何音乐文件。",
            confirmTitle: "删除",
            cancelTitle: "不删除"
        )
        guard confirmed else { return }
        if playlistManager.playbackScope == .playlist(playlist.id) {
            playlistManager.setPlaybackScopeQueue()
        }
        playlistsStore.deletePlaylist(playlist)
        reloadSelectedPlaylist()
    }

    @MainActor
    private func playTrackInPlaylist(_ file: AudioFile, playlist: UserPlaylist) {
        if let reason = trackUnplayableReasons[pathKey(file.url)] {
            postToast(title: "无法播放：\(reason)", subtitle: file.url.lastPathComponent, kind: "warning")
            return
        }
        let playable = loadedTracks.filter { trackUnplayableReasons[pathKey($0.url)] == nil }
        guard !playable.isEmpty else {
            postToast(title: "歌单里没有可播放的歌曲", subtitle: nil, kind: "warning")
            return
        }
        guard let idx = playlistManager.ensureInQueue(playable, focusURL: file.url),
              let selected = playlistManager.selectFile(at: idx)
        else {
            postToast(title: "未能加入播放列表", subtitle: file.url.lastPathComponent, kind: "warning")
            return
        }

        playlistManager.setPlaybackScopePlaylist(playlist.id, trackURLsInOrder: playable.map(\.url))
        audioPlayer.play(selected)
    }

    @MainActor
    private func appendPlaylistToQueue(_ playlist: UserPlaylist, autostart: Bool) {
        let playable = loadedTracks.filter { trackUnplayableReasons[pathKey($0.url)] == nil }
        guard !playable.isEmpty else {
            postToast(title: "歌单里没有可播放的歌曲", subtitle: nil, kind: "warning")
            return
        }

        let focusURL = playable.first?.url
        let focusIndex = playlistManager.ensureInQueue(playable, focusURL: focusURL)

        guard autostart, let idx = focusIndex, let selected = playlistManager.selectFile(at: idx) else {
            postToast(title: "已加入 \(playable.count) 首到播放列表", subtitle: nil, kind: "success")
            return
        }
        playlistManager.setPlaybackScopePlaylist(playlist.id, trackURLsInOrder: playable.map(\.url))
        audioPlayer.play(selected)
    }

    // MARK: - Loading

    private func reloadSelectedPlaylist() {
        loadTask?.cancel()
        trackSearchText = ""
        loadedTracks = []
        trackUnplayableReasons = [:]

        guard let playlist = selectedPlaylist else { return }
        let playlistID = playlist.id
        let paths = playlist.tracks.map(\.path)
        guard !paths.isEmpty else { return }

        isLoadingTracks = true

        let playlistManager = self.playlistManager
        loadTask = Task.detached(priority: .background) { [paths, playlistManager, playlistID] in
            let fm = FileManager.default
            let gate = ConcurrencyGate(maxConcurrent: 4)
            func key(for url: URL) -> String {
                url.standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
            }
            var results: [AudioFile?] = Array(repeating: nil, count: paths.count)
            var reasons: [String: String] = [:]

            await withTaskGroup(of: (Int, AudioFile).self) { group in
                for (idx, path) in paths.enumerated() {
                    group.addTask {
                        let url = URL(fileURLWithPath: path)
                        let exists = fm.fileExists(atPath: url.path)
                        if !exists {
                            let title = url.deletingPathExtension().lastPathComponent
                            let meta = AudioMetadata(title: title, artist: "", album: "", year: nil, genre: nil, artwork: nil)
                            return (idx, AudioFile(url: url, metadata: meta, duration: nil))
                        }

                        await gate.acquire()
                        let metadata = await playlistManager.loadCachedMetadata(from: url)
                        let duration = await DurationCache.shared.cachedDurationIfValid(for: url)
                        await gate.release()

                        return (idx, AudioFile(url: url, metadata: metadata, duration: duration))
                    }
                }

                for await (idx, file) in group {
                    results[idx] = file
                }
            }

            // Build unplayable reasons for missing files.
            for (idx, path) in paths.enumerated() {
                let url = URL(fileURLWithPath: path)
                if !fm.fileExists(atPath: url.path) {
                    reasons[key(for: url)] = "文件不存在"
                }
                if results[idx] == nil {
                    let title = url.deletingPathExtension().lastPathComponent
                    let meta = AudioMetadata(title: title, artist: "", album: "", year: nil, genre: nil, artwork: nil)
                    results[idx] = AudioFile(url: url, metadata: meta, duration: nil)
                }
            }

            let finalTracks = results.compactMap { $0 }
            let finalReasons = reasons
            await MainActor.run {
                if Task.isCancelled { return }
                self.loadedTracks = finalTracks
                self.trackUnplayableReasons = finalReasons
                self.isLoadingTracks = false

                let playableURLs = finalTracks
                    .filter { finalReasons[self.pathKey($0.url)] == nil }
                    .map(\.url)
                self.playlistManager.updatePlaybackScopePlaylistTracksIfActive(playlistID, trackURLsInOrder: playableURLs)
            }
        }
    }

    private func postToast(title: String, subtitle: String?, kind: String) {
        var userInfo: [String: Any] = ["title": title, "kind": kind, "duration": 2.2]
        if let subtitle { userInfo["subtitle"] = subtitle }
        NotificationCenter.default.post(name: .showAppToast, object: nil, userInfo: userInfo)
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    // MARK: - Add from queue sheet

    private var addFromQueueCandidates: [AudioFile] {
        let all = playlistManager.audioFiles
        guard !addFromQueueSearchText.isEmpty else { return all }
        let q = addFromQueueSearchText
        return all.filter { f in
            f.metadata.title.localizedCaseInsensitiveContains(q) ||
                f.metadata.artist.localizedCaseInsensitiveContains(q) ||
                f.metadata.album.localizedCaseInsensitiveContains(q) ||
                f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
        }
    }

    private var addFromQueueSelectedFiles: [AudioFile] {
        let keySet = addFromQueueSelectedKeys
        guard !keySet.isEmpty else { return [] }
        return playlistManager.audioFiles.filter { keySet.contains(pathKey($0.url)) }
    }

    @ViewBuilder
    private var addFromQueueSheet: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("从队列添加")
                    .font(.headline)
                Spacer()
                Button("本页全选") {
                    for f in addFromQueueCandidates {
                        addFromQueueSelectedKeys.insert(pathKey(f.url))
                    }
                }
                .disabled(addFromQueueCandidates.isEmpty)
                Button("本页全不选") {
                    for f in addFromQueueCandidates {
                        addFromQueueSelectedKeys.remove(pathKey(f.url))
                    }
                }
                .disabled(addFromQueueCandidates.isEmpty)
                Button("清空") {
                    addFromQueueSelectedKeys.removeAll(keepingCapacity: true)
                }
                .disabled(addFromQueueSelectedKeys.isEmpty)
            }

            SearchBarView(searchText: $addFromQueueSearchText, onSearchChanged: { q in
                addFromQueueSearchText = q
            }, focusTarget: .addFromQueue, autoFocusOnAppear: true)

            List(addFromQueueCandidates) { file in
                Button {
                    let k = pathKey(file.url)
                    if addFromQueueSelectedKeys.contains(k) {
                        addFromQueueSelectedKeys.remove(k)
                    } else {
                        addFromQueueSelectedKeys.insert(k)
                    }
                } label: {
                    let selected = addFromQueueSelectedKeys.contains(pathKey(file.url))
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText))
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 18, height: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.metadata.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(file.url.lastPathComponent)
                                .font(.caption2)
                                .foregroundColor(theme.mutedText)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)

            // Bottom "selected files" area
            VStack(alignment: .leading, spacing: 8) {
                Text("已选 \(addFromQueueSelectedKeys.count) 首：")
                    .font(.caption)
                    .foregroundColor(theme.mutedText)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(addFromQueueSelectedFiles, id: \.id) { f in
                            Text(f.url.lastPathComponent)
                                .font(.caption2)
                                .foregroundColor(theme.mutedText.opacity(0.95))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.mutedSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                )
            }

            HStack {
                Button("取消") {
                    showAddFromQueueSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("添加 \(addFromQueueSelectedKeys.count) 首") {
                    guard let targetID = addFromQueueTargetPlaylistID else {
                        showAddFromQueueSheet = false
                        return
                    }
                    let urls = addFromQueueSelectedFiles.map(\.url)
                    playlistsStore.addTracks(urls, to: targetID)
                    showAddFromQueueSheet = false
                    reloadSelectedPlaylist()
                    postToast(title: "已添加 \(urls.count) 首", subtitle: nil, kind: "success")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addFromQueueSelectedKeys.isEmpty)
            }
        }
        .onAppear {
            AppFocusState.shared.activeSearchTarget = .addFromQueue
            // 自动聚焦搜索框（并确保 Cmd+F 只作用于当前弹窗）
            NotificationCenter.default.post(
                name: .focusSearchField,
                object: nil,
                userInfo: ["target": SearchFocusTarget.addFromQueue.rawValue]
            )
        }
        .onDisappear {
            // 恢复到歌单面板的搜索框
            AppFocusState.shared.activeSearchTarget = .playlists
            AppFocusState.shared.isSearchFocused = false
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 560)
    }
}
