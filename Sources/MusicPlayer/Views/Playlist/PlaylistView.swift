import AppKit
import SwiftUI

struct PlaylistView: View {
  let audioPlayer: AudioPlayer
  let playlistManager: PlaylistManager
  let playlistsStore: PlaylistsStore
  let isCompactRoot: Bool
  let isActive: Bool

  @StateObject private var viewModel: PlaylistViewModel
  @State private var showingMetadataEdit = false
  @State private var selectedFileForEdit: AudioFile?
  @State private var metadataEditWindow: NSWindow?
  @State private var playlistLocateRequestID: Int = 0
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  init(
    audioPlayer: AudioPlayer,
    playlistManager: PlaylistManager,
    playlistsStore: PlaylistsStore,
    isCompactRoot: Bool = false,
    isActive: Bool = true
  ) {
    self.audioPlayer = audioPlayer
    self.playlistManager = playlistManager
    self.playlistsStore = playlistsStore
    self.isCompactRoot = isCompactRoot
    self.isActive = isActive
    _viewModel = StateObject(wrappedValue: PlaylistViewModel(
      audioPlayer: audioPlayer,
      playlistManager: playlistManager,
      playlistsStore: playlistsStore,
      weights: playlistManager.playbackWeights
    ))
  }

  var body: some View {
    Group {
      if isActive {
        playlistContent
      } else {
        Color.clear
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchPlaylistPanelToQueue)) { _ in
      viewModel.switchToQueue()
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchPlaylistPanelToPlaylists)) { _ in
      viewModel.switchToPlaylists()
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInQueue)) { _ in
      viewModel.switchToQueue()
      viewModel.requestScrollToNowPlayingInQueue()
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInPlaylist)) { _ in
      viewModel.switchToPlaylists()
      playlistLocateRequestID += 1
    }
  }

  private var playlistContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isCompactRoot {
        compactHeader
      } else {
        header
      }

      if viewModel.isQueueSelected {
        QueuePanel(
          viewModel: viewModel,
          onRequestEditMetadata: { file in
            selectedFileForEdit = file
            showingMetadataEdit = true
          }
        )
      } else {
        PlaylistsPanel(
          audioPlayer: audioPlayer,
          playlistManager: playlistManager,
          playlistsStore: playlistsStore,
          locateNowPlayingRequestID: playlistLocateRequestID,
          isCompactRoot: isCompactRoot,
          onRequestEditMetadata: { file in
            selectedFileForEdit = file
            showingMetadataEdit = true
          }
        )
      }
    }
    .background(Color.clear)
    .onAppear {
      AppFocusState.shared.activeSearchTarget = viewModel.isQueueSelected ? .queue : .playlists
    }
    .onChange(of: viewModel.panelMode) { _ in
      AppFocusState.shared.activeSearchTarget = viewModel.isQueueSelected ? .queue : .playlists
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
    .onChange(of: showingMetadataEdit) { isShowing in
      if isShowing, let file = selectedFileForEdit {
        showMetadataEditWindow(for: file)
        showingMetadataEdit = false
      }
    }
    .onDisappear {
      if let window = metadataEditWindow {
        window.close()
        metadataEditWindow = nil
        selectedFileForEdit = nil
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 18) {
        headerIdentity
        Spacer(minLength: 16)
        panelTabs
        headerActions
      }
      .frame(minWidth: 680, maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 14) {
        headerIdentity
        HStack(alignment: .center, spacing: 12) {
          panelTabs
          Spacer(minLength: 8)
          headerActions
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 24)
    .padding(.top, 24)
    .padding(.bottom, 18)
    .contentShape(Rectangle())
    .onTapGesture {
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
  }

  private var compactHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      Text(viewModel.isQueueSelected ? "播放队列" : "我的歌单")
        .font(AppTheme.musicDisplayFont(size: 22, weight: .bold))
        .foregroundStyle(theme.stagePrimaryText)
        .lineLimit(1)

      Spacer(minLength: 8)

      panelTabs
      headerActions
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .onTapGesture {
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
  }

  private var headerIdentity: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(viewModel.isQueueSelected ? "播放队列" : "我的歌单")
        .font(AppTheme.musicDisplayFont(size: 30, weight: .bold))
        .foregroundStyle(theme.stagePrimaryText)

      HStack(spacing: 10) {
        Text(viewModel.isQueueSelected
          ? "\(viewModel.playlistManager.audioFiles.count) 首本地音乐"
          : "整理你的收藏")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(theme.mutedText)

        if let badge = viewModel.activePlaybackScopeBadge {
          Button(action: {
            viewModel.handleScopeBadgeTap(badge)
          }) {
            HStack(spacing: 5) {
              ActivePlaybackScopeIndicator(
                systemName: viewModel.scopeIndicatorSystemName,
                isPlaying: viewModel.audioPlayer.isPlaying
              )
              Text(badge.title)
                .lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.accent)
          }
          .buttonStyle(.plain)
          .help(badge.help)
        }
      }
    }
  }

  private var panelTabs: some View {
    HStack(spacing: 18) {
      panelTab(title: "队列", isSelected: viewModel.isQueueSelected) {
        viewModel.switchToQueue()
      }
      panelTab(title: "歌单", isSelected: viewModel.isPlaylistsSelected) {
        viewModel.switchToPlaylists()
      }
    }
  }

  private var headerActions: some View {
    HStack(spacing: 8) {
      if viewModel.isQueueSelected {
        FileSelectionView(isLibraryEmpty: viewModel.playlistManager.audioFiles.isEmpty) { urls in
          viewModel.enqueueFiles(urls)
        }
      } else {
        Button(action: { viewModel.createPlaylist() }) {
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
        .disabled(!viewModel.playlistsStore.isReady)
        .help(viewModel.playlistsStore.isReady ? "新建歌单" : "正在加载歌单…")
      }

      Button {
        if viewModel.isQueueSelected {
          viewModel.requestScrollToNowPlayingInQueue()
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
        viewModel.isQueueSelected
          ? viewModel.nowPlayingIDInQueue() == nil
          : viewModel.audioPlayer.currentFile == nil
      )
      .help("定位正在播放")

      Menu {
        if viewModel.isQueueSelected {
          Toggle("扫描子文件夹", isOn: viewModel.scanSubfoldersBinding)
          Divider()
        }

        Button("完全刷新") {
          viewModel.refreshAllMetadata()
        }
        .disabled(viewModel.playlistManager.audioFiles.isEmpty)

        if viewModel.isQueueSelected {
          Divider()
          Button("清空队列", role: .destructive) {
            viewModel.clearQueue()
          }
          .disabled(viewModel.playlistManager.audioFiles.isEmpty)
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

  private func panelTab(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 5) {
        Text(title)
          .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(isSelected ? theme.stagePrimaryText : theme.mutedText)

        Rectangle()
          .fill(isSelected ? theme.accent : Color.clear)
          .frame(height: 2)
      }
      .contentShape(Rectangle())
      .fixedSize()
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: - Metadata Edit Window

  private func showMetadataEditWindow(for file: AudioFile) {
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

    metadataEditWindow = window

    let metadataEditView = MetadataEditView(
      audioFile: file,
      onSave: { title, artist, album, year, genre, _ in
        Task {
          await MainActor.run {
            playlistManager.updateFileMetadata(
              file, title: title, artist: artist, album: album, year: year, genre: genre)
          }

          await LyricsService.shared.invalidate(for: file.url)
          let result = await LyricsService.shared.loadLyrics(for: file.url)
          await MainActor.run {
            switch result {
            case .success(let timeline):
              if let idx = playlistManager.audioFiles.firstIndex(where: { $0.url == file.url }) {
                let f = playlistManager.audioFiles[idx]
                playlistManager.audioFiles[idx] = AudioFile(
                  url: f.url, metadata: f.metadata, lyricsTimeline: timeline, duration: f.duration)
              }
              if let current = audioPlayer.currentFile, current.url == file.url {
                audioPlayer.lyricsTimeline = timeline
                audioPlayer.currentFile = AudioFile(
                  url: current.url, metadata: current.metadata, lyricsTimeline: timeline,
                  duration: current.duration)
                audioPlayer.reloadCurrentPreservingState()
              }
            case .failure:
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
    window.minSize = NSSize(width: 400, height: 500)
    window.isReleasedWhenClosed = false
  }
}
