import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onFilesDropped: ([URL]) -> Void
    @State private var isDragOver = false
    @State private var pulseScale: CGFloat = 1.0
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        ZStack {
            // 拖拽时的发光效果
            if isDragOver {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.accent.opacity(0.1))
                    .blur(radius: 8)
                    .scaleEffect(pulseScale)
            }

            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(theme.dropZoneFill(isActive: isDragOver))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isDragOver ? theme.glowStroke : theme.dropZoneBorder(isActive: false),
                            style: StrokeStyle(lineWidth: isDragOver ? 2 : 1.5, dash: isDragOver ? [] : [8, 6])
                        )
                )
                .shadow(color: isDragOver ? theme.accentShadow : theme.subtleShadow, radius: isDragOver ? 12 : 6, x: 0, y: 3)

            VStack(spacing: 10) {
                ZStack {
                    if isDragOver {
                        Circle()
                            .fill(theme.accent.opacity(0.15))
                            .frame(width: 60, height: 60)
                            .blur(radius: 6)
                    }

                    Image(systemName: isDragOver ? "arrow.down.circle.fill" : "music.note.list")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(isDragOver ? theme.accentGradient : LinearGradient(colors: [theme.mutedText], startPoint: .top, endPoint: .bottom))
                }

                Text(isDragOver ? "松开以添加" : "将音乐文件拖放到此处")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isDragOver ? theme.accent : .primary)

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
        .onChange(of: isDragOver) { active in
            if active {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseScale = 1.05
                }
            } else {
                pulseScale = 1.0
            }
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
