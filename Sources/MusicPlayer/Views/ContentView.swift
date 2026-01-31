import SwiftUI

struct ContentView: View {
    // Inject shared instances from MusicPlayerApp to avoid duplicate players after window reopen
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @Environment(\.colorScheme) private var colorScheme

    // 缓存清理提示
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showVolumeNormalizationAnalysis = false
    // 播放失败提示（非阻塞）
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false
    @State private var toastTask: Task<Void, Never>?

    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 800 {
                // 小屏幕：垂直布局
                VStack(spacing: 0) {
                    // 上方播放器面板
                    PlayerView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                        .frame(height: max(200, geometry.size.height * 0.4))
                        .background(.ultraThinMaterial)
                        .background(theme.panelBackground.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(theme.stroke, lineWidth: 0.5)
                        )
                        .shadow(color: theme.subtleShadow, radius: 16, x: 0, y: 8)

                    // 下方播放列表
                    PlaylistView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                        .frame(minHeight: 200)
                        .background(.ultraThinMaterial)
                        .background(theme.surface.opacity(0.3))
                }
            } else {
                // 大屏幕：水平布局
                HStack(spacing: 20) {
                    // 左侧播放器面板
                    PlayerView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                        .frame(width: 440)
                        .background(.ultraThinMaterial)
                        .background(theme.panelBackground.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(theme.stroke, lineWidth: 0.5)
                        )
                        .shadow(color: theme.subtleShadow, radius: 16, x: 0, y: 8)

                    // 右侧播放列表
                    PlaylistView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                        .frame(minWidth: 400)
                        .background(.ultraThinMaterial)
                        .background(theme.surface.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(theme.stroke, lineWidth: 0.5)
                        )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(theme.backgroundGradient)
        .onAppear {
            // 启动时确保搜索框不自动聚焦
            NotificationCenter.default.post(name: .blurSearchField, object: nil)
            // 一次性恢复逻辑移动到持久化的 PlaylistManager（避免窗口重开导致重复）
            playlistManager.performInitialRestoreIfNeeded(audioPlayer: audioPlayer)
        }
        .onDisappear {
            // 应用关闭时保存播放列表（不会影响后台播放）
            playlistManager.savePlaylist()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleGlobalDrop(providers: providers)
            return true
        }
        .sheet(isPresented: $showVolumeNormalizationAnalysis) {
            VolumeNormalizationAnalysisView(audioPlayer: audioPlayer, playlistManager: playlistManager)
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        }
        .overlay(alignment: .top) {
            if showToast {
                Text(toastMessage)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.elevatedSurface.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.accent.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .shadow(color: theme.subtleShadow, radius: 10, x: 0, y: 4)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 扬声器播放确认弹窗（仅在“耳机→扬声器”后，用户显式点击开始时出现一次）
        .alert("通过扬声器播放？", isPresented: Binding(
            get: { audioPlayer.showSpeakerConfirm },
            set: { audioPlayer.showSpeakerConfirm = $0 }
        )) {
            Button("取消", role: .cancel) {
                audioPlayer.speakerConfirmProceed = nil
            }
            Button("继续播放") {
                let proceed = audioPlayer.speakerConfirmProceed
                audioPlayer.speakerConfirmProceed = nil
                audioPlayer.showSpeakerConfirm = false
                proceed?()
            }
        } message: {
            Text("当前输出设备：\(audioPlayer.currentOutputDeviceName)\n为了避免误外放，请确认是否通过扬声器播放。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .loadLastPlayedFile)) { notification in
            if let userInfo = notification.userInfo,
               let url = userInfo["url"] as? URL,
               let time = userInfo["time"] as? TimeInterval {
                if let file = playlistManager.audioFiles.first(where: { $0.url == url }),
                   let index = playlistManager.audioFiles.firstIndex(where: { $0.url == url }) {
                    playlistManager.currentIndex = index
                    playlistManager.savePlaylist()
                    // 恢复到上次曲目与进度，但默认不自动播放
                    audioPlayer.play(file, autostart: false, bypassConfirm: true)
                    audioPlayer.seek(to: time)
                } else {
                    showToastMessage("未能在播放列表中找到上次播放文件")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showVolumeCacheClearedAlert)) { _ in
            alertMessage = "音量均衡缓存已清空"
            showAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showArtworkCacheClearedAlert)) { _ in
            alertMessage = "封面缓存已清空"
            showAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showLyricsCacheClearedAlert)) { _ in
            alertMessage = "歌词缓存已清空"
            showAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAllCachesClearedAlert)) { _ in
            alertMessage = "所有缓存已清空"
            showAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showVolumeNormalizationAnalysis)) { _ in
            showVolumeNormalizationAnalysis = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioPlayerDidFailToPlay)) { notification in
            let raw = (notification.userInfo?["message"] as? String) ?? "播放失败"
            let firstLine = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
            showToastMessage(firstLine)
        }
    }
    
    private func handleGlobalDrop(providers: [NSItemProvider]) {
        Task {
            let urls: [URL] = await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask {
                        await provider.loadFileURL()
                    }
                }
                var results: [URL] = []
                for await url in group {
                    if let url {
                        results.append(url)
                    }
                }
                return results
            }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                playlistManager.enqueueAddFiles(urls)
            }
        }
    }

    @MainActor
    private func showToastMessage(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) {
            showToast = true
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToast = false
                }
            }
        }
    }
}
