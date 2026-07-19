import SwiftUI
import AppKit
import Foundation
import UserNotifications

struct MusicPlayerCommands: Commands {
    @ObservedObject var audioPlayer: AudioPlayer
    let playlistManager: PlaylistManager
    @AppStorage("userNotifyOnDeviceSwitch") private var notifyOnDeviceSwitch: Bool = true
    @AppStorage("userNotifyDeviceSwitchSilent") private var notifyDeviceSwitchSilent: Bool = true
    @AppStorage("userColorSchemeOverride") private var userColorSchemeOverride: Int = 0
    @AppStorage(IPCDebugSettings.userDefaultsKey) private var ipcDebugEnabled: Bool = false

    var body: some Commands {
        // 保证 Command+Q 在任何弹窗/子窗口/Sheet 打开时都能正常退出（不被焦点/第一响应者影响）
        CommandGroup(replacing: .appTermination) {
            Button("退出 MusicPlayer") {
                AppTerminator.requestQuit()
            }
            .keyboardShortcut("q", modifiers: [.command])
        }

        // 将自定义命令收纳到系统默认菜单中，避免顶栏出现过多一级菜单
        CommandGroup(after: .textEditing) {
            Divider()
            Button("搜索播放列表") {
                NotificationCenter.default.post(name: .focusSearchField, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])

            Divider()

            Button("切到队列") {
                NotificationCenter.default.post(name: .switchPlaylistPanelToQueue, object: nil)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("切到歌单") {
                NotificationCenter.default.post(name: .switchPlaylistPanelToPlaylists, object: nil)
            }
            .keyboardShortcut("2", modifiers: [.command])
        }

        CommandGroup(after: .appSettings) {
            Divider()
            Menu("外观") {
                Picker("外观", selection: $userColorSchemeOverride) {
                    Text("跟随系统").tag(UserColorSchemeOverride.system.rawValue)
                    Text("亮色").tag(UserColorSchemeOverride.light.rawValue)
                    Text("暗色").tag(UserColorSchemeOverride.dark.rawValue)
                }
                .pickerStyle(.inline)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { audioPlayer.isImmersivePlaybackEnabled },
                set: { audioPlayer.setImmersivePlaybackEnabled($0) }
            )) {
                Text("沉浸播放")
            }
            .help("自动跳过歌曲前后的静音，让下一首更快接上；不会修改音乐文件")

            Button("音量均衡分析…") {
                NotificationCenter.default.post(name: .showVolumeNormalizationAnalysis, object: nil)
            }

            Divider()

            Menu("文件关联") {
                Button("设为默认打开方式…") {
                    Task { @MainActor in
                        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
                            let alert = NSAlert()
                            alert.messageText = "无法设置默认打开方式"
                            alert.informativeText = "当前不是以 .app 形式运行（例如 swift build 产物）。请使用 MusicPlayer.app 启动后再设置。"
                            alert.addButton(withTitle: "确定")
                            alert.runModal()
                            return
                        }

                        let formats = DefaultAudioFileAssociations.supportedTargets.map(\.label).joined(separator: "\n• ")
                        let alert = NSAlert()
                        alert.messageText = "设为默认打开方式？"
                        alert.informativeText =
                            "将 MusicPlayer 设为以下音频格式的默认打开方式（仅对当前用户生效）：\n\n• \(formats)\n\n提示：可在 Finder 里对任意文件点“显示简介 → 打开方式”改回。"
                        alert.alertStyle = .informational

                        let cancelButton = alert.addButton(withTitle: "取消")
                        cancelButton.keyEquivalent = "\r"
                        cancelButton.keyEquivalentModifierMask = []

                        let confirmButton = alert.addButton(withTitle: "设为默认")
                        confirmButton.keyEquivalent = ""
                        confirmButton.keyEquivalentModifierMask = []

                        guard alert.runModal() == .alertSecondButtonReturn else { return }

                        let result = DefaultAudioFileAssociations.setAsDefaultViewerForSupportedAudio()
                        if result.failed.isEmpty {
                            if result.changed == 0 {
                                NotificationSettingsHelper.postToast(
                                    title: "默认打开方式已是 MusicPlayer",
                                    subtitle: "无需修改（\(result.total) 项均已设置）",
                                    kind: "success",
                                    duration: 2.6
                                )
                            } else {
                                NotificationSettingsHelper.postToast(
                                    title: "已设为默认打开方式",
                                    subtitle: "已更新 \(result.changed) 项（共 \(result.total) 项）",
                                    kind: "success",
                                    duration: 3.0
                                )
                            }
                        } else {
                            NotificationSettingsHelper.postToast(
                                title: "部分格式未能设为默认",
                                subtitle: "成功 \(result.changed + result.alreadyDefault)/\(result.total)，失败 \(result.failed.count)（可在 Finder 手动设置）",
                                kind: "warning",
                                duration: 5.0
                            )
                        }
                    }
                }
            }

            Divider()

            Menu("缓存") {
                Button("清空音量均衡缓存") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空音量均衡缓存？",
                            message: "将删除已分析的音量均衡缓存。下次播放或预分析时会重新计算，可能耗时。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        if Self.clearVolumeCacheWithProtectedConfirmation(audioPlayer) {
                            NotificationCenter.default.post(name: .showVolumeCacheClearedAlert, object: nil)
                        }
                    }
                }

                Button("清空沉浸分析缓存") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空沉浸分析缓存？",
                            message: "只会删除歌曲首尾的响度分析结果，不会修改音乐文件。下次开启沉浸播放时会按需重新分析。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        switch await audioPlayer.clearImmersivePlaybackCache() {
                        case .success:
                            NotificationSettingsHelper.postToast(
                                title: "沉浸分析缓存已清空",
                                subtitle: "音乐文件没有改动",
                                kind: "success",
                                duration: 2.6
                            )
                        case .failure(let error):
                            NotificationSettingsHelper.postToast(
                                title: "沉浸分析缓存清理失败",
                                subtitle: error.localizedDescription,
                                kind: "error",
                                duration: 4.0
                            )
                        }
                    }
                }

                Button("清空时长缓存") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空时长缓存？",
                            message: "将删除歌曲时长缓存。之后列表会重新读取时长，可能耗时。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        switch await DurationCache.shared.clearPersistence() {
                        case .success:
                            playlistManager.resetDurationsAndRestartPrefetch()
                            NotificationCenter.default.post(name: .showDurationCacheClearedAlert, object: nil)
                        case .failure(let error):
                            Self.postCacheFailure(title: "时长缓存清理失败", error: error)
                        }
                    }
                }

                Button("清空随机权重（当前播放范围）") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空随机权重？",
                            message: "将清空当前播放范围（队列/歌单）的“随机权重”设置。之后随机/洗牌将按默认第 2 档（1.0×）。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        let scope: PlaybackWeights.Scope = {
                            switch playlistManager.playbackScope {
                            case .queue: return .queue
                            case .playlist(let id): return .playlist(id)
                            }
                        }()
                        let result = PlaybackWeights.shared.clear(scope: scope)
                        switch result {
                        case .applied, .unchanged:
                            NotificationCenter.default.post(
                                name: .showAppToast,
                                object: nil,
                                userInfo: ["title": "随机权重已清空", "kind": "success", "duration": 2.0]
                            )
                        case .rejectedReadOnly(let reason):
                            NotificationCenter.default.post(
                                name: .showAppToast,
                                object: nil,
                                userInfo: ["title": "无法清空权重", "subtitle": reason.diagnosticMessage, "kind": "error", "duration": 4.0]
                            )
                        }
                    }
                }

                Button("清空随机权重（全部）") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空全部随机权重？",
                            message: "将清空队列与所有歌单的“随机权重”设置，并恢复为默认第 2 档（1.0×）。操作不可撤销。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        let result = PlaybackWeights.shared.clearAll()
                        switch result {
                        case .applied, .unchanged:
                            NotificationCenter.default.post(
                                name: .showAppToast,
                                object: nil,
                                userInfo: ["title": "全部随机权重已清空", "kind": "success", "duration": 2.0]
                            )
                        case .rejectedReadOnly(let reason):
                            NotificationCenter.default.post(
                                name: .showAppToast,
                                object: nil,
                                userInfo: ["title": "无法清空权重", "subtitle": reason.diagnosticMessage, "kind": "error", "duration": 4.0]
                            )
                        }
                    }
                }

                Button("清空封面缩略图（内存）") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空封面缩略图（内存）？",
                            message: "将清空当前封面缩略图与内存缓存（不会删除你的音乐文件）。之后切歌可能需要重新加载/处理封面。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        audioPlayer.clearArtworkCache()
                        await PlaylistArtworkStore.shared.clearMemoryCache()
                        NotificationCenter.default.post(name: .showArtworkCacheClearedAlert, object: nil)
                    }
                }

                Button("清空歌词缓存") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空歌词缓存？",
                            message: "将清空歌词缓存。之后会重新解析内嵌/外置歌词。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        await LyricsService.shared.invalidateAll()
                        NotificationCenter.default.post(name: .showLyricsCacheClearedAlert, object: nil)
                    }
                }

                Divider()

                Button("清空所有缓存") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空所有缓存？",
                            message: "将清空音量均衡、沉浸分析、元数据、时长、封面缩略图（内存）和歌词缓存，不会修改音乐文件。操作不可撤销。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        let volumeCleared = Self.clearVolumeCacheWithProtectedConfirmation(audioPlayer)
                        let immersiveResult = await audioPlayer.clearImmersivePlaybackCache()
                        let durationResult = await DurationCache.shared.clearPersistence()
                        let metadataResult = await MetadataCache.shared.clearPersistence()
                        if case .success = durationResult {
                            playlistManager.resetDurationsAndRestartPrefetch()
                        }
                        audioPlayer.clearArtworkCache()
                        await PlaylistArtworkStore.shared.clearMemoryCache()
                        await LyricsService.shared.invalidateAll()
                        let derivedFailures = [durationResult.map { _ in () }, metadataResult.map { _ in () }]
                            .compactMap { result -> DerivedCachePersistenceError? in
                                if case .failure(let error) = result { return error }
                                return nil
                            }
                        if !volumeCleared {
                            NotificationSettingsHelper.postToast(
                                title: "部分缓存未清理",
                                subtitle: "音量均衡缓存已保留",
                                kind: "warning",
                                duration: 4.0
                            )
                        } else if case .failure(let error) = immersiveResult {
                            NotificationSettingsHelper.postToast(
                                title: "部分缓存清理失败",
                                subtitle: error.localizedDescription,
                                kind: "error",
                                duration: 4.0
                            )
                        } else if let firstFailure = derivedFailures.first {
                            Self.postCacheFailure(title: "部分缓存清理失败", error: firstFailure)
                        } else {
                            NotificationCenter.default.post(name: .showAllCachesClearedAlert, object: nil)
                        }
                    }
                }
            }

            Divider()

            Menu("通知") {
                Button("请求通知权限…") {
                    guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
                        let alert = NSAlert()
                        alert.messageText = "通知功能不可用"
                        alert.informativeText = "当前不是以 .app 形式运行（例如 swift build 产物）。请使用 MusicPlayer.app 启动后再设置通知。"
                        alert.addButton(withTitle: "确定")
                        alert.runModal()
                        return
                    }
                    let center = UNUserNotificationCenter.current()
                    center.getNotificationSettings { settings in
                        switch settings.authorizationStatus {
                        case .authorized, .provisional, .ephemeral:
                            DispatchQueue.main.async {
                                NotificationSettingsHelper.postToast(
                                    title: "通知权限已启用",
                                    subtitle: "可在“通知”菜单里开关是否发送",
                                    kind: "success",
                                    duration: 2.5
                                )
                            }
                        case .denied:
                            DispatchQueue.main.async {
                                NotificationSettingsHelper.openSystemNotificationSettingsOrFallback()
                            }
                        case .notDetermined:
                            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                                center.getNotificationSettings { updated in
                                    DispatchQueue.main.async {
                                        switch updated.authorizationStatus {
                                        case .authorized, .provisional, .ephemeral:
                                            NotificationSettingsHelper.postToast(
                                                title: "通知权限已启用",
                                                subtitle: "设备切换时可显示通知",
                                                kind: "success",
                                                duration: 2.5
                                            )
                                        case .denied:
                                            NotificationSettingsHelper.openSystemNotificationSettingsOrFallback()
                                        case .notDetermined:
                                            NotificationSettingsHelper.postToast(
                                                title: "未弹出系统授权弹窗",
                                                subtitle: "已打开系统通知设置，请手动开启",
                                                kind: "warning",
                                                duration: 4.0
                                            )
                                            NotificationSettingsHelper.openSystemNotificationSettingsOrFallback()
                                        @unknown default:
                                            NotificationSettingsHelper.postToast(
                                                title: "通知权限状态未知",
                                                subtitle: "已打开系统通知设置，请检查通知权限",
                                                kind: "warning",
                                                duration: 4.0
                                            )
                                            NotificationSettingsHelper.openSystemNotificationSettingsOrFallback()
                                        }
                                    }
                                }
                            }
                        @unknown default:
                            DispatchQueue.main.async {
                                NotificationSettingsHelper.postToast(
                                    title: "通知权限状态未知",
                                    subtitle: "已打开系统通知设置，请检查通知权限",
                                    kind: "warning",
                                    duration: 4.0
                                )
                                NotificationSettingsHelper.openSystemNotificationSettingsOrFallback()
                            }
                        }
                    }
                }

                Button("打开系统通知设置…") {
                    let bid = Bundle.main.bundleIdentifier ?? "io.github.lueluelue2006.macosmusicplayer"
                    if NotificationSettingsHelper.openAppNotificationSettings(bundleIdentifier: bid) {
                        return
                    }
                    if !NotificationSettingsHelper.openSystemNotificationSettings() {
                        NotificationSettingsHelper.copyOpenCommandAndOpenTerminal()
                    }
                }

                Button("发送测试通知") {
                    SystemNotifier.shared.notifyDeviceChanged(to: "测试设备", silent: notifyDeviceSwitchSilent)
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { notifyOnDeviceSwitch },
                    set: { newValue in
                        notifyOnDeviceSwitch = newValue
                        audioPlayer.notifyOnDeviceSwitch = newValue
                    }
                )) {
                    Text("设备切换时通知")
                }

                Toggle(isOn: Binding(
                    get: { notifyDeviceSwitchSilent },
                    set: { newValue in
                        notifyDeviceSwitchSilent = newValue
                        audioPlayer.notifyDeviceSwitchSilent = newValue
                    }
                )) {
                    Text("设备切换通知静音（默认）")
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { ipcDebugEnabled },
                set: { newValue in
                    ipcDebugEnabled = newValue
                    IPCDebugSettings.setEnabled(newValue)
                    NotificationSettingsHelper.postToast(
                        title: newValue ? "已开启 CLI 调试模式" : "已关闭 CLI 调试模式",
                        subtitle: newValue ? "musicplayerctl 命令现已可用" : "IPC 命令调用将被拒绝",
                        kind: newValue ? "success" : "info",
                        duration: 2.8
                    )
                }
            )) {
                Text("启用 CLI 调试模式")
            }

            Divider()

            Button("检查更新…") {
                NotificationCenter.default.post(name: .manualCheckForUpdates, object: nil)
            }
            .help("检查 GitHub Releases 是否有新版本")
        }
    }

    private static func postCacheFailure(
        title: String,
        error: DerivedCachePersistenceError
    ) {
        NotificationSettingsHelper.postToast(
            title: title,
            subtitle: error.localizedDescription,
            kind: "error",
            duration: 4.0
        )
    }

    @MainActor
    private static func clearVolumeCacheWithProtectedConfirmation(
        _ audioPlayer: AudioPlayer
    ) -> Bool {
        switch audioPlayer.clearVolumeCache() {
        case .cleared:
            return true
        case .failed(let message):
            NotificationSettingsHelper.postToast(
                title: "音量均衡缓存清理失败",
                subtitle: message,
                kind: "error",
                duration: 4.0
            )
            return false
        case .requiresConfirmation(let reason):
            let confirmed = DestructiveConfirmation.confirm(
                title: "删除受保护的音量缓存？",
                message: protectedVolumeCacheMessage(reason),
                confirmTitle: "仍然删除",
                cancelTitle: "保留"
            )
            guard confirmed else { return false }
            switch audioPlayer.clearVolumeCache(forceProtectedData: true) {
            case .cleared:
                return true
            case .failed(let message):
                NotificationSettingsHelper.postToast(
                    title: "音量均衡缓存清理失败",
                    subtitle: message,
                    kind: "error",
                    duration: 4.0
                )
                return false
            case .requiresConfirmation:
                return false
            }
        }
    }

    private static func protectedVolumeCacheMessage(
        _ reason: ProtectedVolumeCacheReason
    ) -> String {
        switch reason {
        case .futureLegacyJSON(let version):
            return "发现由更高版本创建的音量缓存（版本 \(version)）。删除后无法恢复其中的数据。"
        case .unknownLegacyJSON:
            return "现有音量缓存格式无法识别。删除后无法恢复原文件。"
        case .futureDatabase(let version):
            return "发现由更高版本创建的音量数据库（版本 \(version)）。删除后无法恢复其中的数据。"
        case .foreignDatabase:
            return "现有数据库不属于 MusicPlayer。为避免误删，只有再次确认后才会移除。"
        }
    }
}

