import SwiftUI
import Foundation

struct ContentView: View {
    // Inject shared instances from MusicPlayerApp to avoid duplicate players after window reopen
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var playlistsStore: PlaylistsStore
    @Environment(\.colorScheme) private var colorScheme

    // 缓存清理提示
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showVolumeNormalizationAnalysis = false
    // 播放失败提示（非阻塞）
    @State private var toastTitle: String = ""
    @State private var toastSubtitle: String? = nil
    @State private var toastKind: ToastKind = .info
    @State private var showToast: Bool = false
    @State private var toastTask: Task<Void, Never>?

    // 更新检查（自动：启动后，在播放列表成功加载完歌曲后执行一次；延迟执行避免与加载/恢复抢占资源）
    @Environment(\.openURL) private var openURL
    @State private var didAutoCheckForUpdatesThisLaunch: Bool = false
    @State private var updateCheckTask: Task<Void, Never>?
    @State private var toastTapURL: URL?
    @State private var toastTapUpdate: UpdateChecker.UpdateInfo?

    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    private var layoutView: some View {
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
                    PlaylistView(audioPlayer: audioPlayer, playlistManager: playlistManager, playlistsStore: playlistsStore)
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
                    PlaylistView(audioPlayer: audioPlayer, playlistManager: playlistManager, playlistsStore: playlistsStore)
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
    }

