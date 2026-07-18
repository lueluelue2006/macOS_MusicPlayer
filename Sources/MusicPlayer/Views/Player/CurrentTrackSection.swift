import SwiftUI

struct CurrentTrackSection: View {
  @ObservedObject var viewModel: PlayerViewModel
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let currentFile = viewModel.currentFile {
        RecordSleeveHero(
          image: viewModel.audioPlayer.artworkImage,
          title: currentFile.metadata.title,
          artist: currentFile.metadata.artist
        )
          .frame(width: 314, height: 310)
          .frame(maxWidth: .infinity)

        if viewModel.persistPlaybackState == false {
          ephemeralPlaybackHint
        }

        VStack(alignment: .leading, spacing: 5) {
          Text(currentFile.metadata.title)
            .font(AppTheme.musicDisplayFont(size: 28, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .foregroundColor(theme.stagePrimaryText)

          Text(currentFile.metadata.artist)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(theme.stageSecondaryText)
            .lineLimit(1)

          Text(
            [currentFile.metadata.album, currentFile.metadata.year]
              .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
              }
              .joined(separator: " · ")
          )
            .font(.system(size: 12))
            .foregroundColor(theme.stageTertiaryText)
            .lineLimit(1)
        }
        .padding(.top, 26)

        ProgressSliderView(
          playbackClock: viewModel.audioPlayer.playbackClock,
          playbackStart: viewModel.audioPlayer.effectivePlaybackStartTime,
          playbackEnd: viewModel.audioPlayer.effectivePlaybackEndTime,
          onSeek: { viewModel.seek(to: $0) }
        )
        .padding(.top, 18)

        HStack(spacing: 10) {
          playbackRateMenu

          WeightBlocksView(
            level: viewModel.weightLevel(),
            scopeLabel: viewModel.weightScopeLabel()
          ) { newLevel in
            viewModel.setWeightLevel(newLevel)
          }
          .fixedSize(horizontal: true, vertical: true)
          .layoutPriority(3)

          Button {
            viewModel.playRandomTrack()
          } label: {
            Image(systemName: "die.face.5")
              .font(.system(size: 12, weight: .medium))
              .frame(width: 22, height: 22)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(
            viewModel.playlistManager.playbackScopePlayableCount() < 2
              || viewModel.persistPlaybackState == false
          )
          .help(viewModel.persistPlaybackState == false ? "临时播放模式下不可切歌" : "随机选一首")

          Spacer()
        }
        .foregroundStyle(theme.stageTertiaryText)
        .padding(.top, 10)

      } else {
        emptyState
      }
    }
    .frame(maxWidth: 334)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
  }

  private var ephemeralPlaybackHint: some View {
    HStack(spacing: 8) {
      Image(systemName: "bolt.fill")
        .font(.caption)
      Text("临时播放")
        .font(.caption)
        .fontWeight(.semibold)
      Text("关闭窗口后不会保存进度")
        .font(.caption)
        .foregroundStyle(theme.stageSecondaryText)
    }
    .foregroundColor(Color.orange.opacity(0.92))
    .padding(.top, 16)
    .help("通过 Finder/Dock 打开的临时播放：关闭应用或再次以临时方式打开其他歌曲都会丢失当前进度")
  }

  private var playbackRateMenu: some View {
    Menu {
      let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
      ForEach(rates, id: \.self) { rate in
        Button {
          viewModel.setPlaybackRate(rate)
        } label: {
          if abs(viewModel.audioPlayer.playbackRate - rate) < 0.001 {
            Label(String(format: "%.2f×", rate), systemImage: "checkmark")
          } else {
            Text(String(format: "%.2f×", rate))
          }
        }
      }
      Divider()
      Button("重置为 1.00×") { viewModel.setPlaybackRate(1.0) }
    } label: {
      Label(String(format: "%.2f×", viewModel.audioPlayer.playbackRate), systemImage: "speedometer")
        .font(.system(size: 11, weight: .medium))
    }
    .buttonStyle(.plain)
    .help("播放速度")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 18) {
      RecordSleeveHero(image: nil, title: "MusicPlayer", artist: "本地音乐")
        .frame(width: 314, height: 310)

      VStack(alignment: .leading, spacing: 6) {
        Text("等待播放")
          .font(AppTheme.musicDisplayFont(size: 28, weight: .semibold))
          .foregroundColor(theme.stagePrimaryText)

        Text("添加音乐，开始你的本地唱片架")
          .font(.system(size: 14))
          .foregroundColor(theme.stageSecondaryText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }
}
