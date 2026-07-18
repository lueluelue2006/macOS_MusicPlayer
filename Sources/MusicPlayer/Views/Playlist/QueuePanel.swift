import SwiftUI

struct QueuePanel: View {
  @ObservedObject var viewModel: PlaylistViewModel
  let onRequestEditMetadata: (AudioFile) -> Void
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SearchBarView(
        searchText: viewModel.queueSearchTextBinding,
        onSearchChanged: { query in
          viewModel.updateQueueSearch(query)
        },
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
      .foregroundColor(.secondary)
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 10)
  }

  private var trackList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(viewModel.displayedQueueFiles.indices, id: \.self) { index in
            let file = viewModel.displayedQueueFiles[index]
            TrackRowView(
              trackNumber: index + 1,
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
        viewModel.performQueueScrollSequence(targetID: target, proxy: proxy)
      }
      .onChange(of: viewModel.queueVisibleRevision) { _ in
        guard let target = viewModel.queueScrollTargetID else { return }
        viewModel.performQueueScrollSequence(targetID: target, proxy: proxy)
      }
      .onChange(of: viewModel.playlistManager.searchText) { _ in
        guard let target = viewModel.queueScrollTargetID else { return }
        viewModel.performQueueScrollSequence(targetID: target, proxy: proxy)
      }
      .onAppear {
        guard let target = viewModel.queueScrollTargetID else { return }
        viewModel.performQueueScrollSequence(targetID: target, proxy: proxy)
      }
    }
  }
}
