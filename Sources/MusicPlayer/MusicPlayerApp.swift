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
	    private let audioPlayer: AudioPlayer?
	    private let playlistManager: PlaylistManager?
	    private let playlistsStore: PlaylistsStore?
	    private let playbackCoordinator: PlaybackCoordinator?
	    private let audioRouteMonitor: AudioRouteMonitor?
	    private let externalVolumeCoordinator: ExternalVolumeCoordinator?
	    private let ipcServer: IPCServer?
	    private let singleInstanceCoordinator: SingleInstanceCoordinator?
	    private let startupFailureMessage: String?
	    private let startupRecovery: (() -> Bool)?
	    private let notificationDelegate = NotificationCenterDelegate()
    
    init() {
        let coordinator: SingleInstanceCoordinator
        let acquisition: SingleInstanceCoordinator.Acquisition
        do {
            coordinator = try SingleInstanceCoordinator()
            acquisition = try coordinator.acquire()
        } catch {
            // Fail closed: starting without the writer lock could corrupt queue,
            // playlist, weight, and cache state if another process is alive.
            PersistenceLogger.log("无法建立单实例写锁，当前进程将安全退出")
            self.singleInstanceCoordinator = nil
            self.audioPlayer = nil
            self.playlistManager = nil
            self.playlistsStore = nil
            self.playbackCoordinator = nil
            self.audioRouteMonitor = nil
            self.externalVolumeCoordinator = nil
            self.ipcServer = nil
            self.startupFailureMessage = nil
            self.startupRecovery = nil
            Self.scheduleSecondaryTermination()
            return
        }

        self.singleInstanceCoordinator = coordinator
        var promotedPrimaryOpenURLs: [URL] = []
        if acquisition == .secondary {
            let launchURLs = SingleInstanceCoordinator.commandLineOpenURLs(
                arguments: ProcessInfo.processInfo.arguments
            )
            let resolution: SingleInstanceCoordinator.SecondaryLaunchResolution
            do {
                resolution = try coordinator.resolveSecondaryLaunch(openURLs: launchURLs)
            } catch {
                PersistenceLogger.log(
                    "单实例接管判定失败，当前进程将安全退出：\(error.localizedDescription)"
                )
                self.audioPlayer = nil
                self.playlistManager = nil
                self.playlistsStore = nil
                self.playbackCoordinator = nil
                self.audioRouteMonitor = nil
                self.externalVolumeCoordinator = nil
                self.ipcServer = nil
                self.startupFailureMessage = nil
                self.startupRecovery = nil
                appDelegate.configureSecondary(singleInstanceCoordinator: coordinator)
                Self.scheduleSecondaryTermination()
                return
            }

            switch resolution {
            case .forwardedToPrimary:
                self.audioPlayer = nil
                self.playlistManager = nil
                self.playlistsStore = nil
                self.playbackCoordinator = nil
                self.audioRouteMonitor = nil
                self.externalVolumeCoordinator = nil
                self.ipcServer = nil
                self.startupFailureMessage = nil
                self.startupRecovery = nil
                appDelegate.configureSecondary(singleInstanceCoordinator: coordinator)
                Self.scheduleSecondaryTermination()
                return
            case .becamePrimary(let openURLs):
                // `resolveSecondaryLaunch` retained this same request in the
                // coordinator. Keep its canonical result through composition;
                // AppDelegate.configure installs the handler that drains it.
                promotedPrimaryOpenURLs = openURLs
            }
        }

        let environment: PersistenceEnvironment
        do {
            environment = try PersistenceEnvironment.production()
            try environment.prepareDirectories()
        } catch {
            self.audioPlayer = nil
            self.playlistManager = nil
            self.playlistsStore = nil
            self.playbackCoordinator = nil
            self.audioRouteMonitor = nil
            self.externalVolumeCoordinator = nil
            self.ipcServer = nil
            self.startupFailureMessage = "无法准备音乐库目录：\(error.localizedDescription)"
            self.startupRecovery = nil
            appDelegate.configureFailedPrimary(singleInstanceCoordinator: coordinator)
            return
        }

        // The legacy entry points below resolve fixed production paths and the
        // standard defaults domain. Never let an XCTest/regression composition
        // escape its isolated PersistenceEnvironment.
        if !environment.isTesting {
            UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
                currentBundleIdentifier: Bundle.main.bundleIdentifier,
                currentDefaults: environment.userDefaults
            )
            PathKeyDiskMigrator.migrateLegacyLowercasedKeysIfNeeded()
        }
        _ = LegacyPersistenceGovernor(
            baseDirectory: environment.applicationSupportURL
        ).run()

        let bootstrap = LibraryBootstrap.open(environment: environment)
        guard let libraryDatabase = bootstrap.database else {
            self.audioPlayer = nil
            self.playlistManager = nil
            self.playlistsStore = nil
            self.playbackCoordinator = nil
            self.audioRouteMonitor = nil
            self.externalVolumeCoordinator = nil
            self.ipcServer = nil
            self.startupFailureMessage = bootstrap.legacyFallbackIssue?.localizedDescription
                ?? "音乐库数据库无法安全打开"
            let finalURL = environment.applicationSupportURL.appendingPathComponent(
                LibraryBootstrap.databaseFileName
            )
            self.startupRecovery = FileManager.default.fileExists(atPath: finalURL.path)
                ? {
                    do {
                        _ = try LibraryBootstrap.recoverCorruptAuthorityStartingEmpty(
                            environment: environment
                        )
                        return true
                    } catch {
                        PersistenceLogger.log(
                            "显式重建音乐库失败：\(error.localizedDescription)"
                        )
                        return false
                    }
                }
                : nil
            appDelegate.configureFailedPrimary(singleInstanceCoordinator: coordinator)
            return
        }

        let appPreferencesStore = AppPreferencesStore(userDefaults: environment.userDefaults)
        IPCDebugSettings.setEnabled(appPreferencesStore.load().ipcDebugEnabled)
        let playbackWeights = PlaybackWeights(libraryDatabase: libraryDatabase)
        let playbackSessionStore = PlaybackSessionStore(libraryDatabase: libraryDatabase)
        let signatureCaptureService = SignatureCaptureService()
	    let libraryLocationResolver = LibraryLocationResolver()
	    let audioPlayer = AudioPlayer(
            environment: environment,
            appPreferencesStore: appPreferencesStore
        )
	        let playlistManager = PlaylistManager(
                libraryDatabase: libraryDatabase,
                libraryLocationResolver: libraryLocationResolver,
                signatureCaptureService: signatureCaptureService,
                appPreferencesStore: appPreferencesStore,
                legacyUserDefaults: environment.userDefaults,
                playbackSessionStore: playbackSessionStore,
                playbackWeights: playbackWeights,
                playbackStateRekeyHandler: { [weak audioPlayer] oldURL, newURL in
                    audioPlayer?.rekeyPersistedPlaybackState(from: oldURL, to: newURL)
                        ?? .unchanged
                }
            )
	    audioPlayer.configurePlaybackAccessLeaseProvider(playlistManager)
	        let playlistsStore = PlaylistsStore(
                libraryDatabase: libraryDatabase,
                signatureCaptureService: signatureCaptureService,
                playbackWeights: playbackWeights
            )
	        let playbackCoordinator = PlaybackCoordinator(
                audioPlayer: audioPlayer,
                playlistManager: playlistManager,
                playlistsStore: playlistsStore,
                playbackSessionStore: playbackSessionStore
            )
	        let ipcServer = IPCServer(
                audioPlayer: audioPlayer,
                playlistManager: playlistManager,
                playlistsStore: playlistsStore,
                playbackWeights: playbackWeights
            )

        let audioRouteMonitor = AudioRouteMonitor(
            onHeadphonesDisconnected: { [weak audioPlayer] in
                DispatchQueue.main.async {
                    guard let ap = audioPlayer else { return }
                    ap.isHeadphoneOutput = false
                    ap.shouldConfirmSpeakerPlayback = true
                    if ap.isPlaybackRequested || ap.isPlaying {
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
                    if ap.shouldAutoResumeAfterRoute {
                        ap.shouldAutoResumeAfterRoute = false
                        if !ap.isPlaybackRequested, ap.canTogglePlayback {
                            ap.resume()
                        }
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

        let externalVolumeCoordinator = ExternalVolumeCoordinator()
        externalVolumeCoordinator.onEvent = {
            [weak playlistManager, weak audioPlayer, weak playlistsStore] event in
            switch event {
            case .willUnmount(let volume):
                guard let volume else { return }
                if let audioPlayer,
                   audioPlayer.playbackTargetIsAffected(by: volume) {
                    if audioPlayer.persistPlaybackState,
                       let playlistManager,
                       let targetURL = audioPlayer.playbackTargetURL {
                        _ = playbackSessionStore.mergeInstalledTrack(
                            playlistManager.playbackSessionTrackIdentity(for: targetURL)
                        )
                        let seconds = audioPlayer.captureInstalledPlaybackTime()
                        let milliseconds = seconds.isFinite && seconds > 0
                            ? Int64(min(Double(Int64.max), seconds * 1_000).rounded())
                            : 0
                        _ = playbackSessionStore.mergePosition(milliseconds: milliseconds)
                    }
                }
                _ = audioPlayer?.detachPlaybackResourceForUnmount(
                    volumeURL: volume.url
                )
                Task {
                    _ = await playlistManager?.handleExternalVolumeWillUnmount(volume)
                }
            case .topologyChanged(let diff):
                Task {
                    await playlistManager?.refreshExternalMediaAvailability(
                        playlistsStore: playlistsStore,
                        topologyGeneration: diff.snapshot.generation
                    )
                }
            case .refreshFailed(_, let message):
                PersistenceLogger.log("刷新外接磁盘状态失败：\(message)")
            }
        }
        externalVolumeCoordinator.start()

	        self.audioPlayer = audioPlayer
	        self.playlistManager = playlistManager
	        self.playlistsStore = playlistsStore
	        self.playbackCoordinator = playbackCoordinator
	        self.ipcServer = ipcServer
	        self.audioRouteMonitor = audioRouteMonitor
	        self.externalVolumeCoordinator = externalVolumeCoordinator
	        self.startupFailureMessage = nil
	        self.startupRecovery = nil

        // 连接 AppDelegate，使其可以接管 Finder/Dock 打开的临时文件
        appDelegate.configure(
            audioPlayer: audioPlayer,
            playlistManager: playlistManager,
            playlistsStore: playlistsStore,
            singleInstanceCoordinator: coordinator,
            playbackWeights: playbackWeights,
            playbackSessionStore: playbackSessionStore
        )
        if !promotedPrimaryOpenURLs.isEmpty {
            PersistenceLogger.log(
                "单实例接管完成，已向主进程打开管线交付 \(promotedPrimaryOpenURLs.count) 个路径"
            )
        }
        _ = appDelegate.registerTerminationLifecycleHook(
            .init {
                [weak ipcServer,
                 weak audioRouteMonitor,
                 weak externalVolumeCoordinator,
                 weak playbackCoordinator,
                 weak audioPlayer] context in
                ipcServer?.stopForTermination(generation: context.generation)
                audioRouteMonitor?.stopForTermination(generation: context.generation)
                MainActor.assumeIsolated {
                    externalVolumeCoordinator?.stopForTermination(
                        generation: context.generation
                    )
                    playbackCoordinator?.stopForTermination(
                        generation: context.generation
                    )
                    audioPlayer?.stopForTermination(generation: context.generation)
                }
            }
        )

        // Run format detection tests in background to avoid blocking app startup/IPC.
        #if DEBUG
        Task.detached(priority: .background) {
            FormatDetectionTest.runTests()
            FormatDetectionTest.testSpecificScenarios()
        }
        #endif

        Task.detached(priority: .background) {
            await RegressionTests.runIfEnabled()
        }

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
            Group {
                if let audioPlayer, let playlistManager, let playlistsStore {
	                RootView(
                        audioPlayer: audioPlayer,
                        playlistManager: playlistManager,
                        playlistsStore: playlistsStore
                    )
                } else if let startupFailureMessage {
                    StartupPersistenceFailureView(
                        message: startupFailureMessage,
                        recoverStartingEmpty: startupRecovery
                    )
                } else {
                    EmptyView()
                }
            }
            .frame(minWidth: 600, minHeight: 400)
	        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            if let audioPlayer, let playlistManager {
	            MusicPlayerCommands(audioPlayer: audioPlayer, playlistManager: playlistManager)
            }
        }
    }

    private static func scheduleSecondaryTermination() {
        // Keep the forwarding process alive briefly so the idempotent handoff
        // retry can bridge the primary process' observer-installation window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct StartupPersistenceFailureView: View {
    let message: String
    let recoverStartingEmpty: (() -> Bool)?
    @State private var showsRecoveryConfirmation = false
    @State private var recoverySucceeded = false
    @State private var recoveryFailed = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.orange)
            Text("音乐库处于保护模式")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text(recoverySucceeded
                ? "已建立新的空音乐库，损坏数据库仍保留为诊断副本。请退出后重新打开。"
                : "原始数据没有被覆盖。你可以保留数据库供诊断，或明确重建一个空音乐库。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                if recoverStartingEmpty != nil, !recoverySucceeded {
                    Button("保留诊断并重建空音乐库") {
                        showsRecoveryConfirmation = true
                    }
                }
                Button(recoverySucceeded ? "退出后重新打开" : "退出 MusicPlayer") {
                    AppTerminator.requestQuit()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
            if recoveryFailed {
                Text("重建失败，原数据库仍保持不变。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
        .alert("重建空音乐库？", isPresented: $showsRecoveryConfirmation) {
            Button("取消", role: .cancel) { }
            Button("保留诊断并重建", role: .destructive) {
                recoverySucceeded = recoverStartingEmpty?() == true
                recoveryFailed = !recoverySucceeded
            }
        } message: {
            Text("当前损坏数据库会被归档，不会删除；随后创建一个经过完整性校验的空音乐库。")
        }
    }
}
