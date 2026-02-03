import SwiftUI

/// A lightweight, high-performance "breathing" indicator for the active playback scope.
///
/// - Uses CoreAnimation-backed SwiftUI animation (doesn't require per-frame recomputation).
/// - Respects Reduce Motion.
struct ActivePlaybackScopeIndicator: View {
    let systemName: String
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    @State private var breathe: Bool = false

    var body: some View {
        if reduceMotion || !isPlaying {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentGradient)
                .frame(width: 18, height: 18, alignment: .center)
        } else {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentGradient)
                .frame(width: 18, height: 18, alignment: .center)
                .scaleEffect(breathe ? 1.05 : 0.95)
                .opacity(breathe ? 1.0 : 0.78)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathe)
                .onAppear { breathe = true }
                .accessibilityHidden(true)
        }
    }
}
