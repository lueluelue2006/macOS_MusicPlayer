import SwiftUI
import Foundation

struct ContentView: View {
    // Inject shared instances from MusicPlayerApp to avoid duplicate players after window reopen
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var playlistsStore: PlaylistsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @StateObject private var toastState = ToastState()
    @StateObject private var updateCheckState = UpdateCheckState()

    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showVolumeNormalizationAnalysis = false

    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0.0"
    }

    var body: some View {
        layoutView
            .background(theme.libraryBackground)
            .tint(theme.accent)
            .onAppear {
                NotificationCenter.default.post(name: .blurSearchField, object: nil)
                playlistManager.performInitialRestoreIfNeeded(
                    audioPlayer: audioPlayer,
                    playlistsStore: playlistsStore
                )
                triggerAutoUpdateCheck()
            }
            .onDisappear {
                playlistManager.savePlaylist()
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleGlobalDrop(providers: providers)
                return true
            }
            .sheet(isPresented: $showVolumeNormalizationAnalysis) {
                VolumeNormalizationAnalysisView(
                    audioPlayer: audioPlayer,
                    playlistManager: playlistManager
                )
            }
            .alert(alertMessage, isPresented: $showAlert) {
                Button("确定", role: .cancel) { }
            }
            .overlay(alignment: .topTrailing) {
                if toastState.isVisible {
                    ToastBanner(
                        title: toastState.title,
                        subtitle: toastState.subtitle,
                        kind: toastState.kind,
                        onTap: toastState.hasTapAction ? { handleToastTap() } : nil,
                        onClose: { toastState.dismiss() }
                    )
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
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
            .onChange(of: playlistManager.audioFiles.count) { _ in triggerAutoUpdateCheck() }
            .onChange(of: playlistManager.isAddingFiles) { _ in triggerAutoUpdateCheck() }
            .onChange(of: playlistManager.isRestoringPlaylist) { _ in triggerAutoUpdateCheck() }
            .onReceive(NotificationCenter.default.publisher(for: .loadLastPlayedFile)) { notification in
                handleLoadLastPlayedFile(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showVolumeCacheClearedAlert)) { _ in
                showAlert("音量均衡缓存已清空")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showDurationCacheClearedAlert)) { _ in
                showAlert("时长缓存已清空")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showArtworkCacheClearedAlert)) { _ in
                showAlert("封面缩略图（内存）已清空")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showLyricsCacheClearedAlert)) { _ in
                showAlert("歌词缓存已清空")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAllCachesClearedAlert)) { _ in
                showAlert("所有缓存已清空")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showVolumeNormalizationAnalysis)) { _ in
                showVolumeNormalizationAnalysis = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestDismissAllSheets)) { _ in
                showVolumeNormalizationAnalysis = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .manualCheckForUpdates)) { _ in
                updateCheckState.manualCheck(currentVersion: currentVersion, onOutcome: handleUpdateOutcome)
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioPlayerDidFailToPlay)) { notification in
                let raw = (notification.userInfo?["message"] as? String) ?? "播放失败"
                let firstLine = raw
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? raw
                toastState.show(firstLine, kind: .error)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAppToast)) { notification in
                handleShowAppToast(notification)
            }
    }

    private var layoutView: some View {
        GeometryReader { geometry in
            if geometry.size.width < 980 {
                VStack(spacing: 0) {
                    PlayerView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                        .frame(height: max(260, geometry.size.height * 0.48))
                        .background(theme.nowPlayingBackground)

                    Rectangle()
                        .fill(theme.paneDivider)
                        .frame(height: 1)

                    PlaylistView(
                        audioPlayer: audioPlayer,
                        playlistManager: playlistManager,
                        playlistsStore: playlistsStore
                    )
                    .frame(minHeight: 200)
                    .background(theme.libraryBackground)
                }
            } else {
                HStack(spacing: 0) {
                    PlayerView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                        .frame(width: min(max(430, geometry.size.width * 0.34), 540))
                        .background(theme.nowPlayingBackground)

                    Rectangle()
                        .fill(theme.paneDivider)
                        .frame(width: 1)

                    PlaylistView(
                        audioPlayer: audioPlayer,
                        playlistManager: playlistManager,
                        playlistsStore: playlistsStore
                    )
                    .frame(minWidth: 480)
                    .background(theme.libraryBackground)
                }
            }
        }
    }

    private func triggerAutoUpdateCheck() {
        updateCheckState.maybeAutoCheck(
            currentVersion: currentVersion,
            playlistManager: playlistManager,
            onOutcome: handleUpdateOutcome
        )
    }

    private func handleUpdateOutcome(_ outcome: UpdateChecker.CheckOutcome) {
        switch outcome {
        case .updateAvailable(let info):
            if info.assetURL != nil && info.checksumAssetURL != nil {
                toastState.show(
                    "发现新版本 \(info.latestVersion)",
                    subtitle: "点击自动更新（下载并校验后安装）",
                    kind: .update,
                    duration: 10.0,
                    tapUpdate: info
                )
            } else if info.assetURL != nil {
                toastState.show(
                    "发现新版本 \(info.latestVersion)",
                    subtitle: "未找到 SHA256 校验文件，点击打开 Releases 手动下载",
                    kind: .warning,
                    duration: 10.0,
                    tapURL: info.releaseURL
                )
            } else {
                toastState.show(
                    "发现新版本 \(info.latestVersion)",
                    subtitle: "点击打开 GitHub Releases 下载",
                    kind: .update,
                    duration: 10.0,
                    tapURL: info.releaseURL
                )
            }
        case .upToDate(let current, let latest, let url):
            if latest == current {
                toastState.show("已是最新版本 \(current)", kind: .success, duration: 2.0, tapURL: url)
            } else {
                toastState.show(
                    "已是最新版本 \(current)",
                    subtitle: "线上最新：\(latest)",
                    kind: .success,
                    duration: 2.0,
                    tapURL: url
                )
            }
        case .failed(let message, let url):
            toastState.show(message, subtitle: "点击打开 GitHub Releases", kind: .warning, duration: 2.0, tapURL: url)
        }
    }

    private func handleToastTap() {
        if let info = toastState.tapUpdate {
            updateCheckState.startSelfUpdate(info, toastState: toastState)
        } else if let url = toastState.tapURL {
            openURL(url)
        }
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func handleLoadLastPlayedFile(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let url = userInfo["url"] as? URL,
              let time = userInfo["time"] as? TimeInterval else { return }

        guard let index = playlistManager.audioFiles.firstIndex(where: { $0.url == url }) else {
            toastState.show("未能在播放列表中找到上次播放文件", kind: .warning)
            return
        }

        playlistManager.currentIndex = index
        playlistManager.savePlaylist()
        audioPlayer.prepareInitialSeekForRestore(to: time, for: url)
        if let file = playlistManager.selectFile(at: index) {
            audioPlayer.play(file, autostart: false, bypassConfirm: true)
        }
    }

    private func handleShowAppToast(_ notification: Notification) {
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
        toastState.show(title, subtitle: subtitle, kind: kind, duration: duration, tapURL: tapURL)
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
                    if let url { results.append(url) }
                }
                return results
            }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                playlistManager.enqueueAddFiles(urls)
            }
        }
    }
}
