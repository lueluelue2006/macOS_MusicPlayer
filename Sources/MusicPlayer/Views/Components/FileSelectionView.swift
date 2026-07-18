import AppKit
import SwiftUI

struct FileSelectionView: View {
  let isLibraryEmpty: Bool
  let onFilesSelected: ([URL]) -> Void
  @State private var hovering = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Button(action: selectFiles) {
      HStack(spacing: 7) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 12, weight: .semibold))
        Text(isLibraryEmpty ? "添加音乐" : "导入")
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(theme.accentForeground)
      .padding(.vertical, 7)
      .padding(.horizontal, 11)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(hovering ? theme.accent.opacity(0.86) : theme.accent)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .animation(AppTheme.smoothTransition, value: hovering)
    }
    .buttonStyle(PlainButtonStyle())
    .accessibilityLabel("添加音乐文件或文件夹")
    .onHover { isHovering in
      hovering = isHovering
    }
  }

  private func selectFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = true

    if panel.runModal() == .OK {
      onFilesSelected(panel.urls)
    }
  }
}
