import AppKit
import SwiftUI

struct PlaylistsPanelView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @ObservedObject var playlistsStore: PlaylistsStore

  let locateNowPlayingRequestID: Int
  let onRequestEditMetadata: (AudioFile) -> Void

  @ObservedObject private var weights = PlaybackWeights.shared
  @ObservedObject private var sortState = SearchSortState.shared

  @State private var trackSearchText: String = ""
  @State private var loadedTracks: [AudioFile] = []
  @State private var visibleTracks: [AudioFile] = []
  @State private var visibleTracksRevision: UInt64 = 0
  @State private var trackUnplayableReasons: [String: String] = [:]
  @State private var isLoadingTracks: Bool = false
  @State private var loadTask: Task<Void, Never>?
  @State private var playlistScrollTargetID: String?
  @State private var playlistScrollTask: Task<Void, Never>?
  @State private var playlistTableView: NSTableView?
  @State private var handledLocateNowPlayingRequestID: Int = 0

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
      playlistManager.currentIndex < playlistManager.audioFiles.count
    {
      return playlistManager.audioFiles[playlistManager.currentIndex].url
    }
    return audioPlayer.currentFile?.url
  }

  var body: some View {
    HStack(spacing: 18) {
      playlistsSidebar
        .frame(width: 180)

      Divider()
        .opacity(0.35)

      playlistDetail
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 16)
    .sheet(isPresented: $showAddFromQueueSheet) {
      addFromQueueSheet
    }
    .onAppear {
      playlistsStore.loadIfNeeded()
      reloadSelectedPlaylist()
      refreshVisibleTracks()
      handlePendingLocateNowPlayingRequest()
    }
    .onChange(of: playlistsStore.selectedPlaylistID) { _ in
      reloadSelectedPlaylist()
    }
    .onChange(of: trackSearchText) { _ in
      refreshVisibleTracks()
    }
    .onChange(of: loadedTracks) { _ in
      refreshVisibleTracks()
    }
    .onChange(of: weights.revision) { _ in
      if sortState.option(for: .playlists).field == .weight {
        refreshVisibleTracks()
      }
    }
    .onChange(of: sortState.revision) { _ in
      refreshVisibleTracks()
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestDismissAllSheets)) { _ in
      showAddFromQueueSheet = false
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInPlaylist)) { _ in
      guard let playlist = selectedPlaylist else { return }
      requestScrollToNowPlayingInPlaylist(playlist)
    }
    .onChange(of: locateNowPlayingRequestID) { _ in
      handlePendingLocateNowPlayingRequest()
    }
  }

  private var playlistsSidebar: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("歌单")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(theme.mutedText)
        Spacer()
      }

      if !playlistsStore.isReady {
        VStack(alignment: .leading, spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("正在加载歌单…")
            .font(.caption)
            .foregroundColor(theme.mutedText)
        }
        .padding(.vertical, 8)
        Spacer()
      } else if playlistsStore.playlists.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("还没有歌单")
            .font(.subheadline)
            .foregroundColor(theme.mutedText)
          Text("点击上方“新建歌单”开始使用。")
            .font(.caption)
            .foregroundColor(theme.mutedText.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        Spacer()
      } else {
        List(selection: sidebarSelectedPlaylistID) {
          ForEach(playlistsStore.playlists) { playlist in
            HStack(spacing: 10) {
              Image(systemName: "music.note.list")
                .foregroundStyle(theme.accent)
              VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                  .lineLimit(1)
                Text("\(playlist.tracks.count) 首")
                  .font(.caption2)
                  .foregroundColor(theme.mutedText)
              }
              Spacer(minLength: 0)
              if audioPlayer.playbackTargetURL != nil,
                audioPlayer.persistPlaybackState,
                playlistManager.playbackScope == .playlist(playlist.id)
              {
                ActivePlaybackScopeIndicator(
                  systemName: audioPlayer.isLooping
                    ? "repeat" : "shuffle",
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

        SearchBarView(
          searchText: $trackSearchText,
          onSearchChanged: { q in
            trackSearchText = q
          }, focusTarget: .playlists)

        if !trackSearchText.isEmpty {
          HStack {
            Text("找到 \(visibleTracks.count) / \(loadedTracks.count) 首歌曲")
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
            } else if visibleTracks.isEmpty {
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
              List(visibleTracks) { file in
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
                      postToast(
                        title: "文件不存在，无法编辑", subtitle: fileToEdit.url.lastPathComponent,
                        kind: "warning")
                      return
                    }
                    onRequestEditMetadata(fileToEdit)
                  },
                  weightLevel: weights.level(for: file.url, scope: .playlist(playlist.id)),
                  onWeightSelect: { newLevel in
                    weights.setLevel(newLevel, for: file.url, scope: .playlist(playlist.id))
                  }
                )
                .id(file.id)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
              }
              .listStyle(PlainListStyle())
              .scrollContentBackground(.hidden)
              .background(Color.clear)
              .background(
                ListTableViewAccessor { tableView in
                  let currentID = playlistTableView.map(ObjectIdentifier.init)
                  let newID = tableView.map(ObjectIdentifier.init)
                  if currentID != newID {
                    playlistTableView = tableView
                  }
                }
              )
            }
          }
          .onChange(of: playlistScrollTargetID) { target in
            guard let target else { return }
            performPlaylistScrollSequence(targetID: target, proxy: proxy)
          }
          .onChange(of: visibleTracksRevision) { _ in
            guard let target = playlistScrollTargetID else { return }
            performPlaylistScrollSequence(targetID: target, proxy: proxy)
          }
          .onChange(of: trackSearchText) { _ in
            guard let target = playlistScrollTargetID else { return }
            performPlaylistScrollSequence(targetID: target, proxy: proxy)
          }
          .onAppear {
            guard let target = playlistScrollTargetID else { return }
            performPlaylistScrollSequence(targetID: target, proxy: proxy)
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
          .font(.system(size: 20, weight: .bold))
          .foregroundColor(.primary)
          .lineLimit(1)
        Text("\(playlist.tracks.count) 首")
          .font(.caption)
          .foregroundColor(theme.mutedText)
      }

      Spacer()

      Button {
        openAddFromQueueSheet(targetPlaylistID: playlist.id)
      } label: {
        Label("从队列添加", systemImage: "plus")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.accentForeground)
          .padding(.horizontal, 11)
          .padding(.vertical, 7)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(theme.accent)
          )
      }
      .buttonStyle(.plain)
      .disabled(playlistManager.audioFiles.isEmpty)
      .help(playlistManager.audioFiles.isEmpty ? "队列为空：先在“队列”里导入一些歌曲" : "")

      Menu {
        if audioPlayer.currentFile != nil {
          Button("添加正在播放") {
            if let url = audioPlayer.currentFile?.url {
              playlistsStore.addTracks([url], to: playlist.id)
              reloadSelectedPlaylist()
            } else {
              postToast(title: "没有正在播放的歌曲", subtitle: nil, kind: "info")
            }
          }
        }

        if nowPlayingIDInPlaylist(playlist) != nil {
          Button("定位正在播放") {
            requestScrollToNowPlayingInPlaylist(playlist)
          }
        }

        Divider()

        Button("同步随机权重给队列") {
          let result = weights.syncPlaylistOverridesToQueue(from: playlist.id)
          if result.total == 0 {
            postToast(title: "歌单没有设置随机权重", subtitle: "先在歌曲行的随机权重菜单中设置", kind: "info")
            return
          }
          if result.changed == 0 {
            postToast(title: "队列权重已是最新", subtitle: "无需同步（\(result.total) 条权重一致）", kind: "info")
            return
          }
          postToast(
            title: "已同步权重到队列", subtitle: "应用了 \(result.changed)/\(result.total) 条权重",
            kind: "success")
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("歌单操作")
    }
    .padding(.top, 4)
  }

  private func nowPlayingIDInPlaylist(_ playlist: UserPlaylist) -> String? {
    guard let url = currentHighlightedURL else { return nil }
    let id = pathKey(url)
    let idLookup = Set(pathLookupKeys(url))
    guard
      playlist.tracks.contains(where: {
        !idLookup.isDisjoint(with: Set(pathLookupKeys(URL(fileURLWithPath: $0.path))))
      })
    else { return nil }
    return id
  }

  @MainActor
  private func requestScrollToNowPlayingInPlaylist(_ playlist: UserPlaylist) {
    guard let id = nowPlayingIDInPlaylist(playlist) else { return }
    trackSearchText = ""
    playlistScrollTargetID = id
  }

  @MainActor
  private func performPlaylistScrollSequence(targetID: String, proxy: ScrollViewProxy) {
    guard !isLoadingTracks else { return }

    playlistScrollTask?.cancel()
    playlistScrollTask = Task { @MainActor in
      let retryIntervals: [UInt64] = [0, 120_000_000, 180_000_000, 260_000_000]

      for pause in retryIntervals {
        if pause > 0 {
          try? await Task.sleep(nanoseconds: pause)
        }
        if Task.isCancelled { return }
        guard !isLoadingTracks else { continue }
        guard let targetIndex = visibleTracks.firstIndex(where: { $0.id == targetID }) else {
          continue
        }
        if let tableView = playlistTableView, tableView.numberOfRows > targetIndex {
          centerListRow(targetIndex, in: tableView)
        } else {
          withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(targetID, anchor: .center)
          }
        }
      }

      if Task.isCancelled { return }
      if playlistScrollTargetID == targetID {
        playlistScrollTargetID = nil
      }
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
    audioPlayer.selectOrResume(selected)
  }

  // MARK: - Loading

  private func reloadSelectedPlaylist() {
    loadTask?.cancel()
    trackSearchText = ""
    playlistScrollTargetID = nil
    loadedTracks = []
    visibleTracks = []
    trackUnplayableReasons = [:]
    isLoadingTracks = false

    guard let playlist = selectedPlaylist else { return }
    let playlistID = playlist.id
    let paths = playlist.tracks.map(\.path)
    guard !paths.isEmpty else {
      playlistManager.updatePlaybackScopePlaylistTracksIfActive(
        playlistID, trackURLsInOrder: [])
      return
    }

    isLoadingTracks = true

    let playlistManager = self.playlistManager
    loadTask = Task.detached(priority: .background) { [paths, playlistManager, playlistID] in
      let fm = FileManager.default
      func key(for url: URL) -> String {
        url.standardizedFileURL.path
          .precomposedStringWithCanonicalMapping
      }
      var results: [AudioFile?] = Array(repeating: nil, count: paths.count)
      var missingFileIndices = Set<Int>()
      var reasons: [String: String] = [:]

      // Keep task allocation bounded as well as I/O concurrency bounded. A fixed
      // worker pool avoids retaining one child task per track in large playlists.
      let workerCount = min(4, paths.count)
      await withTaskGroup(of: [(Int, AudioFile, Bool)].self) { group in
        for workerIndex in 0..<workerCount {
          group.addTask {
            var workerResults: [(Int, AudioFile, Bool)] = []
            workerResults.reserveCapacity((paths.count + workerCount - 1) / workerCount)

            for idx in stride(from: workerIndex, to: paths.count, by: workerCount) {
              guard !Task.isCancelled else { break }

              let url = URL(fileURLWithPath: paths[idx])
              let snapshot = FileValidationSnapshot.load(for: url, fileManager: fm)
              if !snapshot.exists {
                let title = url.deletingPathExtension().lastPathComponent
                let metadata = AudioMetadata(
                  title: title,
                  artist: "",
                  album: "",
                  year: nil,
                  genre: nil,
                  artwork: nil
                )
                workerResults.append(
                  (
                    idx,
                    AudioFile(url: url, metadata: metadata, duration: nil),
                    true
                  ))
                continue
              }

              let metadata = await playlistManager.loadCachedMetadata(from: url, snapshot: snapshot)
              guard !Task.isCancelled else { break }
              let duration = await DurationCache.shared.cachedDurationIfValid(
                for: url, snapshot: snapshot)
              workerResults.append(
                (
                  idx,
                  AudioFile(url: url, metadata: metadata, duration: duration),
                  false
                ))
            }

            return workerResults
          }
        }

        for await workerResults in group {
          for (idx, file, isMissing) in workerResults {
            results[idx] = file
            if isMissing {
              missingFileIndices.insert(idx)
            }
          }
        }
      }

      // Build unplayable reasons for missing files.
      for (idx, path) in paths.enumerated() {
        let url = URL(fileURLWithPath: path)
        if missingFileIndices.contains(idx) {
          reasons[key(for: url)] = "文件不存在"
        }
        if results[idx] == nil {
          let title = url.deletingPathExtension().lastPathComponent
          let meta = AudioMetadata(
            title: title, artist: "", album: "", year: nil, genre: nil, artwork: nil)
          results[idx] = AudioFile(url: url, metadata: meta, duration: nil)
        }
      }

      let finalTracks = results.compactMap { $0 }
      let finalReasons = reasons
      await MainActor.run {
        guard self.selectedPlaylist?.id == playlistID else { return }
        if Task.isCancelled { return }
        self.loadedTracks = finalTracks
        self.trackUnplayableReasons = finalReasons
        self.isLoadingTracks = false

        let playableURLs =
          finalTracks
          .filter { finalReasons[self.pathKey($0.url)] == nil }
          .map(\.url)
        self.playlistManager.updatePlaybackScopePlaylistTracksIfActive(
          playlistID, trackURLsInOrder: playableURLs)
      }
    }
  }

  private func postToast(title: String, subtitle: String?, kind: String) {
    var userInfo: [String: Any] = ["title": title, "kind": kind, "duration": 2.2]
    if let subtitle { userInfo["subtitle"] = subtitle }
    NotificationCenter.default.post(name: .showAppToast, object: nil, userInfo: userInfo)
  }

  private func pathKey(_ url: URL) -> String {
    PathKey.canonical(for: url)
  }

  private func pathLookupKeys(_ url: URL) -> [String] {
    PathKey.lookupKeys(for: url)
  }

  @MainActor
  private func refreshVisibleTracks() {
    let base: [AudioFile]
    if trackSearchText.isEmpty {
      base = loadedTracks
    } else {
      let q = trackSearchText
      base = loadedTracks.filter { f in
        f.metadata.title.localizedCaseInsensitiveContains(q)
          || f.metadata.artist.localizedCaseInsensitiveContains(q)
          || f.metadata.album.localizedCaseInsensitiveContains(q)
          || f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
      }
    }

    guard let playlist = selectedPlaylist else {
      visibleTracks = base
      visibleTracksRevision &+= 1
      return
    }
    visibleTracks = sortState.option(for: .playlists).applying(
      to: base, weightScope: .playlist(playlist.id))
    visibleTracksRevision &+= 1
  }

  @MainActor
  private func handlePendingLocateNowPlayingRequest() {
    guard locateNowPlayingRequestID != 0,
      locateNowPlayingRequestID != handledLocateNowPlayingRequestID,
      let playlist = selectedPlaylist
    else { return }
    handledLocateNowPlayingRequestID = locateNowPlayingRequestID
    requestScrollToNowPlayingInPlaylist(playlist)
  }

  // MARK: - Add from queue sheet

  private func makeAddFromQueueCandidates() -> [AudioFile] {
    var all = playlistManager.audioFiles
    if !addFromQueueSearchText.isEmpty {
      let q = addFromQueueSearchText
      all = all.filter { f in
        f.metadata.title.localizedCaseInsensitiveContains(q)
          || f.metadata.artist.localizedCaseInsensitiveContains(q)
          || f.metadata.album.localizedCaseInsensitiveContains(q)
          || f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
      }
    }

    return sortState.option(for: .addFromQueue).applying(to: all, weightScope: .queue)
  }

  private func makeAddFromQueueSelectedFiles() -> [AudioFile] {
    let keySet = addFromQueueSelectedKeys
    guard !keySet.isEmpty else { return [] }
    return playlistManager.audioFiles.filter { file in
      pathLookupKeys(file.url).contains(where: keySet.contains)
    }
  }

  private var addFromQueueSheet: some View {
    let candidates = makeAddFromQueueCandidates()
    let selectedFiles = makeAddFromQueueSelectedFiles()

    return VStack(spacing: 14) {
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          Label("从队列添加", systemImage: "text.badge.plus")
            .font(.headline)
          Spacer()

          Button("本页全选") {
            for f in candidates {
              addFromQueueSelectedKeys.insert(pathKey(f.url))
            }
          }
          .disabled(candidates.isEmpty)

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
            for f in candidates {
              addFromQueueSelectedKeys.remove(pathKey(f.url))
              addFromQueueSelectedKeys.remove(PathKey.legacy(for: f.url))
            }
          }
          .disabled(candidates.isEmpty)
          Button("清空") {
            addFromQueueSelectedKeys.removeAll(keepingCapacity: true)
          }
          .disabled(addFromQueueSelectedKeys.isEmpty)
        }
      }

      SearchBarView(
        searchText: $addFromQueueSearchText,
        onSearchChanged: { q in
          addFromQueueSearchText = q
        }, focusTarget: .addFromQueue, autoFocusOnAppear: true)

      if !addFromQueueSearchText.isEmpty {
        HStack {
          Text("找到 \(candidates.count) / \(playlistManager.audioFiles.count) 首歌曲")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
        }
      }

      List(candidates) { file in
        Button {
          let k = pathKey(file.url)
          let selected = pathLookupKeys(file.url).contains(where: addFromQueueSelectedKeys.contains)
          if selected {
            addFromQueueSelectedKeys.remove(k)
            let legacy = PathKey.legacy(for: file.url)
            if legacy != k {
              addFromQueueSelectedKeys.remove(legacy)
            }
          } else {
            addFromQueueSelectedKeys.insert(k)
            let legacy = PathKey.legacy(for: file.url)
            if legacy != k {
              addFromQueueSelectedKeys.insert(legacy)
            }
          }
        } label: {
          let selected = pathLookupKeys(file.url).contains(where: addFromQueueSelectedKeys.contains)
          HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(
                selected ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText)
              )
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
      .scrollContentBackground(.hidden)
      .background(theme.mutedSurface)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(theme.stroke, lineWidth: 1)
      }

      // Bottom "selected files" area
      VStack(alignment: .leading, spacing: 8) {
        Text("已选 \(selectedFiles.count) 首：")
          .font(.caption)
          .foregroundColor(theme.mutedText)

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(selectedFiles, id: \.id) { f in
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

        Button("添加 \(selectedFiles.count) 首") {
          guard let targetID = addFromQueueTargetPlaylistID else {
            showAddFromQueueSheet = false
            return
          }
          let urls = selectedFiles.map(\.url)
          playlistsStore.addTracks(urls, to: targetID)
          showAddFromQueueSheet = false
          reloadSelectedPlaylist()
          postToast(title: "已添加 \(urls.count) 首", subtitle: nil, kind: "success")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selectedFiles.isEmpty)
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
