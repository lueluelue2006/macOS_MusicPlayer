import SwiftUI

struct PlaylistsPanelView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var playlistsStore: PlaylistsStore

    let onRequestEditMetadata: (AudioFile) -> Void

    @ObservedObject private var weights = PlaybackWeights.shared
    @ObservedObject private var sortState = SearchSortState.shared

	    @State private var trackSearchText: String = ""
	    @State private var loadedTracks: [AudioFile] = []
	    @State private var trackUnplayableReasons: [String: String] = [:]
	    @State private var isLoadingTracks: Bool = false
	    @State private var loadTask: Task<Void, Never>?
	    @State private var playlistScrollTargetID: String?

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

    private var sidebarSelectedPlaylistID: Binding<UserPlaylist.ID?> {
        Binding(
            get: { playlistsStore.selectedPlaylistID },
            set: { newValue in
                // macOS SwiftUI: clicking List's empty area can clear selection (set nil).
                // For playlists, that's a poor UX: it jumps to the "请选择一个歌单" placeholder.
                // Treat empty-area clicks as no-op as long as we still have playlists.
                guard let newValue else {
                    if playlistsStore.playlists.isEmpty {
                        playlistsStore.selectedPlaylistID = nil
                    }
                    return
                }
                playlistsStore.selectedPlaylistID = newValue
            }
        )
    }

    private var currentHighlightedURL: URL? {
        if audioPlayer.persistPlaybackState,
           playlistManager.currentIndex >= 0,
           playlistManager.currentIndex < playlistManager.audioFiles.count {
            return playlistManager.audioFiles[playlistManager.currentIndex].url
        }
        return audioPlayer.currentFile?.url
    }

    private var filteredTracks: [AudioFile] {
        let base: [AudioFile] = {
            guard !trackSearchText.isEmpty else { return loadedTracks }
            let q = trackSearchText
            return loadedTracks.filter { f in
                f.metadata.title.localizedCaseInsensitiveContains(q) ||
                    f.metadata.artist.localizedCaseInsensitiveContains(q) ||
                    f.metadata.album.localizedCaseInsensitiveContains(q) ||
                    f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
            }
        }()

        guard let playlist = selectedPlaylist else { return base }
        return sortState.option(for: .playlists).applying(to: base, weightScope: .playlist(playlist.id))
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
                    Text("点击上方“新建歌单”开始使用。")
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
                List(selection: sidebarSelectedPlaylistID) {
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

		                if !trackSearchText.isEmpty {
		                    HStack {
		                        Text("找到 \(filteredTracks.count) / \(loadedTracks.count) 首歌曲")
		                            .font(.caption)
		                            .foregroundColor(.secondary)
		                        Spacer()
		                    }
		                }

		                ScrollViewReader { proxy in
		                    Group {
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
	                                Text(playlist.tracks.isEmpty ? "可在右上角点击“从队列添加”。" : "试试更短的关键词。")
	                                    .font(.caption)
	                                    .foregroundColor(theme.mutedText.opacity(0.9))
	                            }
	                            .frame(maxWidth: .infinity, maxHeight: .infinity)
	                        } else {
	                            List(filteredTracks) { file in
	                                PlaylistItemView(
	                                    file: file,
	                                    isCurrentTrack: currentHighlightedURL == file.url,
	                                    isVolumeAnalyzed: audioPlayer.hasVolumeNormalizationCache(for: file.url),
	                                    unplayableReason: trackUnplayableReasons[pathKey(file.url)],
	                                    searchText: trackSearchText,
	                                    playAction: { selectedFile in
	                                        NotificationCenter.default.post(name: .blurSearchField, object: nil)
	                                        playTrackInPlaylist(selectedFile, playlist: playlist)
	                                    },
	                                    deleteAction: { fileToDelete in
	                                        NotificationCenter.default.post(name: .blurSearchField, object: nil)
	                                        playlistsStore.removeTrack(path: fileToDelete.url.path, from: playlist.id)
	                                        reloadSelectedPlaylist()
	                                    },
	                                    editAction: { fileToEdit in
	                                        NotificationCenter.default.post(name: .blurSearchField, object: nil)
	                                        if trackUnplayableReasons[pathKey(fileToEdit.url)] != nil {
	                                            postToast(title: "文件不存在，无法编辑", subtitle: fileToEdit.url.lastPathComponent, kind: "warning")
	                                            return
	                                        }
	                                        onRequestEditMetadata(fileToEdit)
	                                    },
	                                    weightScope: .playlist(playlist.id),
	                                    showsWeightControl: true
	                                )
	                                .id(file.id)
	                                .listRowBackground(Color.clear)
	                                .listRowSeparator(.hidden)
	                                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
	                            }
	                            .listStyle(PlainListStyle())
	                            .scrollContentBackground(.hidden)
	                            .background(Color.clear)
	                        }
	                    }
	                    .onChange(of: playlistScrollTargetID) { target in
	                        guard let target else { return }
	                        scrollToPlaylistTrackIfPossible(targetID: target, proxy: proxy)
	                    }
	                    .onChange(of: loadedTracks.count) { _ in
	                        guard let target = playlistScrollTargetID else { return }
	                        scrollToPlaylistTrackIfPossible(targetID: target, proxy: proxy)
	                    }
	                    .onChange(of: trackSearchText) { _ in
	                        guard let target = playlistScrollTargetID else { return }
	                        scrollToPlaylistTrackIfPossible(targetID: target, proxy: proxy)
	                    }
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

		            VStack(alignment: .trailing, spacing: 10) {
		                HStack(spacing: 10) {
		                    Button("从队列添加") {
		                        openAddFromQueueSheet(targetPlaylistID: playlist.id)
		                    }
		                    .buttonStyle(.borderedProminent)
		                    .disabled(playlistManager.audioFiles.isEmpty)
		                    .help(playlistManager.audioFiles.isEmpty ? "队列为空：先在“队列”里导入一些歌曲" : "")

	                    let canAddNowPlaying = (audioPlayer.currentFile != nil)
	                    Button("添加正在播放") {
	                        if let url = audioPlayer.currentFile?.url {
	                            playlistsStore.addTracks([url], to: playlist.id)
	                            reloadSelectedPlaylist()
	                        } else {
	                            postToast(title: "没有正在播放的歌曲", subtitle: nil, kind: "info")
	                        }
	                    }
	                    .buttonStyle(.borderedProminent)
	                    // Keep layout stable, but hide the whole control (including the chrome)
	                    // when there's nothing to add, so it doesn't show an empty grey pill.
	                    .opacity(canAddNowPlaying ? 1 : 0)
	                    .allowsHitTesting(canAddNowPlaying)
	                    .accessibilityHidden(!canAddNowPlaying)
	                    .help(canAddNowPlaying ? "将正在播放的歌曲加入该歌单" : "")
	                }

	                HStack(spacing: 10) {
	                    let nowPlayingID = nowPlayingIDInPlaylist(playlist)
	                    if nowPlayingID != nil {
                        Button {
                            requestScrollToNowPlayingInPlaylist(playlist)
                        } label: {
                            Label("定位正在播放", systemImage: "scope")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("定位到正在播放的歌曲（会自动清空搜索）")
                    }

                    Button {
                        let result = weights.syncPlaylistOverridesToQueue(from: playlist.id)
	                        if result.total == 0 {
	                            postToast(title: "歌单没有设置随机权重", subtitle: "先在歌单里点一下 5 个方块设置权重", kind: "info")
	                            return
	                        }
	                        if result.changed == 0 {
	                            postToast(title: "队列权重已是最新", subtitle: "无需同步（\(result.total) 条权重一致）", kind: "info")
	                            return
	                        }
	                        postToast(title: "已同步权重到队列", subtitle: "应用了 \(result.changed)/\(result.total) 条权重", kind: "success")
                    } label: {
                        Label("同步权重给队列", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("将本歌单的随机权重同步到队列（只同步非默认权重，不会清空队列里其他歌曲的权重）")
                }
            }
        }
		        .padding(.top, 4)
		    }

	    private func nowPlayingIDInPlaylist(_ playlist: UserPlaylist) -> String? {
	        guard let url = currentHighlightedURL else { return nil }
	        let id = pathKey(url)
	        guard playlist.tracks.contains(where: { pathKey(URL(fileURLWithPath: $0.path)) == id }) else { return nil }
	        return id
	    }

	    @MainActor
	    private func requestScrollToNowPlayingInPlaylist(_ playlist: UserPlaylist) {
	        guard let id = nowPlayingIDInPlaylist(playlist) else { return }
	        trackSearchText = ""
	        playlistScrollTargetID = id
	    }

	    @MainActor
	    private func scrollToPlaylistTrackIfPossible(targetID: String, proxy: ScrollViewProxy) {
	        guard !isLoadingTracks else { return }
	        guard filteredTracks.contains(where: { $0.id == targetID }) else { return }
	        withAnimation(.easeInOut(duration: 0.2)) {
	            proxy.scrollTo(targetID, anchor: .center)
	        }
	        DispatchQueue.main.async {
	            playlistScrollTargetID = nil
	        }
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
        // 若点击的是“当前已加载/正在播放”的曲目，不要重启到 0:00。
        if audioPlayer.currentFile?.url == selected.url {
            if !audioPlayer.isPlaying {
                audioPlayer.resume()
            }
            return
        }
        audioPlayer.play(selected)
    }

    // MARK: - Loading

	    private func reloadSelectedPlaylist() {
	        loadTask?.cancel()
	        trackSearchText = ""
	        playlistScrollTargetID = nil
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
        var all = playlistManager.audioFiles
        if !addFromQueueSearchText.isEmpty {
            let q = addFromQueueSearchText
            all = all.filter { f in
                f.metadata.title.localizedCaseInsensitiveContains(q) ||
                    f.metadata.artist.localizedCaseInsensitiveContains(q) ||
                    f.metadata.album.localizedCaseInsensitiveContains(q) ||
                    f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
            }
        }

        return sortState.option(for: .addFromQueue).applying(to: all, weightScope: .queue)
    }

    private var addFromQueueSelectedFiles: [AudioFile] {
        let keySet = addFromQueueSelectedKeys
        guard !keySet.isEmpty else { return [] }
        return playlistManager.audioFiles.filter { keySet.contains(pathKey($0.url)) }
    }

	    @ViewBuilder
	    private var addFromQueueSheet: some View {
	        VStack(spacing: 14) {
	            VStack(spacing: 8) {
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

	                    Button {
	                        showAddFromQueueSheet = false
	                    } label: {
	                        Image(systemName: "xmark.circle.fill")
	                            .font(.system(size: 18, weight: .semibold))
	                            .foregroundColor(theme.mutedText)
	                            .frame(width: 28, height: 28)
	                    }
	                    .buttonStyle(.plain)
	                    .help("关闭（Esc）")
	                }

	                HStack(spacing: 10) {
	                    Spacer()
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
	            }

	            SearchBarView(searchText: $addFromQueueSearchText, onSearchChanged: { q in
	                addFromQueueSearchText = q
	            }, focusTarget: .addFromQueue, autoFocusOnAppear: true)

	            if !addFromQueueSearchText.isEmpty {
	                HStack {
	                    Text("找到 \(addFromQueueCandidates.count) / \(playlistManager.audioFiles.count) 首歌曲")
	                        .font(.caption)
	                        .foregroundColor(.secondary)
	                    Spacer()
	                }
	            }

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
