import SwiftUI
import Foundation

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

    // 更新检查（自动：启动后，在播放列表成功加载完歌曲后执行一次；延迟执行避免与加载/恢复抢占资源）
    @Environment(\.openURL) private var openURL
    @State private var didAutoCheckForUpdatesThisLaunch: Bool = false
    @State private var updateCheckTask: Task<Void, Never>?
    @State private var toastTapURL: URL?

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
            maybeAutoCheckForUpdates()
        }
        .onDisappear {
            // 应用关闭时保存播放列表（不会影响后台播放）
            playlistManager.savePlaylist()
            updateCheckTask?.cancel()
            updateCheckTask = nil
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
        .overlay(alignment: .topTrailing) {
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
                    .padding(.trailing, 12)
                    .onTapGesture {
                        if let url = toastTapURL {
                            openURL(url)
                        }
                    }
                    .help(toastTapURL == nil ? "" : "点击打开 GitHub Releases")
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
        .onChange(of: playlistManager.audioFiles.count) { _ in
            maybeAutoCheckForUpdates()
        }
        .onChange(of: playlistManager.isAddingFiles) { _ in
            maybeAutoCheckForUpdates()
        }
        .onChange(of: playlistManager.isRestoringPlaylist) { _ in
            maybeAutoCheckForUpdates()
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
            alertMessage = "封面缩略图已清空"
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

    private func maybeAutoCheckForUpdates() {
        let ready =
            !playlistManager.audioFiles.isEmpty &&
            !playlistManager.isAddingFiles &&
            !playlistManager.isRestoringPlaylist

        // 若用户正在导入/恢复或播放列表为空：取消任何“待执行”的更新检查，避免与加载抢占资源
        guard ready else {
            updateCheckTask?.cancel()
            updateCheckTask = nil
            return
        }

        guard !didAutoCheckForUpdatesThisLaunch else { return }

        // 已经排队等待执行，则不重复创建任务
        guard updateCheckTask == nil else { return }

        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "3.1"
        updateCheckTask = Task(priority: .background) {
            // 延迟一点：让加载/恢复后的 UI 与磁盘/元数据任务先跑一会儿
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }

            let outcome = await UpdateChecker.shared.check(currentVersion: currentVersion)
            if Task.isCancelled { return }
            await MainActor.run {
                didAutoCheckForUpdatesThisLaunch = true
                updateCheckTask = nil
                switch outcome {
                case .updateAvailable(let info):
                    showToastMessage("发现新版本 \(info.latestVersion) · 点击打开下载页", duration: 3.0, tapURL: info.releaseURL)
                case .upToDate(let current, let latest, let url):
                    if latest == current {
                        showToastMessage("已是最新版本 \(current)", duration: 2.0, tapURL: url)
                    } else {
                        showToastMessage("已是最新版本 \(current)（线上 \(latest)）", duration: 2.0, tapURL: url)
                    }
                case .failed(let message, let url):
                    showToastMessage(message, duration: 2.0, tapURL: url)
                }
            }
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
    private func showToastMessage(_ message: String, duration: TimeInterval = 2.8, tapURL: URL? = nil) {
        toastTask?.cancel()
        toastMessage = message
        toastTapURL = tapURL
        withAnimation(.easeInOut(duration: 0.2)) {
            showToast = true
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToast = false
                }
            }
        }
    }
}
