import SwiftUI

struct QueuePanel: View {
  @ObservedObject var viewModel: PlaylistViewModel
  let onRequestEditMetadata: (AudioFile) -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SearchBarView(
        searchText: viewModel.queueSearchTextBinding,
        focusTarget: .queue
      )
      .padding(.horizontal, 24)
      .padding(.bottom, 14)

      VStack(alignment: .leading, spacing: 0) {
        if !viewModel.playlistManager.searchText.isEmpty {
          searchStats
        }

        if viewModel.playlistManager.isInitialRestorePending || viewModel.playlistManager.isRestoringPlaylist {
          RestoringPlaylistView()
        } else if viewModel.displayedQueueFiles.isEmpty {
          EmptyPlaylistView()
        } else {
          TrackListColumnHeader()
            .padding(.horizontal, 12)

          trackList
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        NotificationCenter.default.post(name: .blurSearchField, object: nil)
      }
    }
  }

  private var searchStats: some View {
    HStack {
      Text(
        "找到 \(viewModel.playlistManager.filteredFiles.count) / \(viewModel.playlistManager.audioFiles.count) 首歌曲"
      )
      .font(.caption)
      .foregroundStyle(theme.stageSecondaryText)
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 10)
  }

  private var trackList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(viewModel.displayedQueueFiles.numberedTracks) { numberedTrack in
            let file = numberedTrack.file
            TrackRowView(
              trackNumber: numberedTrack.number,
              file: file,
              isCurrentTrack: viewModel.currentHighlightedURL == file.url,
              isVolumeAnalyzed: viewModel.audioPlayer.hasVolumeNormalizationCache(for: file.url),
              unplayableReason: viewModel.playlistManager.unplayableReason(for: file.url),
              searchText: viewModel.playlistManager.searchText,
              playAction: { viewModel.playQueueTrack($0) },
              deleteAction: { viewModel.removeQueueTrack($0) },
              editAction: { onRequestEditMetadata($0) },
              weightLevel: viewModel.weightLevel(for: file),
              onWeightSelect: { viewModel.setQueueWeightLevel($0, for: file) },
              weightScopeLabel: "队列"
            )
            .id(file.id)
          }
        }
        .padding(.horizontal, 12)
      }
      .background(Color.clear)
      .onChange(of: viewModel.queueScrollTargetID) { target in
        guard let target else { return }
        performQueueScroll(targetID: target, proxy: proxy)
      }
      .onChange(of: viewModel.queueVisibleRevision) { _ in
        guard let target = viewModel.queueScrollTargetID else { return }
        performQueueScroll(targetID: target, proxy: proxy)
      }
      .onChange(of: viewModel.playlistManager.searchText) { _ in
        guard let target = viewModel.queueScrollTargetID else { return }
        performQueueScroll(targetID: target, proxy: proxy)
      }
      .onAppear {
        guard let target = viewModel.queueScrollTargetID else { return }
        performQueueScroll(targetID: target, proxy: proxy)
      }
    }
  }

  private func performQueueScroll(targetID: String, proxy: ScrollViewProxy) {
    guard reduceMotion else {
      viewModel.performQueueScrollSequence(targetID: targetID, proxy: proxy)
      return
    }

    guard viewModel.displayedQueueFiles.contains(where: { $0.id == targetID }) else { return }
    proxy.scrollTo(targetID, anchor: .center)
    if viewModel.queueScrollTargetID == targetID {
      viewModel.queueScrollTargetID = nil
    }
  }
}
