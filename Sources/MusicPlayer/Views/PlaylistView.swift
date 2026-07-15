import AppKit
import SwiftUI

struct PlaylistView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @ObservedObject var playlistsStore: PlaylistsStore
  @ObservedObject private var sortState = SearchSortState.shared
  @ObservedObject private var weights = PlaybackWeights.shared
  @State private var showingMetadataEdit = false
  @State private var selectedFileForEdit: AudioFile?
  @State private var metadataEditWindow: NSWindow?
  @State private var queueScrollTargetID: String?
  @State private var queueScrollTask: Task<Void, Never>?
  @State private var queueVisibleFiles: [AudioFile] = []
  @State private var queueRefreshTask: Task<Void, Never>?
  @State private var queueVisibleRevision: UInt64 = 0
  @State private var playlistLocateRequestID: Int = 0
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  private enum PanelMode: Int {
    case queue = 0
    case playlists = 1
  }

  /// Persist last opened panel (queue vs playlists) so relaunch returns to where user left off.
  @AppStorage("userPlaylistPanelMode") private var panelModeRaw: Int = PanelMode.queue.rawValue

  private var panelMode: PanelMode {
    get { PanelMode(rawValue: panelModeRaw) ?? .queue }
    nonmutating set { panelModeRaw = newValue.rawValue }
  }

  private struct PlaybackScopeBadge {
    let title: String
    let targetPanel: PanelMode
    let help: String
  }

  private var scopeIndicatorSystemName: String {
    audioPlayer.playbackMode == .repeatOne ? "repeat" : "shuffle"
  }

  private var activePlaybackScopeBadge: PlaybackScopeBadge? {
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

  private var currentHighlightedURL: URL? {
    // For normal playback (queue-based), rely on PlaylistManager selection to avoid any
    // transient `AudioPlayer.currentFile` toggling during async loads.
    if audioPlayer.persistPlaybackState,
      playlistManager.currentIndex >= 0,
      playlistManager.currentIndex < playlistManager.audioFiles.count
    {
      return playlistManager.audioFiles[playlistManager.currentIndex].url
    }
    // For ephemeral playback (external open, not in queue), fall back to the loaded file.
    return audioPlayer.currentFile?.url
  }

  private var queueSourceFiles: [AudioFile] {
    playlistManager.searchText.isEmpty ? playlistManager.audioFiles : playlistManager.filteredFiles
  }

  private var displayedQueueFiles: [AudioFile] {
    if !queueVisibleFiles.isEmpty || queueSourceFiles.isEmpty {
      return queueVisibleFiles
    }
    return sortState.option(for: .queue).applying(to: queueSourceFiles, weightScope: .queue)
  }

  // 确保窗口在视图销毁时被清理
  init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager, playlistsStore: PlaylistsStore) {
    self.audioPlayer = audioPlayer
    self.playlistManager = playlistManager
    self.playlistsStore = playlistsStore
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 18) {
        VStack(alignment: .leading, spacing: 5) {
          Text(panelMode == .queue ? "播放队列" : "我的歌单")
            .font(AppTheme.musicDisplayFont(size: 30, weight: .bold))
            .foregroundStyle(theme.stagePrimaryText)

          HStack(spacing: 10) {
            Text(panelMode == .queue ? "\(playlistManager.audioFiles.count) 首本地音乐" : "整理你的收藏")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(theme.mutedText)

            if let scopeBadge = activePlaybackScopeBadge {
              Button(action: {
                panelMode = scopeBadge.targetPanel
                NotificationCenter.default.post(name: .blurSearchField, object: nil)
              }) {
                HStack(spacing: 5) {
                  ActivePlaybackScopeIndicator(
                    systemName: scopeIndicatorSystemName, isPlaying: audioPlayer.isPlaying)
                  Text(scopeBadge.title)
                    .lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
              }
              .buttonStyle(.plain)
              .help(scopeBadge.help)
            }
          }
        }

        Spacer(minLength: 16)

        HStack(spacing: 18) {
          panelTab(title: "队列", mode: .queue)
          panelTab(title: "歌单", mode: .playlists)
        }

        HStack(spacing: 8) {
          if panelMode == .queue {
            FileSelectionView(isLibraryEmpty: playlistManager.audioFiles.isEmpty) { urls in
              playlistManager.enqueueAddFiles(urls)
            }
          } else {
            Button(action: { createPlaylist() }) {
              Label("新建", systemImage: "plus")
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
            .disabled(!playlistsStore.isReady)
            .help(playlistsStore.isReady ? "新建歌单" : "正在加载歌单…")
          }

          Button {
            if panelMode == .queue {
              requestScrollToNowPlayingInQueue()
            } else {
              playlistLocateRequestID += 1
            }
          } label: {
            Image(systemName: "scope")
              .font(.system(size: 13, weight: .medium))
              .frame(width: 30, height: 30)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(
            panelMode == .queue
              ? nowPlayingIDInQueue() == nil
              : audioPlayer.currentFile == nil
          )
          .help("定位正在播放")

          Menu {
            if panelMode == .queue {
              Toggle("扫描子文件夹", isOn: $playlistManager.scanSubfolders)
              Divider()
            }

            Button("完全刷新") {
              Task { await playlistManager.refreshAllMetadata(audioPlayer: audioPlayer) }
            }
            .disabled(playlistManager.audioFiles.isEmpty)

            if panelMode == .queue {
              Divider()
              Button("清空队列", role: .destructive) {
                playlistManager.clearAllFiles()
                audioPlayer.stopAndClearCurrent()
              }
              .disabled(playlistManager.audioFiles.isEmpty)
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 30, height: 30)
              .contentShape(Rectangle())
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .help("更多操作")
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 18)
      .contentShape(Rectangle())
      .onTapGesture {
        // 点击标题栏/操作按钮区域时，也取消搜索框聚焦
        NotificationCenter.default.post(name: .blurSearchField, object: nil)
      }

      if panelMode == .queue {
        SearchBarView(
          searchText: $playlistManager.searchText,
          onSearchChanged: { query in
            playlistManager.searchFiles(query)
          }, focusTarget: .queue
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        // 搜索框以外区域：点击自动取消搜索框聚焦
        VStack(alignment: .leading, spacing: 0) {
          // 搜索统计
          if !playlistManager.searchText.isEmpty {
            HStack {
              Text(
                "找到 \(playlistManager.filteredFiles.count) / \(playlistManager.audioFiles.count) 首歌曲"
              )
              .font(.caption)
              .foregroundColor(.secondary)
              Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
          }

          // 播放列表
          if playlistManager.isInitialRestorePending || playlistManager.isRestoringPlaylist {
            RestoringPlaylistView()
          } else if displayedQueueFiles.isEmpty {
            EmptyPlaylistView()
          } else {
            TrackListColumnHeader()
              .padding(.horizontal, 12)

            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 0) {
                  ForEach(displayedQueueFiles.indices, id: \.self) { index in
                    let file = displayedQueueFiles[index]
                    PlaylistItemView(
                  trackNumber: index + 1,
                  file: file,
                  isCurrentTrack: currentHighlightedURL == file.url,
                  isVolumeAnalyzed: audioPlayer.hasVolumeNormalizationCache(for: file.url),
                  unplayableReason: playlistManager.unplayableReason(for: file.url),
                  searchText: playlistManager.searchText,
                  playAction: { selectedFile in
                    // 点击列表条目也顺便取消搜索聚焦
                    NotificationCenter.default.post(name: .blurSearchField, object: nil)
                    // 从队列播放：后续“下一首/随机/骰子”等都应作用于队列范围
                    playlistManager.setPlaybackScopeQueue()
                    guard let index = playlistManager.audioFiles.firstIndex(of: selectedFile),
                      let file = playlistManager.selectFile(at: index)
                    else { return }
                    audioPlayer.selectOrResume(file)
                  },
                  deleteAction: { fileToDelete in
                    NotificationCenter.default.post(name: .blurSearchField, object: nil)
                    // 删除前判断是否命中已安装播放器或仍在加载的目标。
                    let isDeletingPlaybackReference =
                      audioPlayer.currentFile?.url == fileToDelete.url ||
                      audioPlayer.pendingPlaybackURL == fileToDelete.url
                    if let index = playlistManager.audioFiles.firstIndex(of: fileToDelete) {
                      // 先执行删除
                      let removalContext = playlistManager.removeFile(at: index)

                      // 若删除命中播放状态，根据播放模式处理。
                      if isDeletingPlaybackReference {
                        // 删除后剩余文件列表（从真实数据源拿）
                        let remaining = playlistManager.audioFiles

                        // 如果后续需要顺序“下一首”，可在此提供闭包：playNext: { playlistManager.nextAfterDeletion(from: index) }
                        // 现阶段按约定：单曲循环->停止并清空；随机->随机一首；其他->停止并清空
                        audioPlayer.handleRemovedTrack(
                          fileToDelete.url,
                          remainingFiles: remaining,
                          playNext: {
                            removalContext.flatMap {
                              playlistManager.nextFileAfterRemovingQueueItem($0)
                            }
                          },
                          playRandom: { playlistManager.getRandomFile() },
                          restoreInstalledSelection: {
                            guard let installedURL = audioPlayer.currentFile?.url,
                              let installedIndex = playlistManager.audioFiles.firstIndex(
                                where: { $0.url == installedURL }
                              )
                            else { return }
                            _ = playlistManager.selectFile(at: installedIndex)
                          }
                        )
                      }
                    }
                  },
                  editAction: { fileToEdit in
                    NotificationCenter.default.post(name: .blurSearchField, object: nil)
                    selectedFileForEdit = fileToEdit
                    showingMetadataEdit = true
                  },
                  weightLevel: weights.level(for: file.url, scope: .queue),
                  onWeightSelect: { newLevel in
                    let result = weights.setLevel(newLevel, for: file.url, scope: .queue)
                    switch result {
                    case .applied, .unchanged:
                      break
                    case .rejectedReadOnly(let reason):
                      NotificationCenter.default.post(
                        name: .showAppToast,
                        object: nil,
                        userInfo: ["title": "无法修改随机权重", "subtitle": reason.diagnosticMessage, "kind": "error", "duration": 4.0]
                      )
                    }
                  },
                  weightScopeLabel: "队列"
                    )
                    .id(file.id)
                  }
                }
                .padding(.horizontal, 12)
              }
              .background(Color.clear)
              .onChange(of: queueScrollTargetID) { target in
                guard let target else { return }
                performQueueScrollSequence(targetID: target, proxy: proxy)
              }
              .onChange(of: queueVisibleRevision) { _ in
                guard let target = queueScrollTargetID else { return }
                performQueueScrollSequence(targetID: target, proxy: proxy)
              }
              .onChange(of: playlistManager.searchText) { _ in
                guard let target = queueScrollTargetID else { return }
                performQueueScrollSequence(targetID: target, proxy: proxy)
              }
              .onAppear {
                guard let target = queueScrollTargetID else { return }
                performQueueScrollSequence(targetID: target, proxy: proxy)
              }
            }
          }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          NotificationCenter.default.post(name: .blurSearchField, object: nil)
        }
      } else {
        PlaylistsPanelView(
          audioPlayer: audioPlayer,
          playlistManager: playlistManager,
          playlistsStore: playlistsStore,
          locateNowPlayingRequestID: playlistLocateRequestID,
          onRequestEditMetadata: { file in
            selectedFileForEdit = file
            showingMetadataEdit = true
          }
        )
      }
    }
    .background(Color.clear)
    .onAppear {
      AppFocusState.shared.activeSearchTarget = (panelMode == .queue) ? .queue : .playlists
      refreshQueueVisibleFiles()
    }
    .onReceive(playlistManager.$filteredFiles) { _ in
      refreshQueueVisibleFiles()
    }
    .onReceive(playlistManager.$audioFiles) { _ in
      refreshQueueVisibleFiles()
    }
    .onChange(of: sortState.revision) { _ in
      refreshQueueVisibleFiles()
    }
    .onChange(of: weights.revision) { _ in
      if sortState.option(for: .queue).field == .weight {
        refreshQueueVisibleFiles()
      }
    }
    .onChange(of: playlistManager.isInitialRestorePending) { _ in
      refreshQueueVisibleFiles()
    }
    .onChange(of: playlistManager.isRestoringPlaylist) { _ in
      refreshQueueVisibleFiles()
    }
    .onChange(of: currentHighlightedURL) { _ in
      refreshQueueVisibleFiles()
    }
    .onChange(of: panelModeRaw) { _ in
      AppFocusState.shared.activeSearchTarget = (panelMode == .queue) ? .queue : .playlists
      // 切换面板时清掉旧的搜索框焦点，避免 Cmd+F 来回跳
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
      if panelMode == .queue {
        refreshQueueVisibleFiles()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchPlaylistPanelToQueue)) { _ in
      panelMode = .queue
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchPlaylistPanelToPlaylists)) { _ in
      panelMode = .playlists
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInQueue)) { _ in
      panelMode = .queue
      requestScrollToNowPlayingInQueue()
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInPlaylist)) { _ in
      panelMode = .playlists
      playlistLocateRequestID += 1
    }
    .onChange(of: showingMetadataEdit) { isShowing in
      if isShowing, let file = selectedFileForEdit {
        showMetadataEditWindow(for: file)
        showingMetadataEdit = false
      }
    }
    .onDisappear {
      queueRefreshTask?.cancel()
      queueRefreshTask = nil
      queueScrollTask?.cancel()
      // 视图消失时确保清理窗口资源
      if let window = metadataEditWindow {
        window.close()
        metadataEditWindow = nil
        selectedFileForEdit = nil
      }
    }
  }

  private func panelTab(title: String, mode: PanelMode) -> some View {
    Button {
      panelMode = mode
    } label: {
      VStack(spacing: 5) {
        Text(title)
          .font(.system(size: 12, weight: panelMode == mode ? .semibold : .medium))
          .foregroundStyle(panelMode == mode ? Color.primary : theme.mutedText)

        Rectangle()
          .fill(panelMode == mode ? theme.accent : Color.clear)
          .frame(height: 2)
      }
      .contentShape(Rectangle())
      .fixedSize()
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(panelMode == mode ? .isSelected : [])
  }

  private func nowPlayingIDInQueue() -> String? {
    guard let url = currentHighlightedURL else { return nil }
    let id = PathKey.canonical(for: url)
    let idLookup = Set(PathKey.lookupKeys(for: url))
    guard
      playlistManager.audioFiles.contains(where: {
        !idLookup.isDisjoint(with: Set(PathKey.lookupKeys(for: $0.url)))
      })
    else { return nil }
    return id
  }

  @MainActor
  private func requestScrollToNowPlayingInQueue() {
    guard let id = nowPlayingIDInQueue() else { return }
    // Ensure the current track is visible.
    playlistManager.searchFiles("")
    queueScrollTargetID = id
  }

  @MainActor
  private func performQueueScrollSequence(targetID: String, proxy: ScrollViewProxy) {
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

  @MainActor
  private func refreshQueueVisibleFiles() {
    // Published queue changes can arrive while SwiftUI's backing NSTableView is
    // inside a delegate callback. Coalesce them onto the next main-actor turn
    // so row updates never re-enter AppKit's table delegate.
    queueRefreshTask?.cancel()
    queueRefreshTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled else { return }
      queueVisibleFiles = sortState.option(for: .queue).applying(
        to: queueSourceFiles, weightScope: .queue)
      queueVisibleRevision &+= 1
    }
  }

  @MainActor
  private func createPlaylist() {
    let name = TextInputPrompt.prompt(
      title: "新建歌单",
      message: "输入歌单名称",
      defaultValue: "",
      okTitle: "创建",
      cancelTitle: "取消"
    )
    playlistsStore.createPlaylist(name: name ?? "")
  }

  private func showMetadataEditWindow(for file: AudioFile) {
    // 如果已经有窗口打开，先关闭它
    if let existingWindow = metadataEditWindow {
      existingWindow.close()
      metadataEditWindow = nil
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    // 保存窗口引用
    metadataEditWindow = window

    let metadataEditView = MetadataEditView(
      audioFile: file,
      onSave: { title, artist, album, year, genre, _ in
        // 此处不再调用 MetadataEditor.updateMetadata：由编辑窗口自身完成保存
        // 仅更新列表显示的元数据，并刷新歌词解析结果
        Task {
          await MainActor.run {
            playlistManager.updateFileMetadata(
              file, title: title, artist: artist, album: album, year: year, genre: genre)
          }

          // 刷新该文件的歌词缓存并加载最新时间轴
          await LyricsService.shared.invalidate(for: file.url)
          let result = await LyricsService.shared.loadLyrics(for: file.url)
          await MainActor.run {
            switch result {
            case .success(let timeline):
              // 更新列表里的条目
              if let idx = playlistManager.audioFiles.firstIndex(where: { $0.url == file.url }) {
                let f = playlistManager.audioFiles[idx]
                playlistManager.audioFiles[idx] = AudioFile(
                  url: f.url, metadata: f.metadata, lyricsTimeline: timeline, duration: f.duration)
              }
              // 如果正在播放当前歌曲，更新播放器里的时间轴
              if let current = audioPlayer.currentFile, current.url == file.url {
                audioPlayer.lyricsTimeline = timeline
                audioPlayer.currentFile = AudioFile(
                  url: current.url, metadata: current.metadata, lyricsTimeline: timeline,
                  duration: current.duration)
                // 重新载入底层播放器以确保持续播放但读取到新文件内容
                audioPlayer.reloadCurrentPreservingState()
              }
            case .failure:
              // 清空时间轴
              if let idx = playlistManager.audioFiles.firstIndex(where: { $0.url == file.url }) {
                let f = playlistManager.audioFiles[idx]
                playlistManager.audioFiles[idx] = AudioFile(
                  url: f.url, metadata: f.metadata, lyricsTimeline: nil, duration: f.duration)
              }
              if let current = audioPlayer.currentFile, current.url == file.url {
                audioPlayer.lyricsTimeline = nil
                audioPlayer.currentFile = AudioFile(
                  url: current.url, metadata: current.metadata, lyricsTimeline: nil,
                  duration: current.duration)
                audioPlayer.reloadCurrentPreservingState()
              }
            }

            // 关闭窗口
            selectedFileForEdit = nil
            window.close()
            metadataEditWindow = nil
          }
        }
      },
      onCancel: {
        selectedFileForEdit = nil
        window.close()
        metadataEditWindow = nil
      }
    )

    let themedMetadataEditView = metadataEditView.preferredColorScheme(colorScheme)
    let hostingController = NSHostingController(rootView: themedMetadataEditView)

    window.title = "编辑元数据 - \(file.url.lastPathComponent)"
    window.appearance = NSAppearance(
      named: colorScheme == .dark ? .darkAqua : .aqua
    )
    window.contentViewController = hostingController
    window.center()
    window.makeKeyAndOrderFront(nil)

    // 设置窗口的最小大小
    window.minSize = NSSize(width: 400, height: 500)

    // 防止子窗口关闭时退出整个应用
    window.isReleasedWhenClosed = false
  }
}

struct SearchBarView: View {
  @Binding var searchText: String
  let onSearchChanged: (String) -> Void
  let focusTarget: SearchFocusTarget
  var autoFocusOnAppear: Bool = false
  @ObservedObject private var sortState = SearchSortState.shared
  @FocusState private var isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundColor(theme.mutedText)
        .font(.system(size: 13, weight: .medium))

      TextField("搜索歌曲、艺术家或专辑...", text: $searchText)
        .textFieldStyle(PlainTextFieldStyle())
        .font(.subheadline)
        .focused($isFocused)
        .onChange(of: searchText) { newValue in
          onSearchChanged(newValue)
        }
        .onChange(of: isFocused) { focused in
          if focused {
            AppFocusState.shared.activeSearchTarget = focusTarget
            AppFocusState.shared.isSearchFocused = true
          } else {
            if AppFocusState.shared.activeSearchTarget == focusTarget {
              AppFocusState.shared.isSearchFocused = false
            }
          }
        }

      if !searchText.isEmpty {
        Button(action: {
          searchText = ""
          onSearchChanged("")
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(theme.mutedText)
            .font(.headline)
        }
        .buttonStyle(PlainButtonStyle())
      }

      SearchSortButton(target: focusTarget, helpSuffix: "仅影响列表显示，不改变队列/歌单顺序。")
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(theme.surface)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(
            isFocused ? theme.accent : theme.controlStroke,
            lineWidth: isFocused ? 1.5 : 1
          )
      }
    )
    .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { notification in
      let requestedTarget = (notification.userInfo?["target"] as? String).flatMap {
        SearchFocusTarget(rawValue: $0)
      }
      if let requestedTarget {
        guard requestedTarget == focusTarget else { return }
      } else {
        // No explicit target: focus only the current active search target.
        guard AppFocusState.shared.activeSearchTarget == focusTarget else { return }
      }
      AppFocusState.shared.activeSearchTarget = focusTarget
      isFocused = true
      AppFocusState.shared.isSearchFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .blurSearchField)) { _ in
      isFocused = false
      if AppFocusState.shared.activeSearchTarget == focusTarget {
        AppFocusState.shared.isSearchFocused = false
      }
    }
    .onAppear {
      DispatchQueue.main.async {
        if autoFocusOnAppear {
          AppFocusState.shared.activeSearchTarget = focusTarget
          isFocused = true
          AppFocusState.shared.isSearchFocused = true
        } else {
          // 防止窗口初次展示时自动获得焦点
          isFocused = false
          if AppFocusState.shared.activeSearchTarget == focusTarget {
            AppFocusState.shared.isSearchFocused = false
          }
        }
      }
    }
  }
}

