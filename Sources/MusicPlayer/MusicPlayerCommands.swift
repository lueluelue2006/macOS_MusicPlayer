import SwiftUI
import AppKit
import Foundation
import UserNotifications

struct MusicPlayerCommands: Commands {
    let audioPlayer: AudioPlayer
    let playlistManager: PlaylistManager
    @AppStorage("userNotifyOnDeviceSwitch") private var notifyOnDeviceSwitch: Bool = true
    @AppStorage("userNotifyDeviceSwitchSilent") private var notifyDeviceSwitchSilent: Bool = true
    @AppStorage("userColorSchemeOverride") private var userColorSchemeOverride: Int = 0

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
                        audioPlayer.clearVolumeCache()
                        NotificationCenter.default.post(name: .showVolumeCacheClearedAlert, object: nil)
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
                        await DurationCache.shared.removeAll()
                        playlistManager.resetDurationsAndRestartPrefetch()
                        NotificationCenter.default.post(name: .showDurationCacheClearedAlert, object: nil)
                    }
                }

                Button("清空随机权重（当前播放范围）") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空随机权重？",
                            message: "将清空当前播放范围（队列/歌单）的“随机权重”设置。之后随机/洗牌将按默认权重(1.0×)。",
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
                        PlaybackWeights.shared.clear(scope: scope)
                        NotificationCenter.default.post(
                            name: .showAppToast,
                            object: nil,
                            userInfo: ["title": "随机权重已清空", "kind": "success", "duration": 2.0]
                        )
                    }
                }

                Button("清空随机权重（全部）") {
                    Task { @MainActor in
                        let confirmed = DestructiveConfirmation.confirm(
                            title: "清空全部随机权重？",
                            message: "将清空队列与所有歌单的“随机权重”设置。操作不可撤销。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        PlaybackWeights.shared.clearAll()
                        NotificationCenter.default.post(
                            name: .showAppToast,
                            object: nil,
                            userInfo: ["title": "全部随机权重已清空", "kind": "success", "duration": 2.0]
                        )
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
                            message: "将清空音量均衡缓存、时长缓存、封面缩略图（内存）、歌词缓存。操作不可撤销。",
                            confirmTitle: "清除",
                            cancelTitle: "不清除"
                        )
                        guard confirmed else { return }
                        audioPlayer.clearVolumeCache()
                        await DurationCache.shared.removeAll()
                        playlistManager.resetDurationsAndRestartPrefetch()
                        audioPlayer.clearArtworkCache()
                        await LyricsService.shared.invalidateAll()
                        NotificationCenter.default.post(name: .showAllCachesClearedAlert, object: nil)
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

            Button("检查更新…") {
                NotificationCenter.default.post(name: .manualCheckForUpdates, object: nil)
            }
            .help("检查 GitHub Releases 是否有新版本")
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
