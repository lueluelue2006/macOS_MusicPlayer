import SwiftUI

struct PlaybackControlsView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @State private var playButtonPressed = false
  @State private var previousButtonPressed = false
  @State private var nextButtonPressed = false
  @State private var previousHovered = false
  @State private var nextHovered = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }
  private var isEphemeralPlayback: Bool { audioPlayer.persistPlaybackState == false }

  var body: some View {
    let playableCount = playlistManager.playbackScopePlayableCount()
    let canChangeTrack = playableCount > 0 && !isEphemeralPlayback

    VStack(spacing: 14) {
      HStack(spacing: 30) {
        Button(action: previousTrack) {
          Image(systemName: "backward.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(previousHovered ? .primary : theme.mutedText)
            .frame(width: 38, height: 38)
            .background(Circle().fill(previousHovered ? theme.mutedSurface : Color.clear))
            .scaleEffect(previousButtonPressed ? 0.94 : 1.0)
            .animation(AppTheme.quickSpring, value: previousButtonPressed)
            .animation(AppTheme.smoothTransition, value: previousHovered)
        }
        .disabled(!canChangeTrack)
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in previousHovered = hovering }
        .onLongPressGesture(
          minimumDuration: 0, maximumDistance: .infinity,
          pressing: { pressing in
            previousButtonPressed = pressing
          }, perform: {})

        Button(action: togglePlayback) {
          ZStack {
            Circle()
              .fill(theme.accent)
              .frame(width: 56, height: 56)
              .shadow(color: theme.subtleShadow, radius: 8, x: 0, y: 4)

            Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 21, weight: .semibold))
              .foregroundStyle(.white)
              .offset(x: audioPlayer.isPlaying ? 0 : 1)
          }
          .scaleEffect(playButtonPressed ? 0.95 : 1.0)
          .animation(AppTheme.quickSpring, value: playButtonPressed)
          .animation(AppTheme.smoothTransition, value: audioPlayer.isPlaying)
        }
        .disabled(audioPlayer.currentFile == nil)
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(
          minimumDuration: 0, maximumDistance: .infinity,
          pressing: { pressing in
            playButtonPressed = pressing
          }, perform: {})

        Button(action: nextTrack) {
          Image(systemName: "forward.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(nextHovered ? .primary : theme.mutedText)
            .frame(width: 38, height: 38)
            .background(Circle().fill(nextHovered ? theme.mutedSurface : Color.clear))
            .scaleEffect(nextButtonPressed ? 0.94 : 1.0)
            .animation(AppTheme.quickSpring, value: nextButtonPressed)
            .animation(AppTheme.smoothTransition, value: nextHovered)
        }
        .disabled(!canChangeTrack)
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in nextHovered = hovering }
        .onLongPressGesture(
          minimumDuration: 0, maximumDistance: .infinity,
          pressing: { pressing in
            nextButtonPressed = pressing
          }, perform: {})
      }

      HStack(spacing: 6) {
        Button(action: { audioPlayer.toggleLoop() }) {
          Label("单曲循环", systemImage: "repeat.1")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              Capsule().fill(audioPlayer.isLooping ? theme.accent.opacity(0.14) : Color.clear)
            )
            .foregroundColor(audioPlayer.isLooping ? theme.accent : theme.mutedText)
            .animation(.easeInOut(duration: 0.2), value: audioPlayer.isLooping)
        }
        .buttonStyle(PlainButtonStyle())

        Button(action: { audioPlayer.toggleShuffle() }) {
          Label("随机播放", systemImage: "shuffle")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              Capsule().fill(audioPlayer.isShuffling ? theme.accent.opacity(0.14) : Color.clear)
            )
            .foregroundColor(audioPlayer.isShuffling ? theme.accent : theme.mutedText)
            .animation(.easeInOut(duration: 0.2), value: audioPlayer.isShuffling)
        }
        .buttonStyle(PlainButtonStyle())

        Button(action: playRandomTrack) {
          Image(systemName: "dice")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.mutedText)
            .frame(width: 28, height: 28)
            .background(Circle().fill(theme.mutedSurface))
        }
        .disabled(playableCount < 2 || isEphemeralPlayback)
        .buttonStyle(PlainButtonStyle())
        .help(isEphemeralPlayback ? "临时播放模式下不可切歌" : "随机播放一首新歌")
      }
    }
    // 自动播放逻辑已由常驻的 PlaybackCoordinator 处理，避免视图销毁时失效或重复触发
  }

  private func togglePlayback() {
    if audioPlayer.isPlaying {
      audioPlayer.pause()
    } else if audioPlayer.currentFile != nil {
      audioPlayer.resume()
    }
  }

  private func nextTrack() {
    guard !isEphemeralPlayback else { return }
    if let nextFile = playlistManager.nextFile(isShuffling: audioPlayer.isShuffling) {
      audioPlayer.play(nextFile)
    }
  }

  private func previousTrack() {
    guard !isEphemeralPlayback else { return }
    if let previousFile = playlistManager.previousFile(isShuffling: audioPlayer.isShuffling) {
      audioPlayer.play(previousFile)
    }
  }

  private func playRandomTrack() {
    guard !isEphemeralPlayback else { return }
    if let randomFile = playlistManager.getRandomFileExcludingCurrent() {
      audioPlayer.play(randomFile)
    }
  }
}

struct AudioControlsView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: volumeIconName)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.mutedText)
          .frame(width: 18)

        Slider(
          value: Binding(
            get: { Double(audioPlayer.volume) },
            set: { audioPlayer.setVolume(Float($0)) }
          ),
          in: 0...1
        )
        .controlSize(.small)
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(audioPlayer.volume * 100))%")

        Text("\(Int(audioPlayer.volume * 100))%")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(theme.mutedText)
          .monospacedDigit()
          .frame(width: 34, alignment: .trailing)
      }

      Divider()
        .background(theme.stroke)

      // 音量均衡开关
      HStack {
        Image(systemName: "waveform.badge.magnifyingglass")
          .font(.system(size: 14))
          .foregroundStyle(
            audioPlayer.isNormalizationEnabled
              ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.mutedText))

        Text("音量均衡")
          .font(.system(size: 14, weight: .medium))

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { audioPlayer.isNormalizationEnabled },
            set: { _ in audioPlayer.toggleNormalization() }
          )
        )
        .toggleStyle(SwitchToggleStyle(tint: theme.accent))
        .labelsHidden()
      }
      .help("自动调整不同歌曲的音量差异")
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(theme.mutedSurface)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.stroke, lineWidth: 1)
        )
    )
  }

  private var volumeIconName: String {
    if audioPlayer.volume == 0 {
      return "speaker.slash.fill"
    } else if audioPlayer.volume < 0.33 {
      return "speaker.wave.1.fill"
    } else if audioPlayer.volume < 0.66 {
      return "speaker.wave.2.fill"
    } else {
      return "speaker.wave.3.fill"
    }
  }
}
