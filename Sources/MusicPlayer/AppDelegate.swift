import AppKit
import AVFoundation
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var audioPlayer: AudioPlayer?
    private weak var playlistManager: PlaylistManager?
    private weak var playlistsStore: PlaylistsStore?
    private var singleInstanceCoordinator: SingleInstanceCoordinator?
    private var isPrimaryInstance = false
    private var keyEventMonitor: Any?
    private var activityEventMonitor: Any?
    private var openRequestTask: Task<Void, Never>?
    private var openRequestGeneration: UInt64 = 0

    func configure(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        playlistsStore: PlaylistsStore,
        singleInstanceCoordinator: SingleInstanceCoordinator
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
        self.singleInstanceCoordinator = singleInstanceCoordinator
        isPrimaryInstance = true
        singleInstanceCoordinator.setOpenRequestHandler { [weak self] urls in
            _ = self?.routeOpenRequest(urls)
        }
    }

    func configureSecondary(singleInstanceCoordinator: SingleInstanceCoordinator) {
        self.singleInstanceCoordinator = singleInstanceCoordinator
        isPrimaryInstance = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 本地鼠标/滚轮监听：用于判定“用户空闲”（无操作一段时间后可做后台任务）
        activityEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel
            ]
        ) { [weak self] event in
            if let ap = self?.audioPlayer {
                ap.recordUserInteraction(throttleSeconds: 0.5)
            }
            return event
        }

        // 本地按键监听：仅在未编辑文本时拦截空格/回车进行播放/暂停
	        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
	            guard let self = self, let ap = self.audioPlayer else { return event }
	            ap.recordUserInteraction(throttleSeconds: 0.25)

	            // Command+Q：无论任何弹窗/子窗口/输入焦点都允许强制退出（符合 macOS 习惯）
	            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
	            if flags.contains(.command),
	               !flags.contains(.control),
	               !flags.contains(.option),
	               !flags.contains(.shift),
	               event.charactersIgnoringModifiers?.lowercased() == "q" {
	                AppTerminator.requestQuit()
	                return nil
	            }

	            // Command+F：聚焦当前上下文的搜索框（由 AppFocusState 决定目标）
	            if flags.contains(.command),
	               !flags.contains(.control),
	               !flags.contains(.option),
	               !flags.contains(.shift),
	               event.charactersIgnoringModifiers?.lowercased() == "f" {
	                NotificationCenter.default.post(name: .focusSearchField, object: nil)
	                return nil
	            }

	            // ESC：从文本输入（尤其是搜索框）退出焦点，方便中文输入法/快捷键切换
	            if event.keyCode == 53, let window = NSApp.keyWindow, let responder = window.firstResponder as? NSTextView {
	                if responder.isEditable || responder.isFieldEditor || responder.hasMarkedText() {
	                    window.makeFirstResponder(nil)
	                    AppFocusState.shared.isSearchFocused = false
                    return nil
                }
            }

            // 允许所有文本输入（含输入法候选确认）优先消费空格/回车，避免与播放快捷键冲突
            if self.shouldLetTextInputHandle(event: event) {
                return event
            }

	            // Ctrl+F：聚焦当前上下文搜索框
	            if flags.contains(.control),
	               !flags.contains(.command),
	               !flags.contains(.option),
	               !flags.contains(.shift),
	               event.charactersIgnoringModifiers?.lowercased() == "f" {
	                NotificationCenter.default.post(name: .focusSearchField, object: nil)
	                return nil
	            }

            // 空格（49）/ 回车（36）/ 小键盘回车（76）：切换播放/暂停
            let keyCode = event.keyCode
            if keyCode == 49 || keyCode == 36 || keyCode == 76 {
                if ap.canTogglePlayback {
                    ap.togglePlayPause()
                }
                // 吞掉事件，避免系统“嘟”一声或触发其它默认快捷键
                return nil
            }
            return event
        }

        // 监听系统睡眠/唤醒，唤醒后不自动续播
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let ap = self?.audioPlayer else { return }
            // 明确暂停，确保不会凭底层自动恢复继续播放
            if ap.isPlaybackRequested || ap.isPlaying { ap.pause() }
            // 标记睡眠状态并清理自动续播意图
            ap.isSystemSleeping = true
            ap.shouldAutoResumeAfterRoute = false
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let ap = self?.audioPlayer else { return }
            // 取消睡眠标记，并在唤醒后 5 秒内禁止任何自动续播
            ap.isSystemSleeping = false
            ap.suppressAutoResumeOnce = true
            ap.disallowAutoResumeUntil = Date().addingTimeInterval(5)
            ap.shouldAutoResumeAfterRoute = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        openRequestGeneration &+= 1
        openRequestTask?.cancel()
        openRequestTask = nil
        guard isPrimaryInstance else {
            removeEventMonitors()
            return
        }
        playlistManager?.prepareForImmediateTermination()
        playlistsStore?.prepareForImmediateTermination()
        audioPlayer?.cancelVolumeNormalizationPreanalysis()
        if audioPlayer?.flushPlaybackStatePersistence() == false {
            PersistenceLogger.log("播放状态退出 flush 失败")
        }
        _ = audioPlayer?.flushUserPreferencesPersistence()
        if let result = playlistManager?.flushPlaylistPersistence(timeout: 1.25),
           !result.isDurable {
            PersistenceLogger.log("队列退出 flush 未持久：\(result.outcome)")
        }
        if playlistsStore?.flushPersistence(timeout: 1.25) == false {
            PersistenceLogger.log("歌单退出 flush 未持久或超过时限")
        }
        Self.flushNonCriticalStores(audioPlayer: audioPlayer, timeout: 1.5)
        removeEventMonitors()
    }

    private func removeEventMonitors() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = activityEventMonitor {
            NSEvent.removeMonitor(monitor)
            activityEventMonitor = nil
        }
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        // `terminate(_:)` waits in a nested AppKit run loop after `.terminateLater`.
        // A MainActor task scheduled from here may therefore never run, leaving
        // Cmd+Q permanently stuck. Cancel unfinished imports immediately; the
        // committed queue/playlists and caches are synchronously flushed from
        // `applicationWillTerminate` before AppKit exits the process.
        openRequestGeneration &+= 1
        openRequestTask?.cancel()
        openRequestTask = nil
        if isPrimaryInstance {
            playlistManager?.prepareForImmediateTermination()
            playlistsStore?.prepareForImmediateTermination()
            audioPlayer?.cancelVolumeNormalizationPreanalysis()
        }
        return .terminateNow
    }

    // Finder/Dock 图标打开单个文件
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        routeOpenRequest([URL(fileURLWithPath: filename)])
    }

    // Finder/Dock 图标一次打开多个文件
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let didAcceptRequest = routeOpenRequest(
            filenames.lazy.map { URL(fileURLWithPath: $0) }
        )
        sender.reply(toOpenOrPrint: Self.openFilesReply(didAcceptRequest: didAcceptRequest))
    }

    // 通用 URL 打开（例如从其他应用拖到 Dock）
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = routeOpenRequest(urls)
    }

    static func openFilesReply(didAcceptRequest: Bool) -> NSApplication.DelegateReply {
        didAcceptRequest ? .success : .failure
    }

    @discardableResult
    private func routeOpenRequest<URLs: Sequence>(_ urls: URLs) -> Bool
    where URLs.Element == URL {
        guard let target = Self.firstValidExternalAudioURL(in: urls) else {
            return false
        }
        guard isPrimaryInstance else {
            guard let singleInstanceCoordinator else { return false }
            singleInstanceCoordinator.forwardOpenRequest([target])
            return true
        }
        return openEphemeral(url: target)
    }

    @discardableResult
    private func openEphemeral(url target: URL) -> Bool {
        guard let audioPlayer = audioPlayer else { return false }

        // 标记本次启动（或本次外部打开）应跳过“恢复上次播放”
        audioPlayer.markSkipRestoreThisLaunch()

        openRequestGeneration &+= 1
        let generation = openRequestGeneration
        openRequestTask?.cancel()
        openRequestTask = Task { [weak self, weak audioPlayer] in
            guard let self, let audioPlayer, !Task.isCancelled else { return }
            let metadata: AudioMetadata
            if let playlistManager = self.playlistManager {
                metadata = await playlistManager.loadFreshMetadata(from: target)
            } else {
                metadata = await AudioMetadata.load(
                    from: AVURLAsset(url: target),
                    includeArtwork: false
                )
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.isPrimaryInstance,
                      self.openRequestGeneration == generation,
                      !Task.isCancelled else { return }
                // 仅播放，不加入/不保存到播放列表
                audioPlayer.play(AudioFile(url: target, metadata: metadata), persist: false)
                self.openRequestTask = nil
            }
            // 确保主窗口置顶展示（单窗口应用，避免“找不到播放控制”的困惑）
            await MainActor.run {
                guard self.openRequestGeneration == generation else { return }
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first {
                    win.makeKeyAndOrderFront(nil)
                }
            }
        }
        return true
    }

    /// 检测当前事件是否来自文本输入环境（含输入法组合状态），若是则不拦截快捷键
    private func shouldLetTextInputHandle(event: NSEvent) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }

        // NSTextView 作为 field editor 或普通编辑器时，交给它处理空格/回车
        if let textView = responder as? NSTextView {
            if textView.isEditable || textView.isFieldEditor {
                return true
            }
            if textView.hasMarkedText() { // 输入法正在组合文字
                return true
            }
        }

        // 其他实现了 NSTextInputClient 的控件（如自定义文本输入）
        if let client = responder as? NSTextInputClient, client.hasMarkedText() {
            return true
        }

        return false
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        let exts = [
            "mp3", "m4a", "aac",
            "wav", "aif", "aiff", "aifc", "caf",
            "flac"
        ]
        return exts.contains(url.pathExtension.lowercased())
    }

    static let maximumExternalOpenPaths = 128
    static let maximumExternalOpenTotalPathBytes = 256 * 1_024

    static func firstValidExternalAudioURL<URLs: Sequence>(in urls: URLs) -> URL?
    where URLs.Element == URL {
        var inspectedCount = 0
        var aggregatePathBytes = 0
        for url in urls {
            inspectedCount += 1
            guard inspectedCount <= maximumExternalOpenPaths else { return nil }
            let byteCount = url.path(percentEncoded: false).utf8.count
            guard byteCount <= maximumExternalOpenTotalPathBytes - aggregatePathBytes else {
                return nil
            }
            aggregatePathBytes += byteCount
            if let valid = validExternalAudioURL(url) {
                return valid
            }
        }
        return nil
    }

    static func isSafeExternalPath(
        _ path: String,
        maximumBytes: Int = Int(PATH_MAX)
    ) -> Bool {
        let byteCount = path.utf8.count
        return maximumBytes > 1
            && path.hasPrefix("/")
            && byteCount > 0
            && byteCount < maximumBytes
            && !path.utf8.contains(0)
    }

    static func isSafeExternalFile(
        mode: mode_t,
        ownerUID _: uid_t,
        isReadable: Bool
    ) -> Bool {
        isReadable && (mode & S_IFMT) == S_IFREG
    }

    static func validExternalAudioURL(_ input: URL) -> URL? {
        guard input.isFileURL,
              isSafeExternalPath(input.path(percentEncoded: false)) else { return nil }
        let url = input.standardizedFileURL
        guard isAudioFile(url),
              isSafeExternalPath(url.path(percentEncoded: false)) else { return nil }
        let isSafe = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            var pathInfo = stat()
            guard lstat(path, &pathInfo) == 0,
                  isSafeExternalFile(
                    mode: pathInfo.st_mode,
                    ownerUID: pathInfo.st_uid,
                    isReadable: true
                  ) else { return false }

            let descriptor = Darwin.open(
                path,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { return false }
            defer { Darwin.close(descriptor) }

            var openedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0,
                  pathInfo.st_dev == openedInfo.st_dev,
                  pathInfo.st_ino == openedInfo.st_ino else { return false }
            return isSafeExternalFile(
                mode: openedInfo.st_mode,
                ownerUID: openedInfo.st_uid,
                isReadable: true
            )
        }
        guard isSafe else { return nil }
        return url
    }

    // 重新激活应用（例如所有窗口被关闭后点击 Dock 图标）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let win = sender.windows.first {
                win.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return false
    }

    // 当关闭最后一个窗口时，如果处于临时播放，停止播放以免“无窗口仍在播”
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        openRequestGeneration &+= 1
        openRequestTask?.cancel()
        openRequestTask = nil
        guard isPrimaryInstance else { return false }
        if let ap = audioPlayer, ap.persistPlaybackState == false {
            ap.stopAndClearCurrent(clearLastPlayed: false)
        }
        if audioPlayer?.flushPlaybackStatePersistence() == false {
            PersistenceLogger.log("Cmd+W 播放状态 flush 失败")
        }
        _ = audioPlayer?.flushUserPreferencesPersistence()
        if let result = playlistManager?.flushPlaylistPersistence(timeout: 0.75),
           !result.isDurable {
            PersistenceLogger.log("Cmd+W 队列 flush 未持久：\(result.outcome)")
        }
        if playlistsStore?.flushPersistence(timeout: 0.75) == false {
            PersistenceLogger.log("Cmd+W 歌单 flush 未持久或超过时限")
        }
        return false
    }

    private static func flushNonCriticalStores(
        audioPlayer: AudioPlayer?,
        timeout: TimeInterval
    ) {
        let group = DispatchGroup()
        if let audioPlayer {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                if case .failed(let message) = audioPlayer.flushVolumeCachePersistence() {
                    PersistenceLogger.log("音量分析缓存退出 flush 失败：\(message)")
                }
                audioPlayer.flushImmersivePlaybackCachePersistence(timeout: timeout)
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            let result = PlaybackWeights.shared.flushPersistence()
            if !result.isDurable {
                PersistenceLogger.log("权重退出 flush 未持久：\(result.outcome)")
            }
        }
        group.enter()
        Task.detached(priority: .utility) {
            defer { group.leave() }
            _ = await MetadataCache.shared.flushPersistence()
        }
        group.enter()
        Task.detached(priority: .utility) {
            defer { group.leave() }
            _ = await DurationCache.shared.flushPersistence()
        }
        _ = group.wait(timeout: .now() + max(0, timeout))
    }
}
