import SwiftUI

/// A lightweight, high-performance "breathing" indicator for the active playback scope.
///
/// - Uses `TimelineView(.animation)` so the animation won't restart due to view refreshes.
/// - Respects Reduce Motion.
struct ActivePlaybackScopeIndicator: View {
    let systemName: String
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        if reduceMotion || !isPlaying {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentGradient)
                .frame(width: 18, height: 18, alignment: .center)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let period: Double = 1.8
                let phase = (t.truncatingRemainder(dividingBy: period)) / period // 0...1
                let wave = (sin(phase * 2 * Double.pi) + 1) / 2 // 0...1

                let scale = 0.92 + 0.12 * wave
                let opacity = 0.72 + 0.28 * wave

                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accentGradient)
                    .frame(width: 18, height: 18, alignment: .center)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .shadow(
                        color: theme.accent.opacity(0.25 * wave),
                        radius: 8 * wave,
                        x: 0,
                        y: 0
                    )
            }
            .accessibilityHidden(true)
        }
    }
}