    var body: some View {
        let base = AnyView(layoutView)

        let withChrome = base
            .background(theme.backgroundGradient)
            .onAppear {
                // 启动时确保搜索框不自动聚焦
                NotificationCenter.default.post(name: .blurSearchField, object: nil)
                // 一次性恢复逻辑移动到持久化的 PlaylistManager（避免窗口重开导致重复）
                playlistManager.performInitialRestoreIfNeeded(audioPlayer: audioPlayer, playlistsStore: playlistsStore)
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
                    ToastBanner(
                        title: toastTitle,
                        subtitle: toastSubtitle,
                        kind: toastKind,
                        onTap: (toastTapURL == nil && toastTapUpdate == nil) ? nil : {
                            if let info = toastTapUpdate {
                                Task { await startSelfUpdate(info) }
                            } else if let url = toastTapURL {
                                openURL(url)
                            }
                        },
                        onClose: { dismissToast() }
                    )
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

        // 扬声器播放确认弹窗（仅在“耳机→扬声器”后，用户显式点击开始时出现一次）
        let withSpeakerConfirm = withChrome.alert("通过扬声器播放？", isPresented: Binding(
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

        let withUpdateTriggers = withSpeakerConfirm
            .onChange(of: playlistManager.audioFiles.count) { _ in
                maybeAutoCheckForUpdates()
            }
            .onChange(of: playlistManager.isAddingFiles) { _ in
                maybeAutoCheckForUpdates()
            }
            .onChange(of: playlistManager.isRestoringPlaylist) { _ in
                maybeAutoCheckForUpdates()
            }

        let withReceivers = withUpdateTriggers
            .onReceive(NotificationCenter.default.publisher(for: .loadLastPlayedFile)) { notification in
                if let userInfo = notification.userInfo,
                   let url = userInfo["url"] as? URL,
                   let time = userInfo["time"] as? TimeInterval {
                    if let file = playlistManager.audioFiles.first(where: { $0.url == url }),
                       let index = playlistManager.audioFiles.firstIndex(where: { $0.url == url }) {
                        playlistManager.currentIndex = index
                        playlistManager.savePlaylist()
                        // 恢复到上次曲目与进度，但默认不自动播放
                        audioPlayer.prepareInitialSeekForRestore(to: time)
                        audioPlayer.play(file, autostart: false, bypassConfirm: true)
                    } else {
                        showToastMessage("未能在播放列表中找到上次播放文件", kind: .warning)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showVolumeCacheClearedAlert)) { _ in
                alertMessage = "音量均衡缓存已清空"
                showAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showDurationCacheClearedAlert)) { _ in
                alertMessage = "时长缓存已清空"
                showAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showArtworkCacheClearedAlert)) { _ in
                alertMessage = "封面缩略图（内存）已清空"
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
            .onReceive(NotificationCenter.default.publisher(for: .requestDismissAllSheets)) { _ in
                showVolumeNormalizationAnalysis = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioPlayerDidFailToPlay)) { notification in
                let raw = (notification.userInfo?["message"] as? String) ?? "播放失败"
                let firstLine =
                    raw
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? raw
                showToastMessage(firstLine, kind: .error)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAppToast)) { notification in
                guard let userInfo = notification.userInfo else { return }

                let title = (userInfo["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let subtitle = (userInfo["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let duration = (userInfo["duration"] as? TimeInterval) ?? 2.8
                let tapURL =
                    (userInfo["url"] as? URL)
                    ?? ((userInfo["url"] as? String).flatMap { URL(string: $0) })
                let kindRaw = (userInfo["kind"] as? String) ?? "info"
                let kind = ToastKind(rawValue: kindRaw) ?? .info

                guard !title.isEmpty else { return }
                showToastMessage(title, subtitle: subtitle, kind: kind, duration: duration, tapURL: tapURL)
            }

        return withReceivers
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

        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "3.6.2"
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
                    if info.assetURL != nil {
                        showToastMessage(
                            "发现新版本 \(info.latestVersion)",
                            subtitle: "点击自动更新（下载并安装后自动重启）",
                            kind: .update,
                            duration: 10.0,
                            tapUpdate: info
                        )
                    } else {
                        showToastMessage(
                            "发现新版本 \(info.latestVersion)",
                            subtitle: "点击打开 GitHub Releases 下载",
                            kind: .update,
                            duration: 10.0,
                            tapURL: info.releaseURL
                        )
                    }
                case .upToDate(let current, let latest, let url):
                    if latest == current {
                        showToastMessage("已是最新版本 \(current)", kind: .success, duration: 2.0, tapURL: url)
                    } else {
                        showToastMessage("已是最新版本 \(current)", subtitle: "线上最新：\(latest)", kind: .success, duration: 2.0, tapURL: url)
                    }
                case .failed(let message, let url):
                    showToastMessage(message, subtitle: "点击打开 GitHub Releases", kind: .warning, duration: 2.0, tapURL: url)
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
    private func showToastMessage(
        _ message: String,
        subtitle: String? = nil,
        kind: ToastKind = .info,
        duration: TimeInterval = 2.8,
        tapURL: URL? = nil,
        tapUpdate: UpdateChecker.UpdateInfo? = nil
    ) {
        toastTask?.cancel()
        toastTitle = message
        toastSubtitle = subtitle
        toastKind = kind
        toastTapURL = tapURL
        toastTapUpdate = tapUpdate
        withAnimation(.easeInOut(duration: 0.2)) {
            showToast = true
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            await MainActor.run {
                dismissToast()
            }
        }
    }

    @MainActor
    private func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toastTapURL = nil
        toastTapUpdate = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            showToast = false
        }
    }

    @MainActor
    private func startSelfUpdate(_ info: UpdateChecker.UpdateInfo) async {
        showToastMessage(
            "正在下载并安装 \(info.latestVersion)…",
            subtitle: "将自动覆盖安装到 /Applications 并重启",
            kind: .update,
            duration: 60.0
        )
        do {
            try await SelfUpdater.shared.startUpdateIfPossible(info: info)
        } catch {
            showToastMessage(
                "自动更新失败",
                subtitle: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                kind: .error,
                duration: 4.0,
                tapURL: info.releaseURL
            )
        }
    }
}

private enum ToastKind: String, Sendable {
    case info
    case success
    case warning
    case error
    case update
}

private struct ToastBanner: View {
    let title: String
    let subtitle: String?
    let kind: ToastKind
    let onTap: (() -> Void)?
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            contentBody

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.mutedText)
                    .padding(10)
            }
            .buttonStyle(PlainButtonStyle())
            .help("关闭")
        }
        .background(backgroundShape)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: theme.subtleShadow, radius: 14, x: 0, y: 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bannerContent: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(indicatorStyle)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(theme.mutedText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 30)
        .padding(.vertical, 14)
        .frame(minWidth: 320, maxWidth: 420, alignment: .leading)
    }

    private var contentBody: some View {
        Group {
            if let onTap {
                Button(action: onTap) { bannerContent }
                    .buttonStyle(PlainButtonStyle())
                    .help("点击打开")
            } else {
                bannerContent
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var indicatorStyle: AnyShapeStyle {
        switch kind {
        case .update:
            return AnyShapeStyle(theme.accentGradient)
        case .success:
            return AnyShapeStyle(theme.accent.opacity(0.9))
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.85))
        case .warning:
            return AnyShapeStyle(Color.orange.opacity(0.85))
        case .info:
            return AnyShapeStyle(theme.accentSecondary.opacity(0.85))
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(backgroundFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private var backgroundFill: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.72)
        }
        return Color.white.opacity(0.92)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)
    }
}