private enum NotificationSettingsHelper {
    private static let notificationsPaneCandidates: [URL] = [
        URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!,
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!,
    ]

    private static let settingsAppURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    private static let terminalAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    static func postToast(
        title: String,
        subtitle: String? = nil,
        kind: String = "info",
        duration: TimeInterval = 3.0,
        url: URL? = nil
    ) {
        NotificationCenter.default.post(
            name: .showAppToast,
            object: nil,
            userInfo: [
                "title": title,
                "subtitle": subtitle as Any,
                "kind": kind,
                "duration": duration,
                "url": url as Any
            ]
        )
    }

    @discardableResult
    static func openSystemNotificationSettings() -> Bool {
        for url in notificationsPaneCandidates {
            if NSWorkspace.shared.open(url) {
                activateSystemSettingsSoon()
                return true
            }
        }

        NSWorkspace.shared.openApplication(at: settingsAppURL, configuration: NSWorkspace.OpenConfiguration())
        return false
    }

    static func openSystemNotificationSettingsOrFallback() {
        let bid = Bundle.main.bundleIdentifier ?? "io.github.lueluelue2006.macosmusicplayer"
        if openAppNotificationSettings(bundleIdentifier: bid) {
            postToast(
                title: "已打开系统通知设置",
                subtitle: "若未自动定位到 MusicPlayer，请在列表中点击它",
                kind: "warning",
                duration: 5.0,
                url: notificationsPaneCandidates.first
            )
            return
        }

        if openSystemNotificationSettings() {
            postToast(
                title: "通知权限未启用",
                subtitle: "已打开系统通知设置（找到“音乐播放器”并开启通知）",
                kind: "warning",
                duration: 5.0,
                url: notificationsPaneCandidates.first
            )
            return
        }
        copyOpenCommandAndOpenTerminal()
    }

