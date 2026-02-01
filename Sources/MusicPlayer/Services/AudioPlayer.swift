import Foundation
import AVFoundation
import Combine

final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

final class AudioPlayer: NSObject, ObservableObject {
    let playbackClock = PlaybackClock()
    @Published var currentFile: AudioFile?
    @Published var isPlaying = false
    @Published var volume: Float = 0.5
    @Published var playbackRate: Float = 1.0
    @Published var isLooping = false
    @Published var isShuffling = true  // 默认开启随机播放
    @Published var isNormalizationEnabled = true  // 音量均衡开关
    // 歌词相关
    @Published var lyricsTimeline: LyricsTimeline?
    @Published var showLyrics: Bool = true
    // 当前系统音频输出设备显示（用于 UI 展示）
    @Published var currentOutputDeviceName: String = "检测中..."
    // 是否为“系统内置扬声器”输出（用于设备名着色）
    @Published var isInternalSpeakerOutput: Bool = true
    // 是否已经初始化过输出设备名称（用于避免首次启动时发送系统通知）
    var hasInitializedOutputDeviceName: Bool = false
    // 是否在设备切换时发送系统通知（用户可在菜单开关）
    @Published var notifyOnDeviceSwitch: Bool = true
    private let userNotifyOnDeviceSwitchKey = "userNotifyOnDeviceSwitch"
    // 设备切换通知是否静音（默认静音）
    @Published var notifyDeviceSwitchSilent: Bool = true
    private let userNotifyDeviceSwitchSilentKey = "userNotifyDeviceSwitchSilent"
    // 当前是否为耳机类输出（用于判定是否需要扬声器确认）
    @Published var isHeadphoneOutput: Bool = false
    // 从耳机切到扬声器后，显式开始播放需要一次确认
    var shouldConfirmSpeakerPlayback: Bool = false
    // UI 弹窗绑定与回调
    @Published var showSpeakerConfirm: Bool = false
    var speakerConfirmProceed: (() -> Void)? = nil
    // 唤醒后抑制一次“自动续播”（例如合盖睡眠 → 开盖唤醒）
    var suppressAutoResumeOnce: Bool = false
    // 标记系统是否处于睡眠中（由 AppDelegate 维护）
    var isSystemSleeping: Bool = false
    // 在此时间点之前，禁止任何“自动续播”（避免开盖瞬间误触发）
    var disallowAutoResumeUntil: Date? = nil
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var volumeRampTask: Task<Void, Never>?
    // 移除未使用且可能干扰的 AVAudioEngine / PlayerNode，避免潜在路由或会话冲突
    // private let audioEngine = AVAudioEngine()
    // private let playerNode = AVAudioPlayerNode()
    // private let audioFile = AVAudioFile?.none
    
    private var lastSavedTime: TimeInterval = 0
    // 音量均衡缓存：存储“测得响度（RMS, dB）”，而不是直接存储增益，便于用户调整目标值后复用缓存。
    private var fileLoudnessCache: [String: Float] = [:]
    private let volumeCacheLock = NSLock()
    private let volumeCacheSaveLock = NSLock()
    @Published private(set) var volumeNormalizationCacheCount: Int = 0
    private let normalizationQueue = DispatchQueue(label: "audio.normalization", qos: .userInitiated)
    private let preanalysisQueue = DispatchQueue(label: "audio.preanalysis", qos: .utility)
    private var normalizationInFlight: Set<String> = []      // 避免同一文件重复分析
    private let volumeCacheKey = "volumeNormalizationCache"  // 旧版 UserDefaults 增益缓存迁移键
    private let volumeCacheFileName = "volume-cache.json"
    private let volumeCacheFormatVersion = 2
    private struct VolumeCacheFile: Codable {
        let version: Int
        let loudnessDbByPath: [String: Float]
    }
    private let legacyVolumeCacheTargetLevelDb: Float = -16.0
    private let maxNormalizationGain: Float = 2.0
    @Published var analyzeVolumesDuringPlayback: Bool = true
    private let userAnalyzeVolumesDuringPlaybackKey = "userAnalyzeVolumesDuringPlayback"
    @Published var autoPreanalyzeVolumesWhenIdle: Bool = false
    private let userAutoPreanalyzeVolumesWhenIdleKey = "userAutoPreanalyzeVolumesWhenIdle"
    @Published private(set) var isVolumePreanalysisRunning: Bool = false
    @Published private(set) var volumePreanalysisTotal: Int = 0
    @Published private(set) var volumePreanalysisCompleted: Int = 0
    @Published private(set) var volumePreanalysisCurrentFileName: String = ""
    private var volumePreanalysisTask: Task<Void, Never>?
    private let volumePreanalysisGenerationLock = NSLock()
    private var volumePreanalysisGeneration: UInt64 = 0
    @Published private(set) var lastUserInteractionAt: Date = Date()

