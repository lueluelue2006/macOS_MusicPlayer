import AppKit
import AVFoundation
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let criticalTerminationTimeout: TimeInterval = 0.75

    struct TerminationDeadline: Equatable, Sendable {
        let startedAt: TimeInterval
        let deadline: TimeInterval

        init(startedAt: TimeInterval, timeout: TimeInterval) {
            let safeStart = startedAt.isFinite ? startedAt : 0
            let safeTimeout = timeout.isFinite ? max(0, timeout) : 0
            self.startedAt = safeStart
            self.deadline = safeStart + safeTimeout
        }

        var budget: TimeInterval {
            max(0, deadline - startedAt)
        }

        func remaining(at time: TimeInterval) -> TimeInterval {
            guard time.isFinite else { return 0 }
            return max(0, deadline - max(startedAt, time))
        }
    }

    struct TerminationLifecycleContext: Equatable, Sendable {
        let generation: UInt64
        let deadline: TerminationDeadline

        func remaining(at time: TimeInterval) -> TimeInterval {
            deadline.remaining(at: time)
        }
    }

    enum CriticalPersistenceStep: String, CaseIterable, Hashable, Sendable {
        case libraryQueue
        case playlists
        case playbackWeights
        case playbackState
        case typedPreferences
    }

    enum CriticalPersistenceOutcome: Equatable, Sendable {
        case durable
        case failed
        case timedOut
        case unavailable
        case skippedNoRemainingTime
        case skippedCoalesced
    }

    struct TerminationStoreIdentity: Hashable, @unchecked Sendable {
        private let identifier: ObjectIdentifier

        init(_ store: AnyObject) {
            identifier = ObjectIdentifier(store)
        }
    }

    struct CriticalPersistenceOperation {
        let step: CriticalPersistenceStep
        /// Set this only when one operation drains the entire durability unit;
        /// later operations with the same identity are then redundant.
        let coalescingIdentity: TerminationStoreIdentity?
        let perform: (TimeInterval) throws -> CriticalPersistenceOutcome

        init(
            step: CriticalPersistenceStep,
            coalescingIdentity: TerminationStoreIdentity? = nil,
            perform: @escaping (TimeInterval) throws -> CriticalPersistenceOutcome
        ) {
            self.step = step
            self.coalescingIdentity = coalescingIdentity
            self.perform = perform
        }
    }

    struct CriticalPersistenceStepReport: Equatable, Sendable {
        let step: CriticalPersistenceStep
        let offeredTimeout: TimeInterval
        let elapsed: TimeInterval
        let outcome: CriticalPersistenceOutcome
    }

    struct CriticalTerminationReport: Equatable, Sendable {
        let budget: TimeInterval
        /// Time already consumed before the first persistence operation. In the
        /// app termination path this includes mutation freeze and snapshot prep.
        let preparationElapsed: TimeInterval
        /// Time spent executing persistence operations and final cleanup.
        let barrierElapsed: TimeInterval
        /// Total wall-clock time measured from `TerminationDeadline.startedAt`.
        let elapsed: TimeInterval
        let steps: [CriticalPersistenceStepReport]
        let didRemoveEventMonitors: Bool

        var didMeetDeadline: Bool {
            elapsed <= budget
        }

        var isFullyDurable: Bool {
            didMeetDeadline && steps.allSatisfy {
                $0.outcome == .durable
                    || $0.outcome == .skippedCoalesced
            }
        }
    }

    /// Hooks let long-lived services join one termination generation without
    /// making AppDelegate depend on each concrete service. `stop` must only
    /// publish cancellation/freeze state. `prepareCriticalOperations` receives
    /// the real remaining budget and should return operations over already
    /// captured immutable snapshots; the executor reports an overrun honestly
    /// but cannot preempt a synchronous hook or operation.
    struct TerminationLifecycleHook {
        let stop: (TerminationLifecycleContext) -> Void
        let prepareCriticalOperations: (
            _ context: TerminationLifecycleContext,
            _ remaining: TimeInterval
        ) -> [CriticalPersistenceOperation]

        init(
            stop: @escaping (TerminationLifecycleContext) -> Void,
            prepareCriticalOperations: @escaping (
                _ context: TerminationLifecycleContext,
                _ remaining: TimeInterval
            ) -> [CriticalPersistenceOperation] = { _, _ in [] }
        ) {
            self.stop = stop
            self.prepareCriticalOperations = prepareCriticalOperations
        }
    }

    struct TerminationLifecycleHookToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct RegisteredTerminationLifecycleHook {
        let token: TerminationLifecycleHookToken
        let hook: TerminationLifecycleHook
    }

    private final class TerminationResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?

        func store(_ value: Bool) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// AudioPlayer is frozen and paused before these references cross to the
    /// bounded persistence worker. Its two lifecycle methods then touch only
    /// lock-protected persistence stores and the already-paused playback state.
    private struct FrozenAudioPlayerReference: @unchecked Sendable {
        let value: AudioPlayer
    }

    private weak var audioPlayer: AudioPlayer?
    private weak var playlistManager: PlaylistManager?
    private weak var playlistsStore: PlaylistsStore?
    private weak var playbackWeights: PlaybackWeights?
    private weak var playbackSessionStore: PlaybackSessionStore?
    private var singleInstanceCoordinator: SingleInstanceCoordinator?
    private(set) var isPrimaryInstance = false
    private var keyEventMonitor: Any?
    private var activityEventMonitor: Any?
    private var openRequestTask: Task<Void, Never>?
    private var openRequestGeneration: UInt64 = 0
    private(set) var isTerminationMutationFrozen = false
    private(set) var lastTerminationReport: CriticalTerminationReport?
    private(set) var lastWindowCloseReport: CriticalTerminationReport?
    private var terminationGeneration: UInt64 = 0
    private(set) var terminationContext: TerminationLifecycleContext?
    private var terminationLifecycleHooks: [RegisteredTerminationLifecycleHook] = []
    private var preparedTerminationOperations: [CriticalPersistenceOperation] = []
    private var queueTerminationSnapshotPreparation:
        PlaylistManager.QueueTerminationSnapshotPreparation?

    func configure(
        audioPlayer: AudioPlayer,
        playlistManager: PlaylistManager,
        playlistsStore: PlaylistsStore,
        singleInstanceCoordinator: SingleInstanceCoordinator,
        playbackWeights: PlaybackWeights = .shared,
        playbackSessionStore: PlaybackSessionStore? = nil
    ) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
        self.playbackWeights = playbackWeights
        self.playbackSessionStore = playbackSessionStore
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

    /// A process that owns the writer lock but could not build its stores is
    /// still the primary instance. Keeping this state distinct from a forwarding
    /// secondary prevents open requests from being reflected back to itself.
    func configureFailedPrimary(singleInstanceCoordinator: SingleInstanceCoordinator) {
        self.singleInstanceCoordinator = singleInstanceCoordinator
        isPrimaryInstance = true
        singleInstanceCoordinator.setOpenRequestHandler { _ in
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @discardableResult
    func registerTerminationLifecycleHook(
        _ hook: TerminationLifecycleHook
    ) -> TerminationLifecycleHookToken {
        let token = TerminationLifecycleHookToken(id: UUID())
        guard !isTerminationMutationFrozen else { return token }
        terminationLifecycleHooks.append(
            RegisteredTerminationLifecycleHook(token: token, hook: hook)
        )
        return token
    }

    func removeTerminationLifecycleHook(_ token: TerminationLifecycleHookToken) {
        guard !isTerminationMutationFrozen else { return }
        terminationLifecycleHooks.removeAll { $0.token == token }
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
            guard self?.isTerminationMutationFrozen == false else { return event }
            if let ap = self?.audioPlayer {
                ap.recordUserInteraction(throttleSeconds: 0.5)
            }
            return event
        }

        // 本地按键监听：仅在未编辑文本时拦截空格/回车进行播放/暂停
	        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
	            guard let self = self,
                      !self.isTerminationMutationFrozen,
                      let ap = self.audioPlayer else { return event }
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
        let context = freezeMutationsForTermination()
        let operations = isPrimaryInstance
            ? preparedTerminationOperations + criticalPersistenceOperations()
            : []
        let report = Self.runCriticalTerminationBarrier(
            deadline: context.deadline,
            operations: operations,
            cleanup: { [weak self] in self?.removeEventMonitors() },
            didRemoveEventMonitors: true
        )
        lastTerminationReport = report
        Self.logCriticalTerminationFailures(report)
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
        // committed critical state is synchronously flushed from
        // `applicationWillTerminate` before AppKit exits the process.
        _ = freezeMutationsForTermination()
        return .terminateNow
    }

    @discardableResult
    private func freezeMutationsForTermination() -> TerminationLifecycleContext {
        let context = beginTerminationContextIfNeeded()
        guard !isTerminationMutationFrozen else { return context }
        // Publish the freeze before cancelling work so every callback that
        // races this method observes the terminal state first.
        isTerminationMutationFrozen = true
        openRequestGeneration &+= 1
        openRequestTask?.cancel()
        openRequestTask = nil

        // Capture the authoritative player position before any lifecycle hook
        // pauses the player or invalidates an in-flight playback generation.
        if isPrimaryInstance {
            MainActor.assumeIsolated {
                capturePlaybackSessionSnapshot()
            }
        }

        // Stop hooks are deliberately generation-based and non-blocking by
        // contract. Their execution time is still charged to the same deadline.
        for registration in terminationLifecycleHooks {
            registration.hook.stop(context)
        }
        guard isPrimaryInstance else { return context }

        // AppKit invokes both termination callbacks on its main thread. The
        // assertion keeps actor-isolated stores synchronous, which is required
        // for `.terminateNow`, without dispatching their state to a worker.
        MainActor.assumeIsolated {
            playlistManager?.prepareForImmediateTermination(
                generation: context.generation
            )
            playlistsStore?.prepareForImmediateTermination()
            if let playlistManager {
                queueTerminationSnapshotPreparation =
                    playlistManager.prepareTerminationQueueSnapshot(
                        remaining: context.remaining(at: Self.monotonicNow()),
                        generation: context.generation
                    )
            }
        }
        if let audioPlayer {
            audioPlayer.pause()
            audioPlayer.cancelVolumeNormalizationPreanalysis()
        }

        // A hook may build a bounded immutable snapshot and return the operation
        // that commits it. Hook operations take precedence over legacy built-ins
        // with the same step, enabling incremental main-line migration.
        for registration in terminationLifecycleHooks {
            let remaining = context.remaining(at: Self.monotonicNow())
            guard remaining > 0 else { break }
            preparedTerminationOperations.append(
                contentsOf: registration.hook.prepareCriticalOperations(
                    context,
                    remaining
                )
            )
        }
        return context
    }

    private func beginTerminationContextIfNeeded() -> TerminationLifecycleContext {
        if let terminationContext { return terminationContext }
        terminationGeneration &+= 1
        let context = TerminationLifecycleContext(
            generation: terminationGeneration,
            deadline: TerminationDeadline(
                startedAt: Self.monotonicNow(),
                timeout: Self.criticalTerminationTimeout
            )
        )
        terminationContext = context
        return context
    }

    private static func monotonicNow() -> TimeInterval {
        let value = ProcessInfo.processInfo.systemUptime
        return value.isFinite ? value : 0
    }

    @MainActor
    private func capturePlaybackSessionSnapshot() {
        guard let playbackSessionStore,
              let audioPlayer,
              audioPlayer.persistPlaybackState,
              let currentURL = audioPlayer.currentFile?.url else { return }
        if let playlistManager {
            _ = playbackSessionStore.mergeInstalledTrack(
                playlistManager.playbackSessionTrackIdentity(for: currentURL)
            )
        }
        let seconds = audioPlayer.captureInstalledPlaybackTime()
        let milliseconds: Int64 = seconds.isFinite && seconds > 0
            ? Int64(min(Double(Int64.max), seconds * 1_000).rounded())
            : 0
        _ = playbackSessionStore.mergePosition(milliseconds: milliseconds)
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
        guard !isTerminationMutationFrozen else { return false }
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
                      !self.isTerminationMutationFrozen,
                      self.openRequestGeneration == generation,
                      !Task.isCancelled else { return }
                // 仅播放，不加入/不保存到播放列表
                audioPlayer.play(AudioFile(url: target, metadata: metadata), persist: false)
                self.openRequestTask = nil
            }
            // 确保主窗口置顶展示（单窗口应用，避免“找不到播放控制”的困惑）
            await MainActor.run {
                guard !self.isTerminationMutationFrozen,
                      self.openRequestGeneration == generation else { return }
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
        let deadline = TerminationDeadline(
            startedAt: Self.monotonicNow(),
            timeout: Self.criticalTerminationTimeout
        )
        if let ap = audioPlayer, ap.persistPlaybackState == false {
            ap.stopAndClearCurrent(clearLastPlayed: false)
        }
        MainActor.assumeIsolated {
            capturePlaybackSessionSnapshot()
        }
        let report = Self.runCriticalTerminationBarrier(
            deadline: deadline,
            operations: criticalPersistenceOperations(),
            cleanup: {},
            didRemoveEventMonitors: false
        )
        lastWindowCloseReport = report
        Self.logCriticalPersistenceFailures(report, context: "Cmd+W")
        return false
    }

    static func runCriticalTerminationBarrier(
        timeout: TimeInterval = criticalTerminationTimeout,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        operations: [CriticalPersistenceOperation],
        cleanup: () -> Void,
        didRemoveEventMonitors: Bool = true
    ) -> CriticalTerminationReport {
        let rawStart = now()
        let start = rawStart.isFinite ? rawStart : 0
        return runCriticalTerminationBarrier(
            deadline: TerminationDeadline(startedAt: start, timeout: timeout),
            now: now,
            operations: operations,
            cleanup: cleanup,
            didRemoveEventMonitors: didRemoveEventMonitors
        )
    }

    /// Runs deadline-aware operations in deterministic step order. A synchronous
    /// operation cannot be safely preempted, so an overrun is measured after it
    /// returns, reported as `.timedOut`, and makes `didMeetDeadline` false. This
    /// is a budget contract, not a false hard-cancellation promise.
    static func runCriticalTerminationBarrier(
        deadline: TerminationDeadline,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        operations: [CriticalPersistenceOperation],
        cleanup: () -> Void,
        didRemoveEventMonitors: Bool = true
    ) -> CriticalTerminationReport {
        let rawBarrierStart = now()
        let barrierStart = rawBarrierStart.isFinite
            ? max(deadline.startedAt, rawBarrierStart)
            : deadline.startedAt
        var currentTime = barrierStart
        var attemptedStores = Set<TerminationStoreIdentity>()
        var stepReports: [CriticalPersistenceStepReport] = []
        stepReports.reserveCapacity(operations.count)

        let operationByStep = Dictionary(
            operations.map { ($0.step, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for step in CriticalPersistenceStep.allCases {
            guard let operation = operationByStep[step] else { continue }

            if let identity = operation.coalescingIdentity,
               !attemptedStores.insert(identity).inserted {
                stepReports.append(
                    CriticalPersistenceStepReport(
                        step: step,
                        offeredTimeout: 0,
                        elapsed: 0,
                        outcome: .skippedCoalesced
                    )
                )
                continue
            }

            let rawBefore = now()
            let before = rawBefore.isFinite ? max(currentTime, rawBefore) : currentTime
            currentTime = before
            let remaining = deadline.remaining(at: before)
            guard remaining > 0 else {
                stepReports.append(
                    CriticalPersistenceStepReport(
                        step: step,
                        offeredTimeout: 0,
                        elapsed: 0,
                        outcome: .skippedNoRemainingTime
                    )
                )
                continue
            }

            let attemptedOutcome: CriticalPersistenceOutcome
            do {
                attemptedOutcome = try operation.perform(remaining)
            } catch {
                attemptedOutcome = .failed
            }

            let rawAfter = now()
            let after = rawAfter.isFinite ? max(before, rawAfter) : before
            currentTime = after
            let elapsed = max(0, after - before)
            let outcome = after > deadline.deadline ? .timedOut : attemptedOutcome
            stepReports.append(
                CriticalPersistenceStepReport(
                    step: step,
                    offeredTimeout: remaining,
                    elapsed: elapsed,
                    outcome: outcome
                )
            )
        }

        cleanup()
        let rawFinished = now()
        let finished = rawFinished.isFinite ? max(currentTime, rawFinished) : currentTime
        let preparationElapsed = max(0, barrierStart - deadline.startedAt)
        let barrierElapsed = max(0, finished - barrierStart)
        let totalElapsed = max(0, finished - deadline.startedAt)
        return CriticalTerminationReport(
            budget: deadline.budget,
            preparationElapsed: preparationElapsed,
            barrierElapsed: barrierElapsed,
            elapsed: totalElapsed,
            steps: stepReports,
            didRemoveEventMonitors: didRemoveEventMonitors
        )
    }

    private func criticalPersistenceOperations() -> [CriticalPersistenceOperation] {
        let weights = playbackWeights
        let playbackSessionStore = playbackSessionStore
        let queuePreparation = queueTerminationSnapshotPreparation
        return [
            CriticalPersistenceOperation(step: .libraryQueue) { [weak playlistManager] remaining in
                guard let playlistManager else { return .unavailable }
                if let queuePreparation, !queuePreparation.canAttemptFlush {
                    return queuePreparation.outcome == .timedOut ? .timedOut : .failed
                }
                switch playlistManager.flushPlaylistPersistence(timeout: remaining).outcome {
                case .durable:
                    return .durable
                case .timedOut:
                    return .timedOut
                case .skippedBeforeRestore, .protectedReadOnly, .failed:
                    return .failed
                }
            },
            CriticalPersistenceOperation(step: .playlists) { [weak playlistsStore] remaining in
                guard let playlistsStore else { return .unavailable }
                return MainActor.assumeIsolated {
                    playlistsStore.flushPersistence(timeout: remaining) ? .durable : .failed
                }
            },
            CriticalPersistenceOperation(step: .playbackWeights) { remaining in
                guard let weights else { return .unavailable }
                return Self.runBoundedPersistenceOperation(timeout: remaining) {
                    weights.flushPersistence().isDurable
                }
            },
            CriticalPersistenceOperation(step: .playbackState) { [weak audioPlayer] remaining in
                if let playbackSessionStore {
                    switch playbackSessionStore.flush(timeout: remaining).outcome {
                    case .durable, .alreadyCurrent:
                        return .durable
                    case .timedOut:
                        return .timedOut
                    case .failed, .rejectedReadOnly:
                        return .failed
                    }
                }
                guard let audioPlayer else { return .unavailable }
                let frozenPlayer = FrozenAudioPlayerReference(value: audioPlayer)
                return Self.runBoundedPersistenceOperation(timeout: remaining) {
                    frozenPlayer.value.flushPlaybackStatePersistence()
                }
            },
            CriticalPersistenceOperation(step: .typedPreferences) { [weak audioPlayer] remaining in
                guard let audioPlayer else { return .unavailable }
                let frozenPlayer = FrozenAudioPlayerReference(value: audioPlayer)
                return Self.runBoundedPersistenceOperation(timeout: remaining) {
                    switch frozenPlayer.value.flushUserPreferencesPersistence() {
                    case .success:
                        return true
                    case .failure:
                        return false
                    }
                }
            },
        ]
    }

    private static func runBoundedPersistenceOperation(
        timeout: TimeInterval,
        operation: @escaping @Sendable () -> Bool
    ) -> CriticalPersistenceOutcome {
        guard timeout.isFinite, timeout > 0 else { return .timedOut }
        let result = TerminationResultBox()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            result.store(operation())
            completion.signal()
        }
        guard completion.wait(timeout: .now() + timeout) == .success else {
            return .timedOut
        }
        return result.load() == true ? .durable : .failed
    }

    private static func logCriticalTerminationFailures(_ report: CriticalTerminationReport) {
        logCriticalPersistenceFailures(report, context: "退出")
    }

    private static func logCriticalPersistenceFailures(
        _ report: CriticalTerminationReport,
        context: String
    ) {
        if !report.didMeetDeadline {
            PersistenceLogger.log(
                "\(context)关键存储超过统一时限："
                    + String(format: "%.3fs / %.3fs", report.elapsed, report.budget)
            )
        }
        for step in report.steps {
            switch step.outcome {
            case .durable, .skippedCoalesced:
                continue
            case .failed, .unavailable:
                PersistenceLogger.log("\(context)关键存储未持久：\(step.step.rawValue)")
            case .timedOut, .skippedNoRemainingTime:
                PersistenceLogger.log("\(context)关键存储超过统一时限：\(step.step.rawValue)")
            }
        }
    }
}
