import SwiftUI

struct CurrentTrackSection: View {
  @ObservedObject var viewModel: PlayerViewModel
  var isCompact: Bool = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Group {
      if let currentFile = viewModel.currentFile {
        if isCompact {
          compactTrack(currentFile)
        } else {
          regularTrack(currentFile)
        }
      } else if isCompact {
        compactEmptyState
      } else {
        regularEmptyState
      }
    }
    .frame(maxWidth: isCompact ? .infinity : 334)
    .padding(.horizontal, isCompact ? 20 : 24)
    .frame(maxWidth: .infinity)
  }

  private func regularTrack(_ currentFile: AudioFile) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        RecordSleeveHero(
          image: viewModel.audioPlayer.artworkImage,
          title: currentFile.metadata.title,
          artist: currentFile.metadata.artist
        )
          .frame(width: 314, height: 310)
          .frame(maxWidth: .infinity)

        if viewModel.persistPlaybackState == false {
          ephemeralPlaybackHint(compact: false)
        }

        trackMetadata(currentFile, compact: false)
        .padding(.top, 26)

        progressSlider
        .padding(.top, 18)

        secondaryControls
        .padding(.top, 10)
    }
  }

  private func compactTrack(_ currentFile: AudioFile) -> some View {
    HStack(alignment: .top, spacing: 16) {
      RecordSleeveHero(
        image: viewModel.audioPlayer.artworkImage,
        title: currentFile.metadata.title,
        artist: currentFile.metadata.artist
      )
      .frame(width: 138, height: 136)
      .layoutPriority(1)

      VStack(alignment: .leading, spacing: 0) {
        if viewModel.persistPlaybackState == false {
          ephemeralPlaybackHint(compact: true)
        }

        trackMetadata(currentFile, compact: true)

        progressSlider
          .padding(.top, 8)

        secondaryControls
          .padding(.top, 6)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func trackMetadata(_ currentFile: AudioFile, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: compact ? 2 : 5) {
      Text(currentFile.metadata.title)
        .font(AppTheme.musicDisplayFont(size: compact ? 21 : 28, weight: .semibold))
        .lineLimit(compact ? 1 : 2)
        .multilineTextAlignment(.leading)
        .foregroundColor(theme.stagePrimaryText)

      Text(currentFile.metadata.artist)
        .font(.system(size: compact ? 13 : 15, weight: .medium))
        .foregroundColor(theme.stageSecondaryText)
        .lineLimit(1)

      Text(collectionSubtitle(for: currentFile))
        .font(.system(size: compact ? 10 : 12))
        .foregroundColor(theme.stageTertiaryText)
        .lineLimit(1)
    }
  }

  private var progressSlider: some View {
    ProgressSliderView(
      playbackClock: viewModel.audioPlayer.playbackClock,
      playbackStart: viewModel.audioPlayer.effectivePlaybackStartTime,
      playbackEnd: viewModel.audioPlayer.effectivePlaybackEndTime,
      onSeek: { viewModel.seek(to: $0) }
    )
  }

  private var secondaryControls: some View {
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

      Spacer(minLength: 0)
    }
    .foregroundStyle(theme.stageTertiaryText)
  }

  private func collectionSubtitle(for currentFile: AudioFile) -> String {
    [currentFile.metadata.album, currentFile.metadata.year]
      .compactMap { value -> String? in
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
      }
      .joined(separator: " · ")
  }

  private func ephemeralPlaybackHint(compact: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "bolt.fill")
        .font(.caption)
      Text("临时播放")
        .font(.caption)
        .fontWeight(.semibold)
      if !compact {
        Text("关闭窗口后不会保存进度")
          .font(.caption)
          .foregroundStyle(theme.stageSecondaryText)
      }
    }
    .foregroundColor(Color.orange.opacity(0.92))
    .padding(.bottom, compact ? 4 : 0)
    .padding(.top, compact ? 0 : 16)
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

  private var regularEmptyState: some View {
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

  private var compactEmptyState: some View {
    HStack(spacing: 16) {
      RecordSleeveHero(image: nil, title: "MusicPlayer", artist: "本地音乐")
        .frame(width: 138, height: 136)

      VStack(alignment: .leading, spacing: 5) {
        Text("等待播放")
          .font(AppTheme.musicDisplayFont(size: 22, weight: .semibold))
          .foregroundColor(theme.stagePrimaryText)

        Text("添加音乐，开始你的本地唱片架")
          .font(.system(size: 13))
          .foregroundColor(theme.stageSecondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
  }
}
