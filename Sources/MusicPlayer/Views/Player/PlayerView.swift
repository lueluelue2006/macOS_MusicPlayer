import SwiftUI

struct PlayerView: View {
  let audioPlayer: AudioPlayer
  let playlistManager: PlaylistManager
  let isActive: Bool
  let isCompactRoot: Bool
  @StateObject private var viewModel: PlayerViewModel
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  init(
    audioPlayer: AudioPlayer,
    playlistManager: PlaylistManager,
    isActive: Bool = true,
    isCompactRoot: Bool = false
  ) {
    self.audioPlayer = audioPlayer
    self.playlistManager = playlistManager
    self.isActive = isActive
    self.isCompactRoot = isCompactRoot
    _viewModel = StateObject(wrappedValue: PlayerViewModel(
      audioPlayer: audioPlayer,
      playlistManager: playlistManager
    ))
  }

  var body: some View {
    if isActive {
      playerContent
    } else {
      Color.clear
    }
  }

  private var playerContent: some View {
    VStack(spacing: 0) {
      EditorialSectionLabel(index: "01", title: "正在播放")
        .padding(.horizontal, isCompactRoot ? 20 : 24)
        .padding(.top, isCompactRoot ? 12 : 20)
        .padding(.bottom, isCompactRoot ? 8 : 12)

      ScrollView {
        VStack(spacing: 0) {
          if viewModel.isAddingFiles {
            AddProgressSection(viewModel: viewModel)
              .padding(.horizontal, 24)
              .padding(.top, 4)
              .padding(.bottom, 16)
          }

          CurrentTrackSection(viewModel: viewModel, isCompact: isCompactRoot)
            .padding(.top, viewModel.isAddingFiles ? 0 : (isCompactRoot ? 4 : 12))

          if let nextUp = viewModel.nextUpFile {
            NextUpSection(file: nextUp)
              .padding(.horizontal, 28)
              .padding(.top, 24)
          }

          if viewModel.hasLyrics {
            Rectangle()
              .fill(theme.paneDivider)
              .frame(height: 1)
              .padding(.horizontal, 28)
              .padding(.top, 24)

            LyricsSection(viewModel: viewModel)
              .padding(.horizontal, 24)
              .padding(.top, 16)
          }

          Color.clear
            .frame(height: 24)
        }
        .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      listeningDock
    }
    .contentShape(Rectangle())
    .onTapGesture {
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
  }

  private var listeningDock: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(theme.paneDivider)
        .frame(height: 1)

      VStack(spacing: 10) {
        PlaybackControlsSection(viewModel: viewModel)

        AudioControlsSection(viewModel: viewModel)

        OutputDeviceSection(viewModel: viewModel)
      }
      .padding(.horizontal, 28)
      .padding(.top, 12)
      .padding(.bottom, 14)
    }
    .background(theme.surface)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("播放控制台")
  }
}
