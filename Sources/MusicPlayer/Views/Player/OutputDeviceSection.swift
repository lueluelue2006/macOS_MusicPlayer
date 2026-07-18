import SwiftUI

struct OutputDeviceSection: View {
  @ObservedObject var viewModel: PlayerViewModel
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 6) {
      Image(
        systemName: viewModel.audioPlayer.isInternalSpeakerOutput ? "laptopcomputer" : "hifispeaker.fill"
      )
      .font(.system(size: 10, weight: .medium))

      Text(viewModel.audioPlayer.currentOutputDeviceName)
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .foregroundStyle(theme.stageTertiaryText.opacity(0.82))
  }
}
