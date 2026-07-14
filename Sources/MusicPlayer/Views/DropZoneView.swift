import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onFilesDropped: ([URL]) -> Void
    @State private var isDragOver = false
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.dropZoneFill(isActive: isDragOver))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            theme.dropZoneBorder(isActive: isDragOver),
                            style: StrokeStyle(lineWidth: isDragOver ? 2 : 1, dash: isDragOver ? [] : [6, 5])
                        )
                )

            VStack(spacing: 10) {
                Image(systemName: isDragOver ? "arrow.down.circle.fill" : "music.note.list")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(isDragOver ? theme.accent : theme.stageSecondaryText)

                Text(isDragOver ? "松开以添加" : "将音乐文件拖放到此处")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isDragOver ? theme.accent : theme.stagePrimaryText)

                Text("支持 MP3, WAV, M4A, FLAC 等格式")
                    .font(.system(size: 12))
                    .foregroundColor(theme.mutedText)
            }
        }
        .frame(height: 130)
        .scaleEffect(isDragOver ? 1.02 : 1.0)
        .animation(AppTheme.quickSpring, value: isDragOver)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        Task {
            let urls: [URL] = await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask {
                        await provider.loadFileURL()
                    }
                }
                var results: [URL] = []
                for await url in group {
                    if let url { results.append(url) }
                }
                return results
            }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                onFilesDropped(urls)
            }
        }
    }
}
