import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlaylistsPanel: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @ObservedObject var playlistsStore: PlaylistsStore

  let locateNowPlayingRequestID: Int
  let isCompactRoot: Bool
  let onRequestEditMetadata: (AudioFile) -> Void

  @ObservedObject private var weights = PlaybackWeights.shared
  @ObservedObject private var sortState = SearchSortState.shared

  @State private var trackSearchText: String = ""
  @State private var loadedTracks: [AudioFile] = []
  @State private var visibleTracks: [AudioFile] = []
  @State private var visibleTracksRevision: UInt64 = 0
  @State private var trackUnplayableReasons: [String: String] = [:]
  @State private var playlistDuration: TimeInterval?
  @State private var isLoadingTracks: Bool = false
  @State private var loadTask: Task<Void, Never>?
  @State private var playlistScrollTargetID: String?
  @State private var playlistScrollTask: Task<Void, Never>?
  @State private var playlistTableView: NSTableView?
  @State private var handledLocateNowPlayingRequestID: Int = 0
  @State private var artworkRevisions: [UserPlaylist.ID: UInt64] = [:]

  // Add-from-queue multi-select sheet
  @State private var showAddFromQueueSheet: Bool = false
  @State private var addFromQueueTargetPlaylistID: UserPlaylist.ID?
  @State private var addFromQueueSearchText: String = ""
  @State private var addFromQueueSelectedKeys: Set<String> = []

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  private var selectedPlaylist: UserPlaylist? {
    playlistsStore.playlist(for: playlistsStore.selectedPlaylistID)
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
    Group {
      if isCompactRoot {
        compactPlaylistLayout
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ViewThatFits(in: .horizontal) {
          widePlaylistLayout
            .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)

          compactPlaylistLayout
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .padding(.horizontal, isCompactRoot ? 16 : 24)
    .padding(.bottom, isCompactRoot ? 8 : 16)
    .sheet(isPresented: $showAddFromQueueSheet) {
      addFromQueueSheet
    }
    .onAppear {
      playlistsStore.loadIfNeeded()
      reloadSelectedPlaylist()
      refreshVisibleTracks()
      handlePendingLocateNowPlayingRequest()
    }
    .onDisappear {
      loadTask?.cancel()
      loadTask = nil
      playlistScrollTask?.cancel()
      playlistScrollTask = nil
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

  private var widePlaylistLayout: some View {
    HStack(spacing: 22) {
      playlistsSidebar
        .frame(width: 188)

      Rectangle()
        .fill(theme.paneDivider)
        .frame(width: 1)

      playlistDetail
    }
  }

  private var compactPlaylistLayout: some View {
    VStack(alignment: .leading, spacing: isCompactRoot ? 8 : 12) {
      compactPlaylistsStrip

      Rectangle()
        .fill(theme.paneDivider)
        .frame(height: 1)

      playlistDetail
    }
  }

  private var playlistsSidebar: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        EditorialSectionLabel(index: "A", title: "歌单目录")
        Spacer()
        importPlaylistButton
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
        List {
          ForEach(playlistsStore.playlists) { playlist in
            let isSelected = playlistsStore.selectedPlaylistID == playlist.id
            Button {
              playlistsStore.selectedPlaylistID = playlist.id
            } label: {
              HStack(spacing: 9) {
                Rectangle()
                  .fill(isSelected ? theme.accent : Color.clear)
                  .frame(width: 2, height: 30)

                PlaylistArtworkView(
                  playlist: playlist,
                  isActive: playlistManager.playbackScope == .playlist(playlist.id)
                    && audioPlayer.playbackTargetURL != nil,
                  targetPixelSize: 72,
                  revision: artworkRevisions[playlist.id] ?? 0
                )
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                  Text(playlist.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(theme.stagePrimaryText)
                    .lineLimit(1)
                  Text("\(playlist.tracks.count) 首")
                    .font(.system(size: 10))
                    .foregroundColor(theme.stageTertiaryText)
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
              .padding(.horizontal, 6)
              .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(isSelected ? theme.selectedSurface : Color.clear)
              )
              .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(playlist.name)，\(playlist.tracks.count) 首")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .contextMenu {
              playlistContextMenu(for: playlist)
            }
          }
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .background(Color.clear)
      }
    }
  }

  private var compactPlaylistsStrip: some View {
    VStack(alignment: .leading, spacing: isCompactRoot ? 4 : 8) {
      HStack {
        EditorialSectionLabel(index: "A", title: "歌单目录")
        Spacer()
        importPlaylistButton
      }

      if !playlistsStore.isReady {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在加载歌单…")
            .font(.caption)
            .foregroundColor(theme.mutedText)
        }
        .frame(height: isCompactRoot ? 42 : 56)
      } else if playlistsStore.playlists.isEmpty {
        Text("还没有歌单，点击上方“新建”开始使用。")
          .font(.caption)
          .foregroundColor(theme.mutedText)
          .frame(height: isCompactRoot ? 42 : 56, alignment: .leading)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 8) {
            ForEach(playlistsStore.playlists) { playlist in
              compactPlaylistButton(for: playlist)
            }
          }
          .padding(.vertical, 1)
        }
        .frame(height: isCompactRoot ? 44 : 58)
      }
    }
  }

  private var importPlaylistButton: some View {
    Button {
      importM3U8Playlist()
    } label: {
      Image(systemName: "square.and.arrow.down")
        .font(.system(size: 11))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!playlistsStore.isReady)
    .help("导入 M3U8 歌单")
    .accessibilityLabel("导入 M3U8 歌单")
  }

  private func compactPlaylistButton(for playlist: UserPlaylist) -> some View {
    let isSelected = playlistsStore.selectedPlaylistID == playlist.id
    let isActive = audioPlayer.playbackTargetURL != nil
      && audioPlayer.persistPlaybackState
      && playlistManager.playbackScope == .playlist(playlist.id)
    let artworkSize: CGFloat = isCompactRoot ? 34 : 42
    let buttonWidth: CGFloat = isCompactRoot ? 142 : 156
    let buttonHeight: CGFloat = isCompactRoot ? 44 : 56

    return Button {
      playlistsStore.selectedPlaylistID = playlist.id
    } label: {
      HStack(spacing: 8) {
        PlaylistArtworkView(
          playlist: playlist,
          isActive: isActive,
          targetPixelSize: isCompactRoot ? 72 : 96,
          revision: artworkRevisions[playlist.id] ?? 0
        )
        .frame(width: artworkSize, height: artworkSize)

        VStack(alignment: .leading, spacing: 3) {
          Text(playlist.name)
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(theme.stagePrimaryText)
            .lineLimit(1)
          Text("\(playlist.tracks.count) 首")
            .font(.system(size: 10))
            .foregroundColor(theme.stageTertiaryText)
        }

        Spacer(minLength: 0)

        if isActive {
          ActivePlaybackScopeIndicator(
            systemName: audioPlayer.isLooping ? "repeat" : "shuffle",
            isPlaying: audioPlayer.isPlaying
          )
        }
      }
      .padding(.horizontal, 7)
      .frame(width: buttonWidth, height: buttonHeight, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? theme.selectedSurface : theme.surface)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isSelected ? theme.accent.opacity(0.65) : theme.stroke, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(playlist.name)，\(playlist.tracks.count) 首")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .contextMenu {
      playlistContextMenu(for: playlist)
    }
  }

  @ViewBuilder
  private func playlistContextMenu(for playlist: UserPlaylist) -> some View {
    Button("设置歌单封面…") {
      choosePlaylistArtwork(playlist)
    }
    Button("恢复默认封面") {
      resetPlaylistArtwork(playlist)
    }
    Divider()
    Button("重命名…") {
      renamePlaylist(playlist)
    }
    Button("导出 M3U8…") {
      exportPlaylistAsM3U8(playlist)
    }
    Divider()
    Button("删除歌单", role: .destructive) {
      deletePlaylist(playlist)
    }
  }

  @ViewBuilder
  private var playlistDetail: some View {
    if let playlist = selectedPlaylist {
      playlistDetailContent(for: playlist)
    } else {
      noPlaylistSelectedView
    }
  }

  private func playlistDetailContent(for playlist: UserPlaylist) -> some View {
    VStack(alignment: .leading, spacing: isCompactRoot ? 8 : 14) {
      header(for: playlist)

      SearchBarView(searchText: $trackSearchText, focusTarget: .playlists)

      if !trackSearchText.isEmpty {
        playlistSearchStats
      }

      if !isCompactRoot && !isLoadingTracks && !visibleTracks.isEmpty {
        TrackListColumnHeader()
      }

      playlistTrackRegion(for: playlist)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
  }

  private var playlistSearchStats: some View {
    HStack {
      Text("找到 \(visibleTracks.count) / \(loadedTracks.count) 首歌曲")
        .font(.caption)
        .foregroundStyle(theme.stageSecondaryText)
      Spacer()
    }
  }

  private var noPlaylistSelectedView: some View {
    VStack(spacing: 10) {
      Text("请选择一个歌单")
        .font(.headline)
        .foregroundColor(theme.stagePrimaryText)
      Text("在歌单目录选择一个歌单，或新建一个歌单开始使用。")
        .font(.caption)
        .foregroundColor(theme.mutedText)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func playlistTrackRegion(for playlist: UserPlaylist) -> some View {
    ScrollViewReader { proxy in
      playlistTrackContent(for: playlist)
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

  @ViewBuilder
  private func playlistTrackContent(for playlist: UserPlaylist) -> some View {
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
        Text(playlist.tracks.isEmpty ? "可在歌单标题旁点击“从队列添加”。" : "试试更短的关键词。")
          .font(.caption)
          .foregroundColor(theme.mutedText.opacity(0.9))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      playlistTracksList(for: playlist)
    }
  }

  private func playlistTracksList(for playlist: UserPlaylist) -> some View {
    List {
      ForEach(visibleTracks.numberedTracks) { numberedTrack in
        playlistTrackRow(
          file: numberedTrack.file,
          number: numberedTrack.number,
          playlist: playlist
        )
      }
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

  private func playlistTrackRow(
    file: AudioFile,
    number: Int,
    playlist: UserPlaylist
  ) -> some View {
    TrackRowView(
      trackNumber: number,
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
            title: "文件不存在，无法编辑",
            subtitle: fileToEdit.url.lastPathComponent,
            kind: "warning"
          )
          return
        }
        onRequestEditMetadata(fileToEdit)
      },
      weightLevel: weights.level(for: file.url, scope: .playlist(playlist.id)),
      onWeightSelect: { newLevel in
        let result = weights.setLevel(newLevel, for: file.url, scope: .playlist(playlist.id))
        WeightCommands.handleSetWeightResult(result)
      }
    )
    .id(file.id)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  @ViewBuilder
  private func header(for playlist: UserPlaylist) -> some View {
    if isCompactRoot {
      HStack(spacing: 10) {
        playlistHeaderIdentity(for: playlist, compact: true)
        Spacer(minLength: 8)
        playlistHeaderActions(for: playlist)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
          playlistHeaderIdentity(for: playlist)
          Spacer(minLength: 12)
          playlistHeaderActions(for: playlist)
        }
        .frame(minWidth: 560, maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 10) {
          playlistHeaderIdentity(for: playlist)
          HStack {
            Spacer(minLength: 0)
            playlistHeaderActions(for: playlist)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.top, 6)
      .padding(.bottom, 2)
    }
  }

  private func playlistHeaderIdentity(
    for playlist: UserPlaylist,
    compact: Bool = false
  ) -> some View {
    HStack(spacing: compact ? 10 : 14) {
      playlistArtworkButton(for: playlist, size: compact ? 44 : 64)

      VStack(alignment: .leading, spacing: compact ? 2 : 5) {
        Text(playlist.name)
          .font(AppTheme.musicDisplayFont(size: compact ? 19 : 24, weight: .bold))
          .foregroundColor(theme.stagePrimaryText)
          .lineLimit(1)

        HStack(spacing: 7) {
          Text("\(playlist.tracks.count) 首")
          if let playlistDuration {
            Text("·")
            Text(Self.formatCollectionDuration(playlistDuration))
          }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(theme.stageTertiaryText)
      }
    }
  }

  private func playlistArtworkButton(for playlist: UserPlaylist, size: CGFloat = 64) -> some View {
    let isActive = playlistManager.playbackScope == .playlist(playlist.id)
      && audioPlayer.playbackTargetURL != nil

    return Button {
      choosePlaylistArtwork(playlist)
    } label: {
      PlaylistArtworkView(
        playlist: playlist,
        isActive: isActive,
        targetPixelSize: size <= 44 ? 112 : 160,
        revision: artworkRevisions[playlist.id] ?? 0
      )
      .frame(width: size, height: size)
      .overlay(alignment: .bottomTrailing) {
        ZStack {
          Image(systemName: "photo")
            .font(.system(size: 9, weight: .semibold))
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 7, weight: .bold))
            .offset(x: 5, y: 5)
        }
        .foregroundStyle(theme.stagePrimaryText)
        .frame(width: 20, height: 20)
        .background(theme.elevatedSurface, in: Circle())
        .overlay {
          Circle().stroke(theme.stroke, lineWidth: 1)
        }
        .offset(x: 4, y: 4)
      }
    }
    .buttonStyle(.plain)
    .help("更换“\(playlist.name)”的歌单封面")
    .accessibilityLabel("更换“\(playlist.name)”的歌单封面")
    .contextMenu {
      Button("选择图片…") {
        choosePlaylistArtwork(playlist)
      }
      Button("恢复默认封面") {
        resetPlaylistArtwork(playlist)
      }
    }
  }

  private func playlistHeaderActions(for playlist: UserPlaylist) -> some View {
    HStack(spacing: 8) {
      Button {
        guard
          let firstPlayable = loadedTracks.first(where: {
            trackUnplayableReasons[pathKey($0.url)] == nil
          })
        else { return }
        playTrackInPlaylist(firstPlayable, playlist: playlist)
      } label: {
        Label("播放", systemImage: "play.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.accentForeground)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(theme.accent)
          )
      }
      .buttonStyle(.plain)
      .disabled(loadedTracks.isEmpty)
      .opacity(loadedTracks.isEmpty ? 0.45 : 1)
      .help("从歌单第一首开始播放")

      Button {
        openAddFromQueueSheet(targetPlaylistID: playlist.id)
      } label: {
        Label("从队列添加", systemImage: "plus")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.stagePrimaryText)
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(theme.surface)
              .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .stroke(theme.stroke, lineWidth: 1)
              }
          )
      }
      .buttonStyle(.plain)
      .disabled(playlistManager.audioFiles.isEmpty)
      .help(playlistManager.audioFiles.isEmpty ? "队列为空：先在“队列”里导入一些歌曲" : "")

      Menu {
        playlistOverflowMenu(for: playlist)
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
  }

  @ViewBuilder
  private func playlistOverflowMenu(for playlist: UserPlaylist) -> some View {
    Button("设置歌单封面…") {
      choosePlaylistArtwork(playlist)
    }
    Button("恢复默认封面") {
      resetPlaylistArtwork(playlist)
    }

    Divider()

    if audioPlayer.currentFile != nil {
      Button("添加正在播放") {
        addCurrentTrack(to: playlist)
      }
    }

    if nowPlayingIDInPlaylist(playlist) != nil {
      Button("定位正在播放") {
        requestScrollToNowPlayingInPlaylist(playlist)
      }
    }

    Divider()

    Button("同步随机权重给队列") {
      syncPlaylistWeightsToQueue(playlist)
    }

    Divider()

    Button("导出 M3U8…") {
      exportPlaylistAsM3U8(playlist)
    }
  }

  private func addCurrentTrack(to playlist: UserPlaylist) {
    guard let url = audioPlayer.currentFile?.url else {
      postToast(title: "没有正在播放的歌曲", subtitle: nil, kind: "info")
      return
    }
    Task {
      _ = await playlistsStore.addTracks([url], to: playlist.id)
      reloadSelectedPlaylist()
    }
  }

  private func syncPlaylistWeightsToQueue(_ playlist: UserPlaylist) {
    let result = weights.syncPlaylistOverridesToQueue(from: playlist.id)
    if case .rejectedReadOnly(let reason) = result.mutationResult {
      postToast(title: "无法同步随机权重", subtitle: reason.diagnosticMessage, kind: "error")
      return
    }
    if result.total == 0 {
      postToast(title: "歌单没有设置随机权重", subtitle: "先在歌曲行的随机权重菜单中设置", kind: "info")
      return
    }
    if result.changed == 0 {
      postToast(title: "队列权重已是最新", subtitle: "无需同步（\(result.total) 条权重一致）", kind: "info")
      return
    }
    postToast(
      title: "已同步权重到队列",
      subtitle: "应用了 \(result.changed)/\(result.total) 条权重",
      kind: "success"
    )
  }

  private static func formatCollectionDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = max(1, Int(duration / 60))
    if totalMinutes >= 60 {
      return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟"
    }
    return "\(totalMinutes) 分钟"
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
          if reduceMotion {
            centerPlaylistRowWithoutAnimation(targetIndex, in: tableView)
          } else {
            centerListRow(targetIndex, in: tableView)
          }
        } else if reduceMotion {
          proxy.scrollTo(targetID, anchor: .center)
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

  @MainActor
  private func centerPlaylistRowWithoutAnimation(_ row: Int, in tableView: NSTableView) {
    guard row >= 0, row < tableView.numberOfRows else { return }

    tableView.scrollRowToVisible(row)
    guard let scrollView = tableView.enclosingScrollView else { return }

    tableView.layoutSubtreeIfNeeded()
    let rowRect = tableView.rect(ofRow: row)
    guard !rowRect.isEmpty else { return }

    let viewportHeight = scrollView.contentView.bounds.height
    let maxOffsetY = max(0, tableView.bounds.height - viewportHeight)
    let desiredOffsetY = min(max(0, rowRect.midY - viewportHeight / 2), maxOffsetY)
    scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: desiredOffsetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
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
  private func choosePlaylistArtwork(_ playlist: UserPlaylist) {
    let panel = NSOpenPanel()
    panel.title = "设置歌单封面"
    panel.message = "选择一张图片作为“\(playlist.name)”的歌单封面"
    panel.prompt = "使用这张图片"
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { @MainActor in
      do {
        try await PlaylistArtworkStore.shared.importArtwork(from: url, for: playlist.id)
        artworkRevisions[playlist.id, default: 0] &+= 1
        postToast(title: "歌单封面已更新", subtitle: playlist.name, kind: "success")
      } catch {
        postToast(
          title: "无法设置歌单封面",
          subtitle: error.localizedDescription,
          kind: "error"
        )
      }
    }
  }

  @MainActor
  private func resetPlaylistArtwork(_ playlist: UserPlaylist) {
    Task { @MainActor in
      do {
        try await PlaylistArtworkStore.shared.removeCustomArtwork(for: playlist.id)
        artworkRevisions[playlist.id, default: 0] &+= 1
        postToast(title: "已恢复默认歌单封面", subtitle: playlist.name, kind: "success")
      } catch {
        postToast(
          title: "无法恢复默认歌单封面",
          subtitle: error.localizedDescription,
          kind: "error"
        )
      }
    }
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
    Task {
      try? await PlaylistArtworkStore.shared.removeCustomArtwork(for: playlist.id)
    }
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

    // Extract signatures from playlist tracks
    var signatures: [String: FileSignature] = [:]
    for track in playlist.tracks {
      if let sig = track.signature {
        signatures[track.path] = sig
      }
    }

    guard let idx = playlistManager.ensureInQueue(playable, focusURL: file.url, signatures: signatures),
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
    playlistDuration = nil
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

      guard !Task.isCancelled else { return }

      // Build unplayable reasons for missing files.
      for (idx, path) in paths.enumerated() {
        guard !Task.isCancelled else { return }
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

      guard !Task.isCancelled else { return }
      let finalTracks = results.compactMap { $0 }
      let finalReasons = reasons
      let knownDurations = finalTracks.compactMap(\.duration).filter { $0.isFinite && $0 > 0 }
      let finalDuration = knownDurations.isEmpty ? nil : knownDurations.reduce(0, +)
      await MainActor.run {
        guard self.selectedPlaylist?.id == playlistID else { return }
        if Task.isCancelled { return }
        self.loadedTracks = finalTracks
        self.trackUnplayableReasons = finalReasons
        self.playlistDuration = finalDuration
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
        focusTarget: .addFromQueue,
        autoFocusOnAppear: true
      )

      if !addFromQueueSearchText.isEmpty {
        HStack {
          Text("找到 \(candidates.count) / \(playlistManager.audioFiles.count) 首歌曲")
            .font(.caption)
            .foregroundStyle(theme.stageSecondaryText)
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
          Task {
            let added = await playlistsStore.addTracks(urls, to: targetID)
            showAddFromQueueSheet = false
            reloadSelectedPlaylist()
            postToast(title: "已添加 \(added) 首", subtitle: nil, kind: "success")
          }
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

  // MARK: - M3U8 Import/Export

  @MainActor
  private func importM3U8Playlist() {
    let panel = NSOpenPanel()
    panel.title = "导入 M3U8 歌单"
    panel.message = "选择要导入的 M3U8 歌单文件"
    panel.prompt = "导入"

    guard let m3u8Type = UTType(filenameExtension: "m3u8", conformingTo: .plainText) else {
      postToast(title: "无法创建 M3U8 文件类型", subtitle: nil, kind: "error")
      return
    }
    panel.allowedContentTypes = [m3u8Type]
    panel.allowsMultipleSelection = false

    panel.begin { response in
      guard response == .OK, let fileURL = panel.url else { return }

      Task.detached {
        do {
          let result = try M3U8ImportService.importPlaylist(from: fileURL)

          // Create sendable snapshot
          let snapshot = (
            name: result.playlistName,
            paths: result.tracks.map(\.path),
            issueCount: result.issues.count
          )

          let createdID = await self.playlistsStore.createPlaylist(name: snapshot.name, tracks: result.tracks)

          await MainActor.run {
            if createdID != nil {
              self.reloadSelectedPlaylist()

              if snapshot.issueCount == 0 {
                self.postToast(
                  title: "已导入歌单",
                  subtitle: "\(snapshot.paths.count) 首歌曲",
                  kind: "success"
                )
              } else if snapshot.paths.isEmpty {
                self.postToast(
                  title: "导入的歌单为空",
                  subtitle: "没有找到有效的歌曲文件",
                  kind: "warning"
                )
              } else {
                self.postToast(
                  title: "已导入歌单（部分跳过）",
                  subtitle: "\(snapshot.paths.count) 首有效，\(snapshot.issueCount) 个问题",
                  kind: "warning"
                )
              }
            } else {
              self.postToast(
                title: "导入未写入",
                subtitle: "歌单可能处于只读保护状态",
                kind: "error"
              )
            }
          }
        } catch let error as M3U8ServiceError {
          await MainActor.run {
            switch error.code {
            case .readFailed:
              self.postToast(
                title: "无法读取 M3U8 文件",
                subtitle: fileURL.lastPathComponent,
                kind: "error"
              )
            case .invalidUTF8:
              self.postToast(
                title: "文件编码无效",
                subtitle: "M3U8 文件必须是 UTF-8 编码",
                kind: "error"
              )
            case .writeFailed:
              break
            }
          }
        } catch {
          await MainActor.run {
            self.postToast(
              title: "导入失败",
              subtitle: error.localizedDescription,
              kind: "error"
            )
          }
        }
      }
    }
  }

  @MainActor
  private func exportPlaylistAsM3U8(_ playlist: UserPlaylist) {
    let panel = NSSavePanel()
    panel.title = "导出 M3U8 歌单"
    panel.message = "选择保存位置"
    panel.nameFieldStringValue = "\(playlist.name).m3u8"

    guard let m3u8Type = UTType(filenameExtension: "m3u8", conformingTo: .plainText) else {
      postToast(title: "无法创建 M3U8 文件类型", subtitle: nil, kind: "error")
      return
    }
    panel.allowedContentTypes = [m3u8Type]
    panel.canCreateDirectories = true

    panel.begin { response in
      guard response == .OK, let fileURL = panel.url else { return }

      // Create sendable snapshot
      let playlistName = playlist.name
      let trackPaths = playlist.tracks.map(\.path)
      let trackCount = playlist.tracks.count

      Task.detached {
        do {
          // Reconstruct playlist in detached context
          let tracks = trackPaths.map { UserPlaylist.Track(path: $0) }
          let temporaryPlaylist = UserPlaylist(name: playlistName, tracks: tracks)

          try M3U8ExportService.exportPlaylist(temporaryPlaylist, to: fileURL)

          await MainActor.run {
            self.postToast(
              title: "已导出歌单",
              subtitle: "\(trackCount) 首歌曲",
              kind: "success"
            )
          }
        } catch {
          await MainActor.run {
            self.postToast(
              title: "导出失败",
              subtitle: fileURL.lastPathComponent,
              kind: "error"
            )
          }
        }
      }
    }
  }
}
