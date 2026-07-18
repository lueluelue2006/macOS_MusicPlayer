import SwiftUI

struct PlayerView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @StateObject private var viewModel: PlayerViewModel
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager) {
    self.audioPlayer = audioPlayer
    self.playlistManager = playlistManager
    _viewModel = StateObject(wrappedValue: PlayerViewModel(
      audioPlayer: audioPlayer,
      playlistManager: playlistManager
    ))
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if viewModel.isAddingFiles {
          AddProgressSection(viewModel: viewModel)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }

        CurrentTrackSection(viewModel: viewModel)
          .padding(.top, viewModel.isAddingFiles ? 0 : 28)

        PlaybackControlsSection(viewModel: viewModel)
          .padding(.horizontal, 28)
          .padding(.top, 22)

        AudioControlsSection(viewModel: viewModel)
          .padding(.horizontal, 28)
          .padding(.top, 14)

        if let nextUp = viewModel.nextUpFile {
          NextUpSection(file: nextUp)
            .padding(.horizontal, 28)
            .padding(.top, 22)
        }

        if viewModel.hasLyrics {
          Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
            .padding(.horizontal, 28)
            .padding(.top, 22)

          LyricsSection(viewModel: viewModel)
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }

        OutputDeviceSection(viewModel: viewModel)
          .padding(.horizontal, 28)
          .padding(.top, 20)
          .padding(.bottom, 24)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      NotificationCenter.default.post(name: .blurSearchField, object: nil)
    }
  }
}
