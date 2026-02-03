import SwiftUI

struct RootView: View {
    let audioPlayer: AudioPlayer
    let playlistManager: PlaylistManager
    let playlistsStore: PlaylistsStore
    @Environment(\.colorScheme) private var colorScheme

    /// 0=跟随系统（首次启动默认），1=亮色，2=暗色
    @AppStorage("userColorSchemeOverride") private var userColorSchemeOverride: Int = 0

    private var override: UserColorSchemeOverride {
        UserColorSchemeOverride(rawValue: userColorSchemeOverride) ?? .system
    }

    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        ContentView(audioPlayer: audioPlayer, playlistManager: playlistManager, playlistsStore: playlistsStore)
            .preferredColorScheme(override.preferredColorScheme)
            .tint(theme.accent)
    }
}
