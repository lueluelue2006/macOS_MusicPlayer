import SwiftUI
import AVFoundation
import AVKit
import AppKit
import UserNotifications

@main
struct MusicPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Create single shared instances for the whole app lifetime.
    // These survive window closes (Cmd+W) and avoid duplicate audio playback.
	    private let audioPlayer: AudioPlayer
	    private let playlistManager: PlaylistManager
	    private let playlistsStore: PlaylistsStore
	    private let playbackCoordinator: PlaybackCoordinator
	    private let audioRouteMonitor: AudioRouteMonitor
	    private let ipcServer: IPCServer
	    private let notificationDelegate = NotificationCenterDelegate()
    
    init() {
        // Bundle identifier change migration:
        // - avoids conflicting defaults when other apps use the old id
        // - preserves existing user settings on upgrade
        UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(currentBundleIdentifier: Bundle.main.bundleIdentifier)

	        let audioPlayer = AudioPlayer()
	        let playlistManager = PlaylistManager()
	        let playlistsStore = PlaylistsStore()
	        let playbackCoordinator = PlaybackCoordinator(audioPlayer: audioPlayer, playlistManager: playlistManager)
	        let ipcServer = IPCServer(audioPlayer: audioPlayer, playlistManager: playlistManager)

        let audioRouteMonitor = AudioRouteMonitor(
            onHeadphonesDisconnected: { [weak audioPlayer] in
                DispatchQueue.main.async {
                    guard let ap = audioPlayer else { return }
                    ap.isHeadphoneOutput = false
                    ap.shouldConfirmSpeakerPlayback = true
                    if ap.isPlaying {
                        ap.shouldAutoResumeAfterRoute = true
                        ap.pause()
                    }
                }
            },
            onHeadphonesConnected: { [weak audioPlayer] in
                DispatchQueue.main.async {
                    guard let ap = audioPlayer else { return }
                    ap.isHeadphoneOutput = true
                    ap.shouldConfirmSpeakerPlayback = false
                    // 若系统正在/刚刚睡眠，或在唤醒后宽限期内，均不自动续播
                    if ap.isSystemSleeping {
                        ap.shouldAutoResumeAfterRoute = false
                        return
                    }
                    if ap.suppressAutoResumeOnce {
                        ap.suppressAutoResumeOnce = false
                        ap.shouldAutoResumeAfterRoute = false
                        return
                    }
                    if let until = ap.disallowAutoResumeUntil, Date() < until {
                        ap.shouldAutoResumeAfterRoute = false
                        return
                    }
                    if ap.shouldAutoResumeAfterRoute, !ap.isPlaying, ap.currentFile != nil {
                        ap.shouldAutoResumeAfterRoute = false
                        ap.resume()
                    }
                }
            },
            onDeviceChanged: { [weak audioPlayer] name in
                DispatchQueue.main.async {
                    guard let ap = audioPlayer else { return }
                    let oldName = ap.currentOutputDeviceName
                    ap.currentOutputDeviceName = name
                    let l = name.lowercased()
                    // 认为包含以下关键词的是“内置扬声器”，其余视为外置设备
                    let isInternal = (
                        l.contains("internal") ||
                        l.contains("built-in") ||
                        l.contains("内置") ||
                        l.contains("内建") ||
                        l.contains("macbook")
                    ) && !l.contains("display") && !l.contains("airplay")
                    ap.isInternalSpeakerOutput = isInternal

                    // 首次初始化不提示；名称变化后才发系统通知
                    if ap.hasInitializedOutputDeviceName {
                        if oldName != name {
                            if ap.notifyOnDeviceSwitch {
                                SystemNotifier.shared.notifyDeviceChanged(to: name, silent: ap.notifyDeviceSwitchSilent)
                            }
                        }
                    } else {
                        ap.hasInitializedOutputDeviceName = true
                    }
                }
            }
        )

	        self.audioPlayer = audioPlayer
	        self.playlistManager = playlistManager
	        self.playlistsStore = playlistsStore
	        self.playbackCoordinator = playbackCoordinator
	        self.ipcServer = ipcServer
	        self.audioRouteMonitor = audioRouteMonitor

        // 连接 AppDelegate，使其可以接管 Finder/Dock 打开的临时文件
        appDelegate.configure(audioPlayer: audioPlayer, playlistManager: playlistManager)

        // Run format detection tests in background to avoid blocking app startup/IPC.
        #if DEBUG
        Task.detached(priority: .background) {
            FormatDetectionTest.runTests()
            FormatDetectionTest.testSpecificScenarios()
        }
        #endif

        // System notifications: only available when running as a bundled .app.
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            let center = UNUserNotificationCenter.current()
            center.delegate = notificationDelegate
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }
    
    var body: some Scene {
        // 使用单窗口场景，避免因外部“打开文件”事件在 macOS 上产生重复主窗口
	        Window("音乐播放器", id: "main") {
	            RootView(audioPlayer: audioPlayer, playlistManager: playlistManager, playlistsStore: playlistsStore)
	                .frame(minWidth: 600, minHeight: 400)
	        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            MusicPlayerCommands(audioPlayer: audioPlayer, playlistManager: playlistManager)
        }
    }
}