struct PlaylistItemView: View {
  let trackNumber: Int
  let file: AudioFile
  let isCurrentTrack: Bool
  let isVolumeAnalyzed: Bool
  let unplayableReason: String?
  let searchText: String
  let playAction: (AudioFile) -> Void
  let deleteAction: (AudioFile) -> Void
  let editAction: (AudioFile) -> Void
  let weightLevel: PlaybackWeights.Level
  let onWeightSelect: (PlaybackWeights.Level) -> Void
  var weightScopeLabel: String = "歌单"
  @State private var isHovered = false
  @State private var isPlaybackRegionHovered = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(isCurrentTrack ? theme.accent : Color.clear)
        .frame(width: 3, height: 34)
        .padding(.trailing, 11)

      HStack(spacing: 11) {
        Button {
          playAction(file)
        } label: {
          HStack(spacing: 11) {
            Group {
              if unplayableReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 11, weight: .semibold))
              } else if isPlaybackRegionHovered {
                Image(systemName: "play.fill")
                  .font(.system(size: 11, weight: .semibold))
              } else {
                Text(String(format: "%02d", trackNumber))
                  .font(.system(size: 11, weight: .medium, design: .rounded))
                  .monospacedDigit()
              }
            }
            .foregroundStyle(leadingColor)
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 7) {
                Text(highlightedText(file.metadata.title, searchText: searchText))
                  .font(.system(size: 13, weight: .semibold))
                  .lineLimit(1)
                  .foregroundStyle(unplayableReason == nil ? Color.primary : Color.secondary)

                if isVolumeAnalyzed {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.mutedText.opacity(0.72))
                    .help("音量均衡已分析")
                    .accessibilityLabel("音量均衡已分析")
                }
              }

              Text(
                "\(highlightedText(file.metadata.artist, searchText: searchText)) · \(highlightedText(file.metadata.album, searchText: searchText))"
              )
              .font(.system(size: 11))
              .foregroundColor(theme.mutedText)
              .lineLimit(1)
              .help(file.url.lastPathComponent)
            }

            Spacer(minLength: 10)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(trackAccessibilityLabel)
        .accessibilityHint(unplayableReason.map { "不可播放：\($0)" } ?? "播放歌曲")
        .accessibilityAddTraits(isCurrentTrack ? .isSelected : [])
        .onHover { hovering in
          isPlaybackRegionHovered = hovering
        }

        WeightBlocksView(
          level: weightLevel,
          scopeLabel: weightScopeLabel,
          itemLabel: file.metadata.title
        ) { newLevel in
          onWeightSelect(newLevel)
        }
        // Keep the full picker footprint—including its padding and the gaps
        // between visible squares—outside the playback button's hit region.
        .padding(.horizontal, 4)
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(2)

        Text(durationLabel)
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .foregroundColor(theme.mutedText.opacity(file.duration == nil ? 0.55 : 0.9))
          .frame(width: 42, alignment: .trailing)
          .accessibilityLabel(file.duration == nil ? "时长加载中" : "时长 \(durationLabel)")
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 2) {
        Button(action: { editAction(file) }) {
          Image(systemName: "pencil")
            .foregroundColor(buttonColor(for: file))
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!MetadataEditor.canShowEditButton(for: file.url))
        .help(helpText(for: file))

        Button(action: { deleteAction(file) }) {
          Image(systemName: "trash")
            .foregroundColor(theme.destructive)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("从列表移除")
      }
      .padding(.leading, 4)
      .opacity(isHovered ? 1 : 0)
      .allowsHitTesting(isHovered)
      .animation(AppTheme.smoothTransition, value: isHovered)
    }
    .padding(.horizontal, 8)
    .frame(minHeight: 54)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isCurrentTrack
            ? theme.selectedSurface
            : (isHovered ? theme.hoverSurface : Color.clear)
        )
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(isCurrentTrack || isHovered ? Color.clear : theme.paneDivider)
        .frame(height: 1)
        .padding(.leading, 46)
    }
    .onHover { hovering in
      isHovered = hovering
    }
    .contextMenu {
      Menu("随机权重") {
        ForEach(PlaybackWeights.Level.allCases, id: \.rawValue) { level in
          Button {
            onWeightSelect(level)
          } label: {
            if level == weightLevel {
              Label(weightLabel(level), systemImage: "checkmark")
            } else {
              Text(weightLabel(level))
            }
          }
        }
      }

      Divider()

      if MetadataEditor.canShowEditButton(for: file.url) {
        Button("编辑元数据…") {
          editAction(file)
        }

        Divider()
      }

      Button("从列表移除", role: .destructive) {
        deleteAction(file)
      }
    }
  }

  private var trackAccessibilityLabel: String {
    [file.metadata.title, file.metadata.artist, file.metadata.album]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "，")
  }

  private var leadingColor: Color {
    if isCurrentTrack { return theme.accent }
    if unplayableReason != nil { return theme.warning }
    return isPlaybackRegionHovered ? theme.stagePrimaryText : theme.stageTertiaryText
  }

  private func weightLabel(_ level: PlaybackWeights.Level) -> String {
    let value = weightValueLabel(level)
    return level == .defaultLevel ? "\(value)（默认）" : value
  }

  private func weightValueLabel(_ level: PlaybackWeights.Level) -> String {
    "第 \(level.rawValue + 1) 档 · \(String(format: "%.1f", level.multiplier))×"
  }

  private func buttonColor(for file: AudioFile) -> Color {
    let buttonType = MetadataEditor.getEditButtonType(for: file.url)

    switch buttonType {
    case .directEdit, .ffmpegCommand:
      return theme.stageSecondaryText
    case .notSupported, .hidden:
      return theme.disabledText
    }
  }

  private func helpText(for file: AudioFile) -> String {
    let format = file.url.pathExtension.uppercased()
    let buttonType = MetadataEditor.getEditButtonType(for: file.url)

    switch buttonType {
    case .directEdit:
      return "编辑 \(format) 元数据"
    case .ffmpegCommand:
      return "\(format) 格式支持FFmpeg命令编辑（点击生成命令）"
    case .notSupported:
      return "\(format) 格式元数据支持有限（点击了解详情）"
    case .hidden:
      return "此格式不支持元数据编辑"
    }
  }

  private var durationLabel: String {
    guard let seconds = file.duration else { return "--:--" }
    return formatDuration(seconds)
  }

  private func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "--:--" }
    let total = Int(seconds.rounded(.towardZero))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
  }

  private func highlightedText(_ text: String, searchText: String) -> AttributedString {
    guard !searchText.isEmpty else {
      return AttributedString(text)
    }

    var attributedString = AttributedString(text)

    if let range = text.range(of: searchText, options: .caseInsensitive) {
      let nsRange = NSRange(range, in: text)
      if let attributedRange = Range(nsRange, in: attributedString) {
        attributedString[attributedRange].backgroundColor = theme.accent.opacity(
          theme.scheme == .dark ? 0.28 : 0.18)
        attributedString[attributedRange].foregroundColor = Color.primary
      }
    }

    return attributedString
  }
}

struct EmptyPlaylistView: View {
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "music.note.list")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(theme.mutedText.opacity(0.72))

      VStack(spacing: 6) {
        Text("播放列表为空")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.primary)

        Text("点击“添加音乐”，或把文件拖进窗口")
          .font(.system(size: 12))
          .foregroundColor(theme.mutedText)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

struct RestoringPlaylistView: View {
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 18) {
      ProgressView()
        .controlSize(.regular)

      Text("正在恢复播放列表…")
        .font(.headline)
        .foregroundColor(.primary)

      Text("启动时正在读取上次队列，请稍候。")
        .font(.caption)
        .foregroundColor(theme.mutedText)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
