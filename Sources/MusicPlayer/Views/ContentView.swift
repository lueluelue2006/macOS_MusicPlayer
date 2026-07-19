import SwiftUI
import Foundation

struct ContentView: View {
    // Inject shared instances from MusicPlayerApp to avoid duplicate players after window reopen
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var playlistsStore: PlaylistsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var toastState = ToastState()
    @StateObject private var updateCheckState = UpdateCheckState()

    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showVolumeNormalizationAnalysis = false
    @State private var pendingSearchFocus = false
    @State private var pendingSearchFocusTargetRaw: String?
    @State private var compactPaneRaw: Int

    init(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        playlistsStore: PlaylistsStore
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
        _compactPaneRaw = State(
            initialValue: playlistManager.appPreferencesStore.load().compactRootPane
        )
    }

    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0.0"
    }

    var body: some View {
        notificationHandlingView
    }

    private var lifecycleView: some View {
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
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleGlobalDrop(providers: providers)
                return true
            }
    }

    private var presentationView: some View {
        lifecycleView
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
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
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
    }

    private var stateHandlingView: some View {
        presentationView
            .onChange(of: playlistManager.audioFiles.count) { _ in triggerAutoUpdateCheck() }
            .onChange(of: playlistManager.isAddingFiles) { _ in triggerAutoUpdateCheck() }
            .onChange(of: playlistManager.isRestoringPlaylist) { _ in triggerAutoUpdateCheck() }
            .onChange(of: compactPaneRaw) { _ in
                persistCompactPaneSelection()
            }
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
    }

    private var appNotificationView: some View {
        stateHandlingView
            .onReceive(NotificationCenter.default.publisher(for: .showVolumeNormalizationAnalysis)) { _ in
                showVolumeNormalizationAnalysis = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestDismissAllSheets)) { _ in
                showVolumeNormalizationAnalysis = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .manualCheckForUpdates)) { _ in
                toastState.show("正在检查更新…", kind: .update, duration: 2.0)
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

    private var notificationHandlingView: some View {
        appNotificationView
            .onReceive(NotificationCenter.default.publisher(for: .switchPlaylistPanelToQueue)) { _ in
                selectCompactPane(.library)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchPlaylistPanelToPlaylists)) { _ in
                selectCompactPane(.library)
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInQueue)) { _ in
                selectCompactPane(.library)
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestLocateNowPlayingInPlaylist)) { _ in
                selectCompactPane(.library)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { notification in
                revealLibraryAndRefocusIfNeeded(notification)
            }
    }

    private var layoutView: some View {
        GeometryReader { geometry in
            let mode = RootLayoutMode(size: geometry.size)

            VStack(spacing: 0) {
                if mode == .compact {
                    CompactPaneSwitcher(
                        selection: compactPane,
                        onSelect: selectCompactPane
                    )
                }

                responsivePanes(mode: mode, size: geometry.size)
            }
        }
    }

    private func responsivePanes(mode: RootLayoutMode, size: CGSize) -> some View {
        let playerWidth = mode == .wide ? min(max(430, size.width * 0.34), 540) : nil
        let playerHeight = mode == .stacked
            ? min(max(320, size.height * 0.46), size.height - 300)
            : nil
        let libraryWidth = mode == .wide
            ? size.width - (playerWidth ?? 0) - 1
            : size.width
        let libraryHeight = mode == .stacked
            ? size.height - (playerHeight ?? 0) - 1
            : size.height - (mode == .compact ? 46 : 0)
        let playerPaneHeight = mode == .stacked
            ? (playerHeight ?? size.height)
            : size.height - (mode == .compact ? 46 : 0)
        let usesCompactPlayerChrome = playerPaneHeight < 650
        let usesCompactLibraryChrome = libraryWidth < 680 || libraryHeight < 620
        let showsPlayer = mode != .compact || compactPane == .nowPlaying
        let showsLibrary = mode != .compact || compactPane == .library
        let layout = paneLayout(for: mode)

        return layout {
            playerPane(
                isActive: showsPlayer,
                isCompactRoot: usesCompactPlayerChrome
            )
                .frame(width: playerWidth, height: playerHeight)
                .frame(
                    maxWidth: mode == .wide ? nil : .infinity,
                    maxHeight: mode == .stacked ? nil : .infinity
                )
                .opacity(showsPlayer ? 1 : 0)
                .allowsHitTesting(showsPlayer)
                .accessibilityHidden(!showsPlayer)
                .zIndex(showsPlayer ? 1 : 0)

            responsivePaneDivider(mode: mode)

            libraryPane(
                isCompactRoot: usesCompactLibraryChrome,
                isActive: showsLibrary
            )
                .frame(
                    minWidth: mode == .wide ? 480 : nil,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .opacity(showsLibrary ? 1 : 0)
                .allowsHitTesting(showsLibrary)
                .accessibilityHidden(!showsLibrary)
                .zIndex(showsLibrary ? 1 : 0)
        }
    }

    private func paneLayout(for mode: RootLayoutMode) -> AnyLayout {
        switch mode {
        case .wide:
            return AnyLayout(HStackLayout(spacing: 0))
        case .stacked:
            return AnyLayout(VStackLayout(spacing: 0))
        case .compact:
            return AnyLayout(ZStackLayout())
        }
    }

    private func playerPane(isActive: Bool, isCompactRoot: Bool) -> some View {
        PlayerView(
            audioPlayer: audioPlayer,
            playlistManager: playlistManager,
            isActive: isActive,
            isCompactRoot: isCompactRoot
        )
            .background(theme.nowPlayingBackground)
    }

    private func libraryPane(isCompactRoot: Bool, isActive: Bool) -> some View {
        PlaylistView(
            audioPlayer: audioPlayer,
            playlistManager: playlistManager,
            playlistsStore: playlistsStore,
            isCompactRoot: isCompactRoot,
            isActive: isActive
        )
        .background(theme.libraryBackground)
    }

    private func responsivePaneDivider(mode: RootLayoutMode) -> some View {
        Rectangle()
            .fill(theme.paneDivider)
            .frame(
                width: mode == .wide ? 1 : (mode == .compact ? 0 : nil),
                height: mode == .stacked ? 1 : (mode == .compact ? 0 : nil)
            )
            .opacity(mode == .compact ? 0 : 1)
    }

    private var compactPane: CompactRootPane {
        CompactRootPane(rawValue: compactPaneRaw) ?? .nowPlaying
    }

    private func selectCompactPane(_ pane: CompactRootPane) {
        guard compactPaneRaw != pane.rawValue else { return }
        compactPaneRaw = pane.rawValue
    }

    private func persistCompactPaneSelection() {
        let store = playlistManager.appPreferencesStore
        let authoritativeRawValue = store.load().compactRootPane
        guard store.persistenceState == .writable else {
            if compactPaneRaw != authoritativeRawValue {
                compactPaneRaw = authoritativeRawValue
            }
            handleCompactPaneChange()
            return
        }

        _ = store.update { $0.compactRootPane = compactPaneRaw }
        if case .failure = store.persist() {
            _ = store.update { $0.compactRootPane = authoritativeRawValue }
            if compactPaneRaw != authoritativeRawValue {
                compactPaneRaw = authoritativeRawValue
            }
        }
        handleCompactPaneChange()
    }

    private func revealLibraryAndRefocusIfNeeded(_ notification: Notification) {
        guard compactPane != .library else { return }
        let requestedTarget = (notification.userInfo?["target"] as? String)
            .flatMap(SearchFocusTarget.init(rawValue:))
            ?? AppFocusState.shared.activeSearchTarget
        AppFocusState.shared.pendingSearchFocusTarget = requestedTarget
        pendingSearchFocus = true
        pendingSearchFocusTargetRaw = requestedTarget.rawValue
        selectCompactPane(.library)
    }

    private func handleCompactPaneChange() {
        NotificationCenter.default.post(name: .blurSearchField, object: nil)
        guard compactPane == .library, pendingSearchFocus else { return }

        pendingSearchFocus = false
        let targetRaw = pendingSearchFocusTargetRaw
        pendingSearchFocusTargetRaw = nil
        DispatchQueue.main.async {
            let userInfo: [AnyHashable: Any]? = targetRaw.map { ["target": $0] }
            NotificationCenter.default.post(
                name: .focusSearchField,
                object: nil,
                userInfo: userInfo
            )
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

private enum RootLayoutMode: Equatable {
    case wide
    case stacked
    case compact

    init(size: CGSize) {
        if size.width >= 980 {
            self = .wide
        } else if size.height >= 700 {
            self = .stacked
        } else {
            self = .compact
        }
    }
}

private enum CompactRootPane: Int {
    case nowPlaying = 0
    case library = 1
}

private struct CompactPaneSwitcher: View {
    let selection: CompactRootPane
    let onSelect: (CompactRootPane) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        HStack(spacing: 4) {
            paneButton(
                pane: .nowPlaying,
                title: "正在播放",
                systemName: "waveform"
            )
            paneButton(
                pane: .library,
                title: "音乐库",
                systemName: "music.note.list"
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(theme.panelSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.paneDivider)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主界面区域")
    }

    private func paneButton(
        pane: CompactRootPane,
        title: String,
        systemName: String
    ) -> some View {
        let isSelected = selection == pane

        return Button {
            onSelect(pane)
        } label: {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.accent : theme.stageSecondaryText)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? theme.selectedSurface : Color.clear)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? theme.accent : Color.clear)
                        .frame(height: 2)
                        .padding(.horizontal, 18)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
