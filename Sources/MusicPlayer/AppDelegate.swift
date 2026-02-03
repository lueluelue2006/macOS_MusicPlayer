import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var audioPlayer: AudioPlayer?
    private weak var playlistManager: PlaylistManager?
    private var keyEventMonitor: Any?
    private var activityEventMonitor: Any?

    func configure(audioPlayer: AudioPlayer, playlistManager: PlaylistManager) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
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
	                DispatchQueue.main.async {
	                    NSApplication.shared.terminate(nil)
	                }
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
                if ap.currentFile != nil {
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
            if ap.isPlaying { ap.pause() }
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
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = activityEventMonitor {
            NSEvent.removeMonitor(monitor)
            activityEventMonitor = nil
        }
    }

    // Finder/Dock 图标打开单个文件
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openEphemeral(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    // Finder/Dock 图标一次打开多个文件
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openEphemeral(urls: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    // 通用 URL 打开（例如从其他应用拖到 Dock）
    func application(_ application: NSApplication, open urls: [URL]) {
        openEphemeral(urls: urls)
    }

    private func openEphemeral(urls: [URL]) {
        guard let audioPlayer = audioPlayer else { return }
        // 过滤可支持的音频文件
        let filtered = urls.filter { Self.isAudioFile($0) }
        if filtered.isEmpty { return }

        // 标记本次启动（或本次外部打开）应跳过“恢复上次播放”
        DispatchQueue.main.async {
            audioPlayer.markSkipRestoreThisLaunch()
        }

        // 构建 AudioFile（使用现有的元数据读取逻辑，避免首次打开信息不全）
        Task { [weak self] in
            guard let self = self else { return }
            let files: [AudioFile] = await withTaskGroup(of: AudioFile?.self) { group in
                for url in filtered {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        if let pm = self.playlistManager {
                            let md = await pm.loadFreshMetadata(from: url)
                            return AudioFile(url: url, metadata: md)
                        } else {
                            let asset = AVURLAsset(url: url)
                            let md = await AudioMetadata.load(from: asset, includeArtwork: false)
                            return AudioFile(url: url, metadata: md)
                        }
                    }
                }
                var built: [AudioFile] = []
                for await item in group {
                    if let f = item { built.append(f) }
                }
                return built
            }

            // 仅播放，不加入/不保存到播放列表
            if let first = files.first {
                await MainActor.run {
                    audioPlayer.play(first, persist: false)
                }
            }
            // 确保主窗口置顶展示（单窗口应用，避免“找不到播放控制”的困惑）
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first {
                    win.makeKeyAndOrderFront(nil)
                }
            }
        }
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
            "flac", "ogg"
        ]
        return exts.contains(url.pathExtension.lowercased())
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
        if let ap = audioPlayer, ap.persistPlaybackState == false {
            ap.stopAndClearCurrent(clearLastPlayed: false)
        }
        return false
    }
}
