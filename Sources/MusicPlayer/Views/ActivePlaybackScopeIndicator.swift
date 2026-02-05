import SwiftUI

/// A lightweight indicator for the active playback scope.
struct ActivePlaybackScopeIndicator: View {
    let systemName: String
    let isPlaying: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.accentGradient)
            .frame(width: 18, height: 18, alignment: .center)
            .opacity(isPlaying ? 1.0 : 0.72)
            .accessibilityHidden(true)
    }
}
