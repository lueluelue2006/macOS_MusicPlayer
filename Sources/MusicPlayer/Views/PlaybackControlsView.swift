import SwiftUI

struct PlaybackControlsView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }
  private var isEphemeralPlayback: Bool { audioPlayer.persistPlaybackState == false }

  var body: some View {
    let playableCount = playlistManager.playbackScopePlayableCount()
    let canChangeTrack = playableCount > 0 && !isEphemeralPlayback
    let isPlaybackActive = audioPlayer.isPlaybackRequested || audioPlayer.isPlaying
    let canTogglePlayback = audioPlayer.canTogglePlayback

    HStack(spacing: 22) {
      TransportIconToggle(
        systemName: "shuffle",
        accessibilityLabel: "随机播放",
        isOn: Binding(
          get: { audioPlayer.isShuffling },
          set: { audioPlayer.setShuffling($0) }
        ),
        isDisabled: isEphemeralPlayback,
        help: isEphemeralPlayback ? "临时播放模式下不可切歌" : "随机播放"
      )

      TransportIconButton(
        systemName: "backward.fill",
        size: 17,
        isDisabled: !canChangeTrack,
        help: "上一首"
      ) {
        previousTrack()
      }

      Button(action: togglePlayback) {
        ZStack {
          Circle()
            .fill(theme.accent)
            .frame(width: 54, height: 54)

          Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(theme.accentForeground)
            .offset(x: isPlaybackActive ? 0 : 1)
        }
      }
      .buttonStyle(TransportPressButtonStyle())
      .disabled(!canTogglePlayback)
      .opacity(canTogglePlayback ? 1 : 0.42)
      .help(isPlaybackActive ? "暂停" : "播放")
      .accessibilityLabel(isPlaybackActive ? "暂停" : "播放")

      TransportIconButton(
        systemName: "forward.fill",
        size: 17,
        isDisabled: !canChangeTrack,
        help: "下一首"
      ) {
        nextTrack()
      }

      TransportIconToggle(
        systemName: "repeat.1",
        accessibilityLabel: "单曲循环",
        isOn: Binding(
          get: { audioPlayer.isLooping },
          set: { audioPlayer.setLooping($0) }
        ),
        help: "单曲循环"
      )

      TransportIconToggle(
        systemName: "infinity",
        accessibilityLabel: "沉浸播放",
        isOn: Binding(
          get: { audioPlayer.isImmersivePlaybackEnabled },
          set: { audioPlayer.setImmersivePlaybackEnabled($0) }
        ),
        help: "沉浸播放：自动跳过歌曲前后的静音，让下一首更快接上"
      )
    }
    .frame(maxWidth: .infinity)
  }

  private func togglePlayback() {
    audioPlayer.togglePlayPause()
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
}

private struct TransportIconToggle: View {
  let systemName: String
  let accessibilityLabel: String
  @Binding var isOn: Bool
  var size: CGFloat = 15
  var isDisabled: Bool = false
  let help: String

  @State private var isHovered = false
  @FocusState private var isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Toggle(isOn: $isOn) {
      Image(systemName: systemName)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(
          isOn
            ? theme.interactiveAccent
            : (isHovered ? theme.stagePrimaryText : theme.stageSecondaryText)
        )
        .frame(width: 34, height: 34)
        .background {
          Circle()
            .fill(isOn ? theme.interactiveAccent.opacity(0.11) : Color.clear)
        }
        .overlay {
          Circle()
            .stroke(
              isFocused
                ? theme.interactiveAccent
                : (isOn ? theme.interactiveAccent.opacity(0.50) : Color.clear),
              lineWidth: isFocused ? 2 : 1
            )
        }
        .contentShape(Rectangle())
    }
    .toggleStyle(.button)
    .buttonStyle(TransportPressButtonStyle())
    .focused($isFocused)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.28 : 1)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isOn ? "已开启" : "已关闭")
  }
}

private struct TransportIconButton: View {
  let systemName: String
  var size: CGFloat = 15
  var isActive: Bool = false
  var isDisabled: Bool = false
  let help: String
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(
          isActive
            ? theme.accent
            : (isHovered ? theme.stagePrimaryText : theme.stageSecondaryText)
        )
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
    }
    .buttonStyle(TransportPressButtonStyle())
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.28 : 1)
    .onHover { isHovered = $0 }
    .help(help)
  }
}

private struct TransportPressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.62 : 1)
  }
}

struct AudioControlsView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: volumeIconName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.stageSecondaryText)
        .frame(width: 18)

      Slider(
        value: Binding(
          get: { Double(audioPlayer.volume) },
          set: { audioPlayer.setVolume(Float($0)) }
        ),
        in: 0...1
      )
      .controlSize(.small)
      .tint(theme.accent)
      .accessibilityLabel("音量")
      .accessibilityValue("\(Int(audioPlayer.volume * 100))%")

      Text("\(Int(audioPlayer.volume * 100))%")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(theme.stageTertiaryText)
        .monospacedDigit()
        .frame(width: 30, alignment: .trailing)

      Rectangle()
        .fill(theme.stroke)
        .frame(width: 1, height: 20)
        .padding(.horizontal, 3)

      Button {
        audioPlayer.toggleNormalization()
      } label: {
        Image(systemName: "waveform.badge.magnifyingglass")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(
            audioPlayer.isNormalizationEnabled ? theme.accent : theme.stageSecondaryText
          )
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(TransportPressButtonStyle())
      .help(audioPlayer.isNormalizationEnabled ? "音量均衡已开启" : "音量均衡已关闭")
      .accessibilityLabel("音量均衡")
      .accessibilityValue(audioPlayer.isNormalizationEnabled ? "已开启" : "已关闭")
    }
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
