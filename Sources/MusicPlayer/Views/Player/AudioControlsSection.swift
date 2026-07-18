import SwiftUI

struct AudioControlsSection: View {
  @ObservedObject var viewModel: PlayerViewModel
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
          get: { Double(viewModel.audioPlayer.volume) },
          set: { viewModel.audioPlayer.setVolume(Float($0)) }
        ),
        in: 0...1
      )
      .controlSize(.small)
      .tint(theme.accent)
      .accessibilityLabel("音量")
      .accessibilityValue("\(Int(viewModel.audioPlayer.volume * 100))%")

      Text("\(Int(viewModel.audioPlayer.volume * 100))%")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(theme.stageTertiaryText)
        .monospacedDigit()
        .frame(width: 30, alignment: .trailing)

      Rectangle()
        .fill(theme.stroke)
        .frame(width: 1, height: 20)
        .padding(.horizontal, 3)

      Button {
        viewModel.audioPlayer.toggleNormalization()
      } label: {
        Image(systemName: "waveform.badge.magnifyingglass")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(
            viewModel.audioPlayer.isNormalizationEnabled ? theme.accent : theme.stageSecondaryText
          )
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(TransportPressButtonStyle())
      .help(viewModel.audioPlayer.isNormalizationEnabled ? "音量均衡已开启" : "音量均衡已关闭")
      .accessibilityLabel("音量均衡")
      .accessibilityValue(viewModel.audioPlayer.isNormalizationEnabled ? "已开启" : "已关闭")
    }
  }

  private var volumeIconName: String {
    if viewModel.audioPlayer.volume == 0 {
      return "speaker.slash.fill"
    } else if viewModel.audioPlayer.volume < 0.33 {
      return "speaker.wave.1.fill"
    } else if viewModel.audioPlayer.volume < 0.66 {
      return "speaker.wave.2.fill"
    } else {
      return "speaker.wave.3.fill"
    }
  }
}