    @discardableResult
    static func openAppNotificationSettings(bundleIdentifier: String) -> Bool {
        let encoded = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleIdentifier

        let candidates = [
            "x-apple.systempreferences:com.apple.preference.notifications?bundleIdentifier=\(encoded)",
            "x-apple.systempreferences:com.apple.preference.notifications?bundleId=\(encoded)",
            "x-apple.systempreferences:com.apple.preference.notifications?AppID=\(encoded)",
            "x-apple.systempreferences:com.apple.preference.notifications?app=\(encoded)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundleIdentifier=\(encoded)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundle_identifier=\(encoded)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?AppID=\(encoded)",
        ].compactMap(URL.init(string:))

        for url in candidates {
            if NSWorkspace.shared.open(url) {
                activateSystemSettingsSoon()
                return true
            }
        }
        return false
    }

    static func copyOpenCommandAndOpenTerminal() {
        let cmd = #"open "x-apple.systempreferences:com.apple.preference.notifications""#
        copyToPasteboard(cmd)

        NSWorkspace.shared.openApplication(at: terminalAppURL, configuration: NSWorkspace.OpenConfiguration())

        postToast(
            title: "已复制命令到剪贴板",
            subtitle: "终端已打开，粘贴回车即可",
            kind: "info",
            duration: 4.0,
            url: notificationsPaneCandidates.first
        )
    }

    private static func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private static func activateSystemSettingsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first?
                .activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        }
    }
}
