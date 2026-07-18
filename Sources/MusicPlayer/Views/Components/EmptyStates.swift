import SwiftUI

struct EmptyPlaylistView: View {
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "music.note.list")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(theme.mutedText.opacity(0.72))

      VStack(spacing: 6) {
        Text("播放列表为空")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.primary)

        Text("点击“添加音乐”，或把文件拖进窗口")
          .font(.system(size: 12))
          .foregroundColor(theme.mutedText)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

struct RestoringPlaylistView: View {
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 18) {
      ProgressView()
        .controlSize(.regular)

      Text("正在恢复播放列表…")
        .font(.headline)
        .foregroundColor(.primary)

      Text("启动时正在读取上次队列，请稍候。")
        .font(.caption)
        .foregroundColor(theme.mutedText)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
