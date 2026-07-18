import SwiftUI

struct ProgressSliderView: View {
  @ObservedObject var playbackClock: PlaybackClock
  let playbackStart: TimeInterval
  let playbackEnd: TimeInterval
  let onSeek: (TimeInterval) -> Void
  @State private var isEditing = false
  @State private var sliderValue: Double = 0
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 8) {
      Slider(
        value: $sliderValue,
        in: sliderMin...sliderMax,
        onEditingChanged: { editing in
          isEditing = editing
          if !editing {
            onSeek(sliderValue)
          }
        }
      )
      .controlSize(.small)
      .tint(theme.accent)
      .accessibilityLabel("播放进度")
      .accessibilityValue(formatTime(displayedElapsedTime))

      HStack {
        Text(formatTime(displayedElapsedTime))
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundColor(theme.mutedText)
          .monospacedDigit()

        Spacer()

        Text(
          "-"
            + formatTime(
              max(0, sliderMax - displayedAbsoluteTime)
            )
        )
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundColor(theme.mutedText)
        .monospacedDigit()
      }
    }
    .onAppear {
      sliderValue = clamp(playbackClock.currentTime, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackClock.currentTime) { newTime in
      guard !isEditing else { return }
      sliderValue = clamp(newTime, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackClock.duration) { _ in
      sliderValue = clamp(sliderValue, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackStart) { _ in
      sliderValue = clamp(playbackClock.currentTime, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackEnd) { _ in
      sliderValue = clamp(playbackClock.currentTime, min: sliderMin, max: sliderMax)
    }
  }

  private var sliderMin: Double {
    guard playbackStart.isFinite, playbackStart >= 0 else { return 0 }
    return min(playbackStart, max(0, playbackClock.duration))
  }

  private var sliderMax: Double {
    let physicalEnd = max(playbackClock.duration, sliderMin + 0.001)
    guard playbackEnd.isFinite, playbackEnd > sliderMin else { return physicalEnd }
    return min(playbackEnd, physicalEnd)
  }

  private var displayedAbsoluteTime: TimeInterval {
    isEditing ? sliderValue : playbackClock.currentTime
  }

  private var displayedElapsedTime: TimeInterval {
    max(0, displayedAbsoluteTime - sliderMin)
  }

  private func clamp(_ value: Double, min: Double, max: Double) -> Double {
    Swift.max(min, Swift.min(max, value))
  }

  private func formatTime(_ time: TimeInterval) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