    enum VolumePreanalysisStartReason {
        case manual
        case autoIdle
    }
    private var volumePreanalysisStartReason: VolumePreanalysisStartReason = .manual
    private let userVolumeKey = "userPreferredVolume"       // 用户设置的主音量键
    private let userNormalizationKey = "userNormalizationEnabled" // 音量均衡开关
    @Published var normalizationTargetLevelDb: Float = -16.0 // 目标响度（dB，基于当前 RMS 算法）
    private let userNormalizationTargetLevelDbKey = "userNormalizationTargetLevelDb"
    @Published var normalizationFadeDuration: Double = 0.6 // 应用均衡增益时的淡入时长（秒）
    private let userNormalizationFadeDurationKey = "userNormalizationFadeDuration"
    @Published var requireVolumeAnalysisBeforePlayback: Bool = false // 无缓存时先分析再播放
    private let userRequireVolumeAnalysisBeforePlaybackKey = "userRequireVolumeAnalysisBeforePlayback"
    private let userLoopingKey = "userLoopingEnabled"             // 单曲循环开关
    private let userShuffleKey = "userShuffleEnabled"             // 随机播放开关
    private var wasPlayingBeforeInterruption = false
    // 在耳机/路由变化导致的自动暂停后，记录是否应在耳机恢复时自动续播
    var shouldAutoResumeAfterRoute: Bool = false
    // 控制是否将当前播放状态（上次播放文件/进度）持久化；用于“外部打开文件（临时播放）”场景
    var persistPlaybackState: Bool = true
    // 标记本次启动是否应跳过“恢复上次播放”（用于 Finder/Dock 外部打开文件启动的场景）
    private var skipRestoreThisLaunch: Bool = false
    // 在播放器尚未就绪时记录一次性预设进度（用于跨启动恢复）
    private var pendingSeekTime: TimeInterval? = nil
    // 用于避免“快速切歌/重载”时旧异步任务回写覆盖新状态
    private var loadGeneration: UInt64 = 0
    private func nextLoadGeneration() -> UInt64 {
        loadGeneration &+= 1
        return loadGeneration
    }

    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.max(min, Swift.min(max, value))
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private func clampPlaybackRate(_ value: Float) -> Float {
        clamp(value, min: 0.5, max: 2.0)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    private func withVolumeCacheLock<T>(_ body: () -> T) -> T {
        volumeCacheLock.lock()
        defer { volumeCacheLock.unlock() }
        return body()
    }

    private func bumpVolumePreanalysisGeneration() -> UInt64 {
        volumePreanalysisGenerationLock.lock()
        defer { volumePreanalysisGenerationLock.unlock() }
        volumePreanalysisGeneration &+= 1
        return volumePreanalysisGeneration
    }

    private func currentVolumePreanalysisGeneration() -> UInt64 {
        volumePreanalysisGenerationLock.lock()
        defer { volumePreanalysisGenerationLock.unlock() }
        return volumePreanalysisGeneration
    }

    func recordUserInteraction(throttleSeconds: TimeInterval = 0) {
        let now = Date()
        let update = {
            if throttleSeconds > 0, now.timeIntervalSince(self.lastUserInteractionAt) < throttleSeconds {
                return
            }
            self.lastUserInteractionAt = now
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    func cancelVolumeNormalizationPreanalysisIfAutoIdle() {
        guard isVolumePreanalysisRunning, volumePreanalysisStartReason == .autoIdle else { return }
        cancelVolumeNormalizationPreanalysis()
    }

    override init() {
        super.init()
        configureAudioSession()
        observeAudioSessionNotifications()
        loadVolumeCache()  // 加载持久化的音量缓存
        loadUserVolume()   // 加载用户设置的主音量
        loadUserPlaybackSwitches() // 加载均衡/循环/随机开关
        loadNormalizationTargetLevelPreference()
        loadNormalizationFadeDurationPreference()
        loadRequireVolumeAnalysisBeforePlaybackPreference()
        loadVolumeAnalysisPreferences()
        loadNotifyOnDeviceSwitchPreference()
        loadNotifyDeviceSwitchSilentPreference()
    }

    private func loadVolumeAnalysisPreferences() {
        let d = UserDefaults.standard
        if d.object(forKey: userAnalyzeVolumesDuringPlaybackKey) != nil {
            analyzeVolumesDuringPlayback = d.bool(forKey: userAnalyzeVolumesDuringPlaybackKey)
        }
        if d.object(forKey: userAutoPreanalyzeVolumesWhenIdleKey) != nil {
            autoPreanalyzeVolumesWhenIdle = d.bool(forKey: userAutoPreanalyzeVolumesWhenIdleKey)
        }
    }

    func saveAnalyzeVolumesDuringPlaybackPreference() {
        let d = UserDefaults.standard
        d.set(analyzeVolumesDuringPlayback, forKey: userAnalyzeVolumesDuringPlaybackKey)
    }

    func saveAutoPreanalyzeVolumesWhenIdlePreference() {
        let d = UserDefaults.standard
        d.set(autoPreanalyzeVolumesWhenIdle, forKey: userAutoPreanalyzeVolumesWhenIdleKey)
    }

    private func loadNormalizationTargetLevelPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userNormalizationTargetLevelDbKey) != nil {
            let v = d.float(forKey: userNormalizationTargetLevelDbKey)
            normalizationTargetLevelDb = clamp(v, min: -30.0, max: -8.0)
        }
    }

    func saveNormalizationTargetLevelPreference() {
        normalizationTargetLevelDb = clamp(normalizationTargetLevelDb, min: -30.0, max: -8.0)
        let d = UserDefaults.standard
        d.set(normalizationTargetLevelDb, forKey: userNormalizationTargetLevelDbKey)
    }

    private func loadNormalizationFadeDurationPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userNormalizationFadeDurationKey) != nil {
            let v = d.double(forKey: userNormalizationFadeDurationKey)
            normalizationFadeDuration = clamp(v, min: 0.0, max: 1.5)
        }
    }

    func saveNormalizationFadeDurationPreference() {
        normalizationFadeDuration = clamp(normalizationFadeDuration, min: 0.0, max: 1.5)
        let d = UserDefaults.standard
        d.set(normalizationFadeDuration, forKey: userNormalizationFadeDurationKey)
    }

    private func loadRequireVolumeAnalysisBeforePlaybackPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userRequireVolumeAnalysisBeforePlaybackKey) != nil {
            requireVolumeAnalysisBeforePlayback = d.bool(forKey: userRequireVolumeAnalysisBeforePlaybackKey)
        }
    }

    func saveRequireVolumeAnalysisBeforePlaybackPreference() {
        let d = UserDefaults.standard
        d.set(requireVolumeAnalysisBeforePlayback, forKey: userRequireVolumeAnalysisBeforePlaybackKey)
    }
    
    // macOS 不需要 AVAudioSession 配置，保留空实现避免 iOS API 在 macOS 上的不可用错误
    private func configureAudioSession() {
        // no-op on macOS
    }
    
    // macOS 上无需监听 AVAudioSession 通知，保留空实现以保持接口一致
    private func observeAudioSessionNotifications() {
        // no-op on macOS
    }
    
    private var pendingLoadTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?

    // MARK: - Launch restore gating
    /// 本次启动/本次外部打开期间，跳过一次“恢复上次播放”。仅用于内存态，不写入 UserDefaults。
    func markSkipRestoreThisLaunch() {
        skipRestoreThisLaunch = true
    }

    /// 消费一次“跳过恢复”标记（读取后自动清除）
    func consumeSkipRestoreThisLaunch() -> Bool {
        if skipRestoreThisLaunch {
            skipRestoreThisLaunch = false
            return true
        }
        return false
    }

    func play(_ file: AudioFile, persist: Bool = true, bypassConfirm: Bool = false) {
        // 兼容旧签名：默认自动开始播放
        play(file, autostart: true, persist: persist, bypassConfirm: bypassConfirm)
    }

    /// 加载并可选是否自动开始播放
    func play(_ file: AudioFile, autostart: Bool, persist: Bool = true, bypassConfirm: Bool = false) {
        // 若当前为扬声器且来自“耳机→扬声器”的切换，仅对用户显式开始播放做一次确认
        if !bypassConfirm, !isHeadphoneOutput, shouldConfirmSpeakerPlayback {
            requestSpeakerConfirm { [weak self] in
                self?.shouldConfirmSpeakerPlayback = false
                self?.play(file, autostart: autostart, persist: persist, bypassConfirm: true)
            }
            return
        }
        // 取消尚未完成的加载任务，避免相互打断
        pendingLoadTask?.cancel()
        self.persistPlaybackState = persist

        let isLoop = self.isLooping
        let url = file.url
        let generation = nextLoadGeneration()

        // 在后台初始化播放器，并添加 20s 超时保护，避免 UI 卡死
        pendingLoadTask = Task { [weak self] in
            guard let self = self else { return }
            if let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url) {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    NotificationCenter.default.post(
                        name: .audioPlayerDidFailToPlay,
                        object: nil,
                        userInfo: [
                            "url": url,
                            "message": reason
                        ]
                    )
                    if !isLoop {
                        NotificationCenter.default.post(name: .audioPlayerDidFinish, object: nil)
                    }
                }
                return
            }
            do {
                let newPlayer: AVAudioPlayer = try await AsyncTimeout.withTimeout(20) {
                    try await Task.detached(priority: .userInitiated) {
                        let p: AVAudioPlayer
                        do {
                            p = try AVAudioPlayer(contentsOf: url)
                        } catch {
                            if let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url) {
                                p = try AVAudioPlayer(contentsOf: url, fileTypeHint: hint)
                            } else {
                                throw error
                            }
                        }
                        p.numberOfLoops = isLoop ? -1 : 0
                        p.prepareToPlay()
                        return p
                    }.value
                }

                // 若用户启用“播放前必须分析”，则在真正切歌/开播前先产出缓存，避免播放中音量变化
                if autostart,
                   self.isNormalizationEnabled,
                   self.requireVolumeAnalysisBeforePlayback,
                   !self.hasVolumeNormalizationCache(for: url) {
                    _ = self.calculateNormalizedVolume(for: url, persist: true)
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    // 到这里说明新曲目可被 AVAudioPlayer 正常初始化，才切换并停止旧播放器
                    self.stop()
                    self.player = newPlayer
                    newPlayer.delegate = self
                    newPlayer.enableRate = true
                    newPlayer.rate = self.clampPlaybackRate(self.playbackRate)

	                    self.currentFile = file
	                    self.playbackClock.duration = newPlayer.duration
	                    self.lastSavedTime = 0
	                    self.loadArtworkIfNeeded(for: url)

                    NotificationCenter.default.post(
                        name: .audioPlayerDidLoadFile,
                        object: nil,
                        userInfo: ["url": url]
                    )

                    // 应用音量均衡（异步计算，避免主线程阻塞）
                    let allowBackgroundAnalysis = (!self.requireVolumeAnalysisBeforePlayback) || (!autostart) || self.hasVolumeNormalizationCache(for: url)
                    self.applyVolumeNormalization(for: url, mode: .immediate, allowBackgroundAnalysis: allowBackgroundAnalysis)

                    // 若存在待应用的初始进度（如跨启动恢复），在真正开播前先定位
	                    if let t = self.pendingSeekTime {
	                        let clamped = max(0, min(t, self.playbackClock.duration))
	                        newPlayer.currentTime = clamped
	                        self.playbackClock.currentTime = clamped
	                        self.pendingSeekTime = nil
	                    }

                    // 加载歌词（异步）
                    self.loadLyricsIfNeeded(for: file)

                    var didStart = false
                    if autostart {
                        didStart = newPlayer.play()
                        if didStart {
                            self.isPlaying = true
                            self.startTimer()
                            if self.persistPlaybackState {
                                self.saveLastPlayedFile(file)
                            }
                        } else {
                            self.isPlaying = false
                            self.stopTimer()
                            NotificationCenter.default.post(
                                name: .audioPlayerDidFailToPlay,
                                object: nil,
                                userInfo: [
                                    "url": url,
                                    "message": "无法开始播放：\(url.lastPathComponent)"
                                ]
                            )
                            if !self.isLooping {
                                NotificationCenter.default.post(name: .audioPlayerDidFinish, object: nil)
                            }
                        }
                    } else {
                        self.isPlaying = false
                        self.stopTimer()
                        if self.persistPlaybackState { self.saveLastPlayedFile(file) }
                    }
                }
            } catch is TimeoutError {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.debugLog("加载音频超时(20s): \(url.lastPathComponent)")
                    NotificationCenter.default.post(
                        name: .audioPlayerDidFailToPlay,
                        object: nil,
                        userInfo: [
                            "url": url,
                            "message": "加载超时(20s)：\(url.lastPathComponent)"
                        ]
                    )
                    if !self.isLooping {
                        NotificationCenter.default.post(name: .audioPlayerDidFinish, object: nil)
                    }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.debugLog("播放音频失败: \(error)")
                    NotificationCenter.default.post(
                        name: .audioPlayerDidFailToPlay,
                        object: nil,
                        userInfo: [
                            "url": url,
                            "message": "播放失败：\(url.lastPathComponent)\n\(error.localizedDescription)"
                        ]
                    )
                    if !self.isLooping {
                        NotificationCenter.default.post(name: .audioPlayerDidFinish, object: nil)
                    }
                }
            }
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        saveCurrentProgress() // 暂停时保存进度
    }
    
    func resume(bypassConfirm: Bool = false) {
        // 若当前为扬声器且来自“耳机→扬声器”的切换，仅对用户显式开始播放做一次确认
        if !bypassConfirm, !isHeadphoneOutput, shouldConfirmSpeakerPlayback {
            requestSpeakerConfirm { [weak self] in
                self?.shouldConfirmSpeakerPlayback = false
                self?.resume(bypassConfirm: true)
            }
            return
        }
        guard let player = player else { return }
        // 若用户开启“播放前必须分析”，且当前曲目尚未缓存，则先完成一次分析再开始播放，避免播放中音量变化
        if isNormalizationEnabled,
           requireVolumeAnalysisBeforePlayback,
           let url = currentFile?.url,
           !hasVolumeNormalizationCache(for: url) {
            let capturedPlayer = player
            Task { [weak self] in
                guard let self else { return }
                _ = self.calculateNormalizedVolume(for: url, persist: true)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.player === capturedPlayer else { return }
                    guard self.currentFile?.url == url else { return }
                    self.applyVolumeNormalization(for: url, mode: .immediate, allowBackgroundAnalysis: false)
                    capturedPlayer.play()
                    self.isPlaying = true
                    self.startTimer()
                }
            }
            return
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    /// 切换播放/暂停（用于快捷键/菜单）
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if currentFile != nil {
            resume()
        }
    }
    
    private func requestSpeakerConfirm(proceed: @escaping () -> Void) {
        speakerConfirmProceed = proceed
        showSpeakerConfirm = true
    }
    
	    func stop() {
	        saveCurrentProgress() // 停止时保存进度
	        volumeRampTask?.cancel()
	        volumeRampTask = nil
	        player?.stop()
	        isPlaying = false
	        playbackClock.currentTime = 0
	        stopTimer()
	    }
    
    /// 停止并清空当前曲目信息（用于“清空播放列表”等需要完全复位的场景）
	    func stopAndClearCurrent(clearLastPlayed: Bool = true) {
        // 停止播放与计时
        volumeRampTask?.cancel()
        volumeRampTask = nil
	        player?.stop()
	        isPlaying = false
	        playbackClock.currentTime = 0
	        stopTimer()
        // 释放播放器实例，避免后续误用
        player = nil
        // 清空与当前曲目相关的状态
        currentFile = nil
        lyricsTimeline = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
	        playbackClock.duration = 0
        // 可选：清理最近播放缓存，避免清空后再次自动恢复
        if clearLastPlayed {
            let userDefaults = UserDefaults.standard
            userDefaults.removeObject(forKey: "lastPlayedFilePath")
            userDefaults.removeObject(forKey: "lastPlayedFileTime")
        }
    }
    
	    func seek(to time: TimeInterval) {
        if let player = player {
            player.currentTime = time
	        } else {
	            // 播放器尚未就绪：记录为待应用的初始进度
	            pendingSeekTime = time
	        }
	        playbackClock.currentTime = time
	    }

    /// 重新载入当前曲目的底层播放器，尽量保留播放/进度状态（用于完全刷新、外部文件被覆盖的情况）
	    func reloadCurrentPreservingState() {
	        guard let file = currentFile else { return }
	        let wasPlaying = isPlaying
	        let prevTime = playbackClock.currentTime
	        let isLoop = isLooping
	        let url = file.url

        pendingLoadTask?.cancel()
        let generation = nextLoadGeneration()
        pendingLoadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let newPlayer: AVAudioPlayer = try await AsyncTimeout.withTimeout(20) {
                    try await Task.detached(priority: .userInitiated) {
                        let p: AVAudioPlayer
                        do {
                            p = try AVAudioPlayer(contentsOf: url)
                        } catch {
                            if let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url) {
                                p = try AVAudioPlayer(contentsOf: url, fileTypeHint: hint)
                            } else {
                                throw error
                            }
                        }
                        p.numberOfLoops = isLoop ? -1 : 0
                        p.prepareToPlay()
                        return p
                    }.value
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    // 切换播放器
                    self.player?.stop()
	                    self.player = newPlayer
	                    newPlayer.delegate = self
	                    newPlayer.enableRate = true
	                    newPlayer.rate = self.clampPlaybackRate(self.playbackRate)
	                    self.playbackClock.duration = newPlayer.duration

                    // 重建音量、进度与定时器
	                    self.loadArtworkIfNeeded(for: url)
	                    self.applyVolumeNormalization(for: url)
	                    if prevTime > 0 { self.seek(to: min(prevTime, self.playbackClock.duration)) }
                    if wasPlaying {
                        _ = newPlayer.play()
                        self.isPlaying = true
                        self.startTimer()
                    } else {
                        self.isPlaying = false
                        self.stopTimer()
                    }
                }
            } catch is TimeoutError {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.debugLog("重新载入当前曲目超时(20s): \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.debugLog("重新载入当前曲目失败: \(error)")
                }
            }
        }
    }
    
    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        saveUserVolume()   // 持久化保存主音量
        updatePlayerVolume()
    }

    func setPlaybackRate(_ newRate: Float) {
        playbackRate = clampPlaybackRate(newRate)
        updatePlayerRate()
    }
    
    func toggleNormalization() {
        isNormalizationEnabled.toggle()
        saveNormalizationPreference()
        if let currentFile = currentFile {
            let mode: VolumeApplyMode = isPlaying ? .smooth : .immediate
            applyVolumeNormalization(for: currentFile.url, mode: mode)
        } else {
            player?.volume = volume
        }
    }

    func setNormalizationEnabled(_ enabled: Bool) {
        guard enabled != isNormalizationEnabled else { return }
        toggleNormalization()
    }
    
    func toggleLoop() {
        isLooping.toggle()
        if isShuffling && isLooping {
            isShuffling = false
            saveShufflePreference()
        }
        // 立即应用循环设置到当前播放器
        updateLoopSetting()
        saveLoopingPreference()
    }
    
    func toggleShuffle() {
        isShuffling.toggle()
        if isLooping && isShuffling {
            isLooping = false
            updateLoopSetting()
            saveLoopingPreference()
        }
        saveShufflePreference()
    }
    
    private func updateLoopSetting() {
        player?.numberOfLoops = isLooping ? -1 : 0
    }

    private func updatePlayerRate() {
        guard let player else { return }
        player.enableRate = true
        player.rate = clampPlaybackRate(playbackRate)
    }
    
    private func startTimer() {
        // 确保只存在一个计时器，并使用 .common 模式防止 UI 交互导致暂停
        stopTimer()
	        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
	            guard let self = self, let player = self.player else { return }
            // 若系统层面导致播放器停止（例如音频路由变化/耳机断开），
            // AVAudioPlayer 可能会自行变为未播放状态，但未必触发 delegate 回调。
            // 这里做保护性检测以同步应用内播放状态与 UI。
            if self.isPlaying && !player.isPlaying {
                self.isPlaying = false
                self.saveCurrentProgress()
                self.stopTimer()
                return
            }
	            let nowTime = player.currentTime
	            self.playbackClock.currentTime = nowTime
	            // 每隔5秒保存一次播放进度
	            if abs(nowTime - self.lastSavedTime) >= 5.0 {
	                self.saveCurrentProgress()
	                self.lastSavedTime = nowTime
	            }
	            // 歌词同步由 SwiftUI 订阅 playbackClock.currentTime/lyricsTimeline 实现，这里无需额外逻辑
	        }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - 删除当前播放项后的回调处理
    /// 在“删除歌曲”时，如果删除的是当前播放曲目，由上层调用本方法以执行正确的后续动作
    /// - Parameters:
    ///   - remainingFiles: 删除后当前播放列表剩余的文件（用于随机/顺序继续播放）
    ///   - playNext: 可选的“获取下一首”的闭包（若上层有顺序管理器可传入），未提供时将不处理顺序下一首
    func handleCurrentTrackRemoved(remainingFiles: [AudioFile], playNext: (() -> AudioFile?)? = nil) {
        // 单曲循环：立即停止并清空当前歌曲
        if isLooping {
            stop()
            currentFile = nil
            lyricsTimeline = nil
            return
        }
        // 随机模式：从剩余文件中随机一首继续播放；若空则停止并清空
        if isShuffling {
            if let next = remainingFiles.randomElement() {
                play(next)
            } else {
                stop()
                currentFile = nil
                lyricsTimeline = nil
            }
            return
        }
        // 其他模式：如果提供了顺序“下一首”，尝试获取并播放；否则与空列表时相同处理
        if let nextProvider = playNext, let next = nextProvider() {
            play(next)
        } else {
            stop()
            currentFile = nil
            lyricsTimeline = nil
        }
    }
    
    // MARK: - 保存和加载上次播放的歌曲
    private func saveLastPlayedFile(_ file: AudioFile) {
        let userDefaults = UserDefaults.standard
        userDefaults.set(file.url.path, forKey: "lastPlayedFilePath")
        // 不在这里保存时间，因为刚开始播放时 currentTime 是 0
    }
    
		    private func saveCurrentProgress() {
		        guard currentFile != nil else { return }
		        // 临时播放（不持久化）时不保存播放进度
		        guard persistPlaybackState else { return }
		        let time = playbackClock.currentTime
		        UserDefaults.standard.set(time, forKey: "lastPlayedFileTime")
		        debugLog("保存播放进度: \(time) 秒")
		    }
    
	    func loadLastPlayedFile() {
	        let userDefaults = UserDefaults.standard
	        guard let filePath = userDefaults.string(forKey: "lastPlayedFilePath") else {
	            debugLog("没有找到上次播放的文件路径")
	            return
	        }
	        debugLog("尝试加载上次播放的文件: \(filePath)")
	        if FileManager.default.fileExists(atPath: filePath) {
	            let url = URL(fileURLWithPath: filePath)
	            let lastPlayedTime = userDefaults.double(forKey: "lastPlayedFileTime")
	            debugLog("文件存在，发送加载通知，播放时间: \(lastPlayedTime)")
	            NotificationCenter.default.post(
	                name: .loadLastPlayedFile,
	                object: nil,
                userInfo: ["url": url, "time": lastPlayedTime]
            )
	        } else {
	            debugLog("文件不存在: \(filePath)")
	        }
	    }
    // MARK: - 歌词加载
    private func loadLyricsIfNeeded(for file: AudioFile) {
        // 优先使用 AudioFile 自带缓存
        if let cached = file.lyricsTimeline {
            if self.currentFile?.url == file.url {
                self.lyricsTimeline = cached
            }
            return
        }
        let url = file.url
        Task {
            let result = await LyricsService.shared.loadLyrics(for: url)
            await MainActor.run {
                // 仅当当前仍为该文件时才回写 UI，避免“切歌后歌词串台/被清空”
                guard self.currentFile?.url == url else { return }
                switch result {
                case .success(let timeline):
                    self.lyricsTimeline = timeline
                    if let current = self.currentFile, current.url == url {
                        let updated = AudioFile(url: current.url, metadata: current.metadata, lyricsTimeline: timeline)
                        self.currentFile = updated
                    }
                case .failure:
                    self.lyricsTimeline = nil
                }
            }
        }
    }

    // MARK: - Artwork loading（按需，避免为整个列表持有大图数据）
    private func loadArtworkIfNeeded(for url: URL) {
        guard let current = currentFile, current.url == url else { return }
        guard current.metadata.artwork == nil else { return }

        artworkLoadTask?.cancel()
        artworkLoadTask = Task { [weak self] in
            guard let self else { return }
            let data = await self.fetchArtworkData(for: url)
            guard let data else { return }
            await MainActor.run {
                guard let current = self.currentFile, current.url == url else { return }
                guard current.metadata.artwork == nil else { return }
                let md = AudioMetadata(
                    title: current.metadata.title,
                    artist: current.metadata.artist,
                    album: current.metadata.album,
                    year: current.metadata.year,
                    genre: current.metadata.genre,
                    artwork: data
                )
                self.currentFile = AudioFile(url: current.url, metadata: md, lyricsTimeline: current.lyricsTimeline)
            }
        }
    }

    private func fetchArtworkData(for url: URL) async -> Data? {
        do {
            return try await AsyncTimeout.withTimeout(20) {
                let asset = AVURLAsset(url: url)
                let items = try await asset.load(.commonMetadata)
                for item in items {
                    if item.commonKey?.rawValue.lowercased() == "artwork" {
                        if #available(macOS 13.0, *) {
                            if let data = try? await item.load(.dataValue) {
                                return data
                            }
                        } else {
                            if let data = item.dataValue {
                                return data
                            }
                        }
                    }
                }
                return nil
            }
        } catch {
            return nil
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 仅处理来自“当前”播放器实例的回调，忽略已被切换掉的旧实例，避免误将新歌置为暂停
        guard player === self.player else { return }
        // 未成功结束：通常意味着解码/播放异常（少数情况下系统也可能不给出 error）
        if !flag, let url = currentFile?.url {
            NotificationCenter.default.post(
                name: .audioPlayerDidFailToPlay,
                object: nil,
                userInfo: [
                    "url": url,
                    "message": "播放异常结束：\(url.lastPathComponent)"
                ]
            )
        }
        // 无论成功与否，只要自然结束且未开启单曲循环，都推进到下一首
	        if !isLooping {
	            isPlaying = false
	            playbackClock.currentTime = 0
	            stopTimer()
	            NotificationCenter.default.post(name: .audioPlayerDidFinish, object: nil)
	        }
	    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // 仅处理来自“当前”播放器实例的回调
        guard player === self.player else { return }
        if let url = currentFile?.url {
            NotificationCenter.default.post(
                name: .audioPlayerDidFailToPlay,
                object: nil,
                userInfo: [
                    "url": url,
                    "message": "解码失败：\(url.lastPathComponent)\n\(error?.localizedDescription ?? "")"
                ]
            )
        }
        // 解码错误时，尝试跳到下一首，避免“卡住或像暂停一样不动”
        if !isLooping {
            isPlaying = false
            stopTimer()
            NotificationCenter.default.post(name: .audioPlayerDidFinish, object: nil)
        }
    }
}

