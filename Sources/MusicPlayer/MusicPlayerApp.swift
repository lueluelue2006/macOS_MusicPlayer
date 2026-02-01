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
    private let audioPlayer = AudioPlayer()
    private let playlistManager = PlaylistManager()
    private var playbackCoordinator: PlaybackCoordinator!
    private var audioRouteMonitor: AudioRouteMonitor!
    private var ipcServer: IPCServer!
    private let notificationDelegate = NotificationCenterDelegate()
    
    init() {
        // 将协调器常驻应用生命周期，确保自动切歌/自动播放不依赖视图
        self.playbackCoordinator = PlaybackCoordinator(audioPlayer: audioPlayer, playlistManager: playlistManager)
        // CLI/调试入口：通过 DistributedNotificationCenter 接收命令
        self.ipcServer = IPCServer(audioPlayer: audioPlayer, playlistManager: playlistManager)
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

        // 监听音频路由变化（耳机拔出/设备切换）
        // - 拔出：若正在播放 → 暂停并记录“可自动续播”标记
        // - 插回/切回耳机：若标记存在且未播放 → 自动继续
        self.audioRouteMonitor = AudioRouteMonitor(
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
    }
    
    var body: some Scene {
        // 使用单窗口场景，避免因外部“打开文件”事件在 macOS 上产生重复主窗口
        Window("音乐播放器", id: "main") {
            RootView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            MusicPlayerCommands(audioPlayer: audioPlayer)
        }
    }
}