// MARK: - 音量均衡相关方法
extension AudioPlayer {
    private enum VolumeApplyMode {
        case immediate
        case smooth
    }

    /// 重新应用当前曲目的音量均衡（用于用户修改目标值/淡入时长后即时生效）
    func reapplyVolumeNormalizationForCurrentFile(smoothIfPlaying: Bool = true) {
        guard let url = currentFile?.url else { return }
        let mode: VolumeApplyMode = (smoothIfPlaying && isPlaying) ? .smooth : .immediate
        applyVolumeNormalization(for: url, mode: mode)
    }

    private func normalizationGain(forMeasuredLevelDb levelDb: Float) -> Float {
        let exponent = Double((normalizationTargetLevelDb - levelDb) / 20.0)
        let gain = pow(10.0, exponent)
        guard gain.isFinite, gain > 0 else { return 1.0 }
        return min(Float(gain), maxNormalizationGain)
    }

    private func desiredPlayerVolume(for url: URL) -> Float {
        if !isNormalizationEnabled { return volume }
        let fileKey = url.path
        if let levelDb = withVolumeCacheLock({ fileLoudnessCache[fileKey] }) {
            return min(volume * normalizationGain(forMeasuredLevelDb: levelDb), 1.0)
        }
        return volume
    }

    private func startVolumeRamp(on player: AVAudioPlayer, to targetVolume: Float, duration: Double) {
        volumeRampTask?.cancel()
        let start = player.volume
        if abs(start - targetVolume) < 0.001 {
            player.volume = targetVolume
            return
        }

        let steps = max(1, Int(duration / 0.03)) // ~33 FPS
        let stepDurationNs = UInt64((duration / Double(steps)) * 1_000_000_000)
        let thisPlayer = player

        volumeRampTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in 1...steps {
                if Task.isCancelled { return }
                if self.player !== thisPlayer { return }
                let t = Float(step) / Float(steps)
                thisPlayer.volume = start + (targetVolume - start) * t
                try? await Task.sleep(nanoseconds: stepDurationNs)
            }
            if self.player === thisPlayer {
                thisPlayer.volume = targetVolume
            }
        }
    }

    private func setPlayerVolume(_ targetVolume: Float, mode: VolumeApplyMode) {
        let clamped = max(0, min(1, targetVolume))
        DispatchQueue.main.async { [weak self] in
            guard let self, let player = self.player else { return }
            switch mode {
            case .immediate:
                self.volumeRampTask?.cancel()
                player.volume = clamped
            case .smooth:
                let duration = self.normalizationFadeDuration
                guard duration > 0, self.isPlaying else {
                    self.volumeRampTask?.cancel()
                    player.volume = clamped
                    return
                }
                self.startVolumeRamp(on: player, to: clamped, duration: duration)
            }
        }
    }
	    
	    /// 应用音量均衡（异步）
	    private func applyVolumeNormalization(for url: URL, mode: VolumeApplyMode = .immediate, allowBackgroundAnalysis: Bool = true) {
            let fileKey = url.path

            // 先立即/平滑应用当前可得的结果（有缓存则命中，否则保持用户音量）
            setPlayerVolume(desiredPlayerVolume(for: url), mode: mode)

            // 若均衡已关闭，不再后台分析
            guard isNormalizationEnabled else { return }

            let hasCache = withVolumeCacheLock { fileLoudnessCache[fileKey] != nil }
            // 若已有缓存，无需再排队分析
            guard !hasCache else { return }
            guard allowBackgroundAnalysis else { return }

            // 若正在播放且用户关闭“播放时分析”，则只用当前音量先播；后续可在空闲时预分析补齐
            if isPlaying && !analyzeVolumesDuringPlayback {
                return
            }

            // 后台计算并更新
            normalizationQueue.async { [weak self] in
                guard let self else { return }
                // 避免同一路径重复排队分析
                if self.normalizationInFlight.contains(fileKey) { return }
                self.normalizationInFlight.insert(fileKey)
                defer { self.normalizationInFlight.remove(fileKey) }

                _ = self.calculateNormalizedVolume(for: url)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // 仅当当前仍是该文件时才应用，避免切歌时误写
                    guard self.currentFile?.url == url else { return }
                    let mode: VolumeApplyMode = self.isPlaying ? .smooth : .immediate
                    self.setPlayerVolume(self.desiredPlayerVolume(for: url), mode: mode)
                }
            }
	    }
	    
	    /// 更新播放器音量
	    func updatePlayerVolume() {
            volumeRampTask?.cancel() // 用户主动调音量时不要被淡入覆盖
	        if let currentFile = currentFile {
	            applyVolumeNormalization(for: currentFile.url, mode: .immediate)
	        } else {
	            player?.volume = volume
	        }
	    }
	    
		    /// 计算归一化音量
		    func calculateNormalizedVolume(for url: URL, persist: Bool = true, cancellationCheck: (() -> Bool)? = nil) -> Float {
		        let fileKey = url.path
		        
		        // 检查缓存
		        if let cachedLevelDb = withVolumeCacheLock({ fileLoudnessCache[fileKey] }) {
		            return normalizationGain(forMeasuredLevelDb: cachedLevelDb)
		        }

			        // 分析音频文件响度（RMS, dB）
			        guard let measuredLevelDb = analyzeAudioLevel(for: url, cancellationCheck: cancellationCheck) else {
                    if cancellationCheck?() == true { return 1.0 }
		                debugLog("音量均衡分析失败：\(url.lastPathComponent)（将使用原始音量）")
		                return 1.0
		            }
		        let gain = normalizationGain(forMeasuredLevelDb: measuredLevelDb)

	        // 缓存“测得响度”
	        let newCount: Int = withVolumeCacheLock {
	            fileLoudnessCache[fileKey] = measuredLevelDb
	            return fileLoudnessCache.count
	        }
	        DispatchQueue.main.async { [weak self] in
	            self?.volumeNormalizationCacheCount = newCount
	        }
	        if persist {
	            saveVolumeCache()  // 持久化保存
	        }
	        
		        debugLog("文件: \(url.lastPathComponent), RMS: \(measuredLevelDb)dB, 目标: \(normalizationTargetLevelDb)dB, 增益: \(gain)")

		        return gain
			    }
	    
	    /// 分析音频文件的音量水平：顺序读取整首歌曲计算 RMS
	    func analyzeAudioLevel(for url: URL, cancellationCheck: (() -> Bool)? = nil) -> Float? {
	        if cancellationCheck?() == true { return nil }
	        if Task.isCancelled { return nil }
	        do {
                var audioFile: AVAudioFile? = nil
                var aliasURL: URL? = nil
                do {
                    audioFile = try AVAudioFile(forReading: url)
                } catch {
                    if cancellationCheck?() == true { return nil }
                    if Task.isCancelled { return nil }
                    // Some files have extensions that don't match the actual container (e.g. `.mp3` name
                    // but actually an `.m4a`). AVAudioFile relies on the extension in some cases, so we
                    // create a temporary alias with a best-effort extension inferred from magic bytes.
                    aliasURL = makeAudioReadAliasURLIfNeeded(for: url)
                    if let aliasURL {
                        audioFile = try AVAudioFile(forReading: aliasURL)
                    } else {
                        throw error
                    }
                }
                guard let audioFile else { return nil }
                defer {
                    if let aliasURL {
                        try? FileManager.default.removeItem(at: aliasURL)
                    }
                }
	            let format = audioFile.processingFormat
	            let channelCount = Int(format.channelCount)
	            guard channelCount > 0 else { return nil }

            let chunkFrames: AVAudioFrameCount = 32768 // ≈0.75s @44.1kHz
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                return nil
            }

            let totalFrames = audioFile.length
            if totalFrames <= 0 { return nil }

            var framesProcessed: AVAudioFramePosition = 0
            var totalSamples: Int64 = 0
            var sumSquares: Double = 0
	            var chunkIndex: Int = 0

	            while framesProcessed < totalFrames {
	                if cancellationCheck?() == true { return nil }
	                if Task.isCancelled { return nil }
	                chunkIndex += 1
	                let framesRemaining = totalFrames - framesProcessed
	                let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), framesRemaining))
	                try audioFile.read(into: buffer, frameCount: framesToRead)
                let framesRead = Int(buffer.frameLength)
                if framesRead == 0 { break }

                let effectiveFrames = min(framesRead, Int(framesRemaining))

                if let channels = buffer.floatChannelData {
                    for c in 0..<channelCount {
                        let ptr = channels[c]
                        var i = 0
                        while i < effectiveFrames {
                            let sample = ptr[i]
                            sumSquares += Double(sample * sample)
                            i += 1
                        }
                    }
                }

                totalSamples += Int64(effectiveFrames * channelCount)
                framesProcessed += AVAudioFramePosition(effectiveFrames)

	                if framesRead < framesToRead { break }
	                if chunkIndex % 16 == 0 {
	                    if cancellationCheck?() == true { return nil }
	                    try? Task.checkCancellation()
	                }
	            }

            guard totalSamples > 0 else { return nil }
            let rms = sqrt(sumSquares / Double(totalSamples))
            let dbValue = 20.0 * log10(max(rms, 1e-10))
            return Float(dbValue)

        } catch {
            debugLog("分析音频音量失败: \(error)")
            return nil
        }
    }

    /// Create a temporary symlink with a corrected extension if `AVAudioFile(forReading:)` may fail due to
    /// extension/container mismatch. Returns `nil` if no hint is available or alias creation fails.
    private func makeAudioReadAliasURLIfNeeded(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        guard let hint else { return nil }

        let desiredExtension: String? = {
            if hint == AVFileType.m4a.rawValue { return "m4a" }
            if hint == AVFileType.wav.rawValue { return "wav" }
            if hint == AVFileType.aiff.rawValue { return "aiff" }
            if hint == AVFileType.aifc.rawValue { return "aifc" }
            if hint == AVFileType.caf.rawValue { return "caf" }
            if hint == AVFileType.mp3.rawValue { return "mp3" }
            if hint == "public.aac-audio" { return "aac" }
            return nil
        }()

        guard let desiredExtension else { return nil }
        if url.pathExtension.lowercased() == desiredExtension { return nil }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let alias = tempDir.appendingPathComponent("MusicPlayer-AudioAlias-\(UUID().uuidString).\(desiredExtension)")

        do {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            return alias
        } catch {
            debugLog("创建音频别名失败: \(error)")
            return nil
        }
    }
    
    /// 清除音量缓存
    func clearVolumeCache() {
        withVolumeCacheLock {
            fileLoudnessCache.removeAll()
        }
        DispatchQueue.main.async { [weak self] in
            self?.volumeNormalizationCacheCount = 0
        }
        // 先尝试删除磁盘缓存文件，保证彻底清理
        if let url = volumeCacheURL() {
            try? FileManager.default.removeItem(at: url)
        }
        saveVolumeCache()  // 清除后也要保存
    }
    
    /// 加载持久化的音量缓存
    private func loadVolumeCache() {
        // 优先从磁盘读取新的 JSON 缓存（带版本字段）
        if let url = volumeCacheURL(), let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(VolumeCacheFile.self, from: data),
               decoded.version == volumeCacheFormatVersion {
                withVolumeCacheLock {
                    fileLoudnessCache = decoded.loudnessDbByPath
                }
                volumeNormalizationCacheCount = decoded.loudnessDbByPath.count
                debugLog("加载了 \(decoded.loudnessDbByPath.count) 个文件的响度缓存")
                return
            }

            // 兼容旧版磁盘缓存：可能是“增益字典”或“响度字典”
            if let legacy = try? JSONDecoder().decode([String: Float].self, from: data) {
                let migrated = migrateLegacyVolumeCache(legacy)
                withVolumeCacheLock {
                    fileLoudnessCache = migrated
                }
                volumeNormalizationCacheCount = migrated.count
                saveVolumeCache()
                debugLog("已迁移旧版音量缓存文件：\(migrated.count) 项")
                return
            }
        }

        // 兼容旧版 UserDefaults 缓存：加载后迁移到磁盘（旧版存的是“增益”）
        let d = UserDefaults.standard
        if let cachedData = d.dictionary(forKey: volumeCacheKey) as? [String: Float] {
            let migrated = migrateLegacyVolumeCache(cachedData)
            withVolumeCacheLock {
                fileLoudnessCache = migrated
            }
            volumeNormalizationCacheCount = migrated.count
            saveVolumeCache()
            d.removeObject(forKey: volumeCacheKey)
            debugLog("从旧版偏好迁移了 \(migrated.count) 个文件的响度缓存")
            return
        }

        if volumeNormalizationCacheCount == 0 {
            volumeNormalizationCacheCount = withVolumeCacheLock { fileLoudnessCache.count }
        }
    }

    /// 将旧版缓存（增益）迁移为“响度(dB)”缓存。
    private func migrateLegacyVolumeCache(_ legacy: [String: Float]) -> [String: Float] {
        // 若存在负数，基本可判定为“响度(dB)”而非旧版增益，直接复用
        if legacy.values.contains(where: { $0 < 0 }) {
            return legacy
        }

        var migrated: [String: Float] = [:]
        migrated.reserveCapacity(legacy.count)
        for (path, gain) in legacy {
            guard gain.isFinite, gain > 0 else { continue }
            // 旧版对增益做了上限（maxNormalizationGain）；若命中上限则信息不足，跳过以触发重新分析
            if gain >= (maxNormalizationGain * 0.999) {
                continue
            }
            let loudness = legacyVolumeCacheTargetLevelDb - Float(20.0 * log10(Double(gain)))
            migrated[path] = loudness
        }
        return migrated
    }
    
    /// 保存音量缓存到持久化存储
    private func saveVolumeCache() {
        guard let url = volumeCacheURL() else { return }
        volumeCacheSaveLock.lock()
        defer { volumeCacheSaveLock.unlock() }

        let snapshot: [String: Float] = withVolumeCacheLock { fileLoudnessCache }
        do {
            let payload = VolumeCacheFile(version: volumeCacheFormatVersion, loudnessDbByPath: snapshot)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
            debugLog("保存了 \(snapshot.count) 个文件的响度缓存到磁盘")
        } catch {
            debugLog("保存音量缓存失败: \(error)")
        }
    }

    func hasVolumeNormalizationCache(for url: URL) -> Bool {
        let key = url.path
        return withVolumeCacheLock { fileLoudnessCache[key] != nil }
    }

    func volumeNormalizationCacheKeysSnapshot() -> Set<String> {
        withVolumeCacheLock { Set(fileLoudnessCache.keys) }
    }

    func startVolumeNormalizationPreanalysis(urls: [URL], reason: VolumePreanalysisStartReason = .manual) {
        let generation = bumpVolumePreanalysisGeneration()
        volumePreanalysisStartReason = reason
        volumePreanalysisTask?.cancel()
        volumePreanalysisTask = nil

        var seen = Set<String>()
        let unique: [URL] = urls.filter { url in
            let key = url.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        let targets = unique.filter { !hasVolumeNormalizationCache(for: $0) }
        guard !targets.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isVolumePreanalysisRunning = false
                self.volumePreanalysisCurrentFileName = ""
            }
            volumePreanalysisStartReason = .manual
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVolumePreanalysisRunning = true
            self.volumePreanalysisTotal = targets.count
            self.volumePreanalysisCompleted = 0
            self.volumePreanalysisCurrentFileName = ""
        }

	        volumePreanalysisTask = Task.detached(priority: .utility) { [weak self] in
	            guard let self else { return }
	            let analysisQueue = (reason == .autoIdle) ? self.preanalysisQueue : self.normalizationQueue
	            var completed = 0
	            for url in targets {
                if Task.isCancelled { break }
                if self.currentVolumePreanalysisGeneration() != generation { break }
                await MainActor.run {
                    if self.currentVolumePreanalysisGeneration() != generation { return }
                    self.volumePreanalysisCurrentFileName = url.lastPathComponent
                }

	                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
	                    analysisQueue.async { [weak self] in
	                        guard let self else {
	                            continuation.resume()
	                            return
                        }
                        if self.currentVolumePreanalysisGeneration() != generation {
                            continuation.resume()
                            return
                        }
                        _ = self.calculateNormalizedVolume(
                            for: url,
                            cancellationCheck: { [weak self] in
                                guard let self else { return true }
                                return self.currentVolumePreanalysisGeneration() != generation
                            }
                        )
                        continuation.resume()
                    }
                }

                if Task.isCancelled { break }
                if self.currentVolumePreanalysisGeneration() != generation { break }
                completed += 1
                let completedSnapshot = completed
                let cacheCount = self.withVolumeCacheLock { self.fileLoudnessCache.count }
                await MainActor.run {
                    if self.currentVolumePreanalysisGeneration() != generation { return }
                    self.volumePreanalysisCompleted = completedSnapshot
                    self.volumeNormalizationCacheCount = cacheCount
                }
            }
            await MainActor.run {
                if self.currentVolumePreanalysisGeneration() != generation { return }
                self.isVolumePreanalysisRunning = false
                self.volumePreanalysisCurrentFileName = ""
                self.volumePreanalysisStartReason = .manual
            }
        }
    }

    func cancelVolumeNormalizationPreanalysis() {
        _ = bumpVolumePreanalysisGeneration()
        volumePreanalysisTask?.cancel()
        volumePreanalysisTask = nil
        volumePreanalysisStartReason = .manual
        DispatchQueue.main.async { [weak self] in
            self?.isVolumePreanalysisRunning = false
            self?.volumePreanalysisCurrentFileName = ""
        }
    }

    /// 读取用户主音量设置
    private func loadUserVolume() {
        let userDefaults = UserDefaults.standard
        if userDefaults.object(forKey: userVolumeKey) != nil {
            let stored = userDefaults.float(forKey: userVolumeKey)
            volume = max(0, min(1, stored))
        }
    }

    /// 保存用户主音量设置
    private func saveUserVolume() {
        let userDefaults = UserDefaults.standard
        userDefaults.set(volume, forKey: userVolumeKey)
    }

    /// 加载用户的播放控制开关
    private func loadUserPlaybackSwitches() {
        let d = UserDefaults.standard
        if d.object(forKey: userNormalizationKey) != nil {
            isNormalizationEnabled = d.bool(forKey: userNormalizationKey)
        }
        if d.object(forKey: userLoopingKey) != nil {
            isLooping = d.bool(forKey: userLoopingKey)
        }
        if d.object(forKey: userShuffleKey) != nil {
            isShuffling = d.bool(forKey: userShuffleKey)
        }
        // 互斥处理：如果两者都为 true，优先保留“循环”，关闭“随机”
        if isLooping && isShuffling {
            isShuffling = false
        }
        // 应用循环设置（如当前已有播放器）
        updateLoopSetting()
    }

    private func saveNormalizationPreference() {
        let d = UserDefaults.standard
        d.set(isNormalizationEnabled, forKey: userNormalizationKey)
    }

    private func saveLoopingPreference() {
        let d = UserDefaults.standard
        d.set(isLooping, forKey: userLoopingKey)
    }

    private func saveShufflePreference() {
        let d = UserDefaults.standard
        d.set(isShuffling, forKey: userShuffleKey)
    }

    // MARK: - 通知开关持久化
    private func loadNotifyOnDeviceSwitchPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userNotifyOnDeviceSwitchKey) != nil {
            notifyOnDeviceSwitch = d.bool(forKey: userNotifyOnDeviceSwitchKey)
        }
    }
    func saveNotifyOnDeviceSwitchPreference() {
        let d = UserDefaults.standard
        d.set(notifyOnDeviceSwitch, forKey: userNotifyOnDeviceSwitchKey)
    }

    private func loadNotifyDeviceSwitchSilentPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userNotifyDeviceSwitchSilentKey) != nil {
            notifyDeviceSwitchSilent = d.bool(forKey: userNotifyDeviceSwitchSilentKey)
        }
    }
    func saveNotifyDeviceSwitchSilentPreference() {
        let d = UserDefaults.standard
        d.set(notifyDeviceSwitchSilent, forKey: userNotifyDeviceSwitchSilentKey)
    }

    // MARK: - 文件路径辅助
    private func appSupportDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                debugLog("创建应用支持目录失败: \(error)")
                return nil
            }
        }
        return dir
    }

    private func volumeCacheURL() -> URL? {
        return appSupportDirectory()?.appendingPathComponent(volumeCacheFileName, isDirectory: false)
    }
}

extension Notification.Name {
    static let audioPlayerDidFinish = Notification.Name("audioPlayerDidFinish")
    static let loadLastPlayedFile = Notification.Name("loadLastPlayedFile")
    static let audioPlayerDidFailToPlay = Notification.Name("audioPlayerDidFailToPlay")
    static let audioPlayerDidLoadFile = Notification.Name("audioPlayerDidLoadFile")
}
