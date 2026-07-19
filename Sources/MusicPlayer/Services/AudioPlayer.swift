import Foundation
import AVFoundation
import Combine
import AppKit
import ImageIO

final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

private struct WeakAudioPlayerBox: @unchecked Sendable {
    weak var player: AudioPlayer?
}

private struct WeakAVAudioPlayerBox: @unchecked Sendable {
    weak var player: AVAudioPlayer?
}

final class AudioPlayer: NSObject, ObservableObject {
    enum PlaybackMode: String, CaseIterable, Sendable {
        case shuffle
        case repeatOne
    }

    let playbackClock = PlaybackClock()
    @Published var currentFile: AudioFile?
    @Published var isPlaying = false
    @Published private(set) var isPlaybackRequested = false
    @Published private(set) var pendingPlaybackURL: URL?
    @Published var volume: Float = 0.5
    @Published var playbackRate: Float = 1.0
    @Published private(set) var playbackMode: PlaybackMode = .shuffle
    var isLooping: Bool { playbackMode == .repeatOne }
    var isShuffling: Bool { playbackMode == .shuffle }
    @Published var isNormalizationEnabled = true  // 音量均衡开关
    @Published private(set) var isImmersivePlaybackEnabled = false
    // 歌词相关
    @Published var lyricsTimeline: LyricsTimeline? {
        didSet { refreshPlaybackTimerPrecisionIfNeeded() }
    }
    @Published var showLyrics: Bool = true {
        didSet { refreshPlaybackTimerPrecisionIfNeeded() }
    }
    // 当前曲目封面缩略图（低内存：仅保留缩放后的图，不保留原始 artwork Data）
    @Published var artworkImage: NSImage?
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
    private let immersivePlaybackAnalyzer: ImmersivePlaybackAnalyzer
    private var immersiveAnalysisTask: Task<Void, Never>?
    private var immersiveEndTask: Task<Void, Never>?
    private var pendingLateImmersiveBounds: (url: URL, bounds: PlaybackBounds)?
    private var unexpectedStopReconciliationTask: Task<Void, Never>?
    @Published private(set) var activePlaybackBounds: PlaybackBounds?
    private var completedLoadGeneration: UInt64?
    private let userImmersivePlaybackEnabledKey = "userImmersivePlaybackEnabled"
    var playbackFinishedHandler: ((UInt64, UInt64, URL?, Bool) -> Void)?
    var playbackFailedHandler: ((URL, String, Bool) -> Void)?
    var playbackLoadedHandler: ((URL, Bool) -> Void)?
    /// Test-only: when true, AVAudioPlayer.volume is forced to 0 to prevent audible output during tests.
    /// This preserves all playback state transitions while silencing actual audio output.
    var testModeSilent: Bool = false

    /// Test-only: returns the actual AVAudioPlayer.volume for verification.
    /// Returns nil if no player is loaded.
    var testActualPlayerVolume: Float? {
        player?.volume
    }
    // 移除未使用且可能干扰的 AVAudioEngine / PlayerNode，避免潜在路由或会话冲突
    // private let audioEngine = AVAudioEngine()
    // private let playerNode = AVAudioPlayerNode()
    // private let audioFile = AVAudioFile?.none
    
    private var lastSavedTime: TimeInterval = 0
    // Derived loudness data is persisted incrementally in SQLite. The in-memory
    // working set is bounded inside VolumeAnalysisStore and is never the source
    // of truth for a whole music library.
    private let volumeAnalysisStore: VolumeAnalysisStore?
    private let volumeAnalysisPersistenceAvailable: Bool
    private let volumeCacheEpochLock = NSLock()
    private var volumeCacheEpoch: UInt64 = 0
    private struct SessionLoudnessEntry {
        let snapshot: FileValidationSnapshot
        let measurement: LoudnessMeasurement
        var accessSequence: UInt64
    }
    private let sessionLoudnessLock = NSLock()
    private var sessionLoudnessEntries: [String: SessionLoudnessEntry] = [:]
    private var sessionLoudnessAccessSequence: UInt64 = 0
    private let sessionLoudnessCapacity = 128
    @Published private(set) var volumeNormalizationCacheCount: Int = 0
    private let normalizationQueue = DispatchQueue(label: "audio.normalization", qos: .utility)
    private let volumeAnalysisLock = NSLock()
    private var normalizationInFlight: Set<String> = []      // 避免同一文件重复分析
    private let volumeCacheKey = "volumeNormalizationCache"  // 旧版 UserDefaults 增益缓存迁移键
    private let playbackStateStore: PlaybackStateStore
    private let appPreferencesStore: AppPreferencesStore
    private let shouldPersistUserPreferences: Bool
    private var didNotifyProtectedCoherentPreferences = false
    @Published var analyzeVolumesDuringPlayback: Bool = false
    private let userAnalyzeVolumesDuringPlaybackKey = "userAnalyzeVolumesDuringPlayback"
    @Published var autoPreanalyzeVolumesWhenIdle: Bool = true
    private let userAutoPreanalyzeVolumesWhenIdleKey = "userAutoPreanalyzeVolumesWhenIdle"
    @Published private(set) var isVolumePreanalysisRunning: Bool = false
    @Published private(set) var volumePreanalysisTotal: Int = 0
    @Published private(set) var volumePreanalysisCompleted: Int = 0
    @Published private(set) var volumePreanalysisCurrentFileName: String = ""
    private var volumePreanalysisTask: Task<Void, Never>?
    private let volumePreanalysisGenerationLock = NSLock()
    private var volumePreanalysisGeneration: UInt64 = 0
    private let playbackAnalysisGenerationLock = NSLock()
    private var playbackAnalysisGeneration: UInt64 = 0
    @Published private(set) var lastUserInteractionAt: Date = Date()

    enum VolumePreanalysisStartReason {
        case manual
        case autoIdle
    }
    private enum VolumePreanalysisItemResult {
        case alreadyCached
        case analyzed
        case failed
    }
    private var volumePreanalysisStartReason: VolumePreanalysisStartReason = .manual

    var isAutoIdleVolumePreanalysisActive: Bool {
        volumePreanalysisStartReason == .autoIdle && volumePreanalysisTask != nil
    }
    private let userNormalizationKey = "userNormalizationEnabled" // 音量均衡开关
    private let normalizationTargetLock = NSLock()
    private var normalizationTargetSnapshot: Float = LoudnessNormalizationPolicy.defaultTargetLUFS
    @Published var normalizationTargetLUFS: Float = LoudnessNormalizationPolicy.defaultTargetLUFS {
        didSet {
            normalizationTargetLock.lock()
            normalizationTargetSnapshot = normalizationTargetLUFS
            normalizationTargetLock.unlock()
        }
    }
    private let userNormalizationTargetLUFSKey = "userNormalizationTargetLUFS"
    // IPC compatibility while clients migrate from the historical RMS name.
    var normalizationTargetLevelDb: Float {
        get { normalizationTargetLUFS }
        set { normalizationTargetLUFS = newValue }
    }
    @Published var normalizationFadeDuration: Double = 0.6 // 应用均衡增益时的淡入时长（秒）
    private let userNormalizationFadeDurationKey = "userNormalizationFadeDuration"
    @Published var requireVolumeAnalysisBeforePlayback: Bool = false // 无缓存时先分析再播放
    private let userRequireVolumeAnalysisBeforePlaybackKey = "userRequireVolumeAnalysisBeforePlayback"
    private var wasPlayingBeforeInterruption = false
    // 在耳机/路由变化导致的自动暂停后，记录是否应在耳机恢复时自动续播
    var shouldAutoResumeAfterRoute: Bool = false
    // 控制是否将当前播放状态（上次播放文件/进度）持久化；用于“外部打开文件（临时播放）”场景
    @Published var persistPlaybackState: Bool = true
    // 标记本次启动是否应跳过“恢复上次播放”（用于 Finder/Dock 外部打开文件启动的场景）
    private var skipRestoreThisLaunch: Bool = false
    // 在播放器尚未就绪时记录一次性预设进度，并绑定目标 URL，避免慢加载
    // 被另一首曲目覆盖后把旧进度串到新播放器。
    private enum PendingSeekSource: Equatable {
        case restore
        case user
        case reloadBaseline
    }
    private struct PendingSeekRequest {
        let url: URL
        let time: TimeInterval
        let source: PendingSeekSource
    }
    private var pendingSeekRequest: PendingSeekRequest?
    // 用于避免“快速切歌/重载”时旧异步任务回写覆盖新状态
    private var loadGeneration: UInt64 = 0
    private var activePlayerGeneration: UInt64 = 0
    private var completionEventSequence: UInt64 = 0
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

    private func currentNormalizationTargetLUFS() -> Float {
        normalizationTargetLock.lock()
        defer { normalizationTargetLock.unlock() }
        return normalizationTargetSnapshot
    }

    /// 用于“跨启动恢复/初始定位”的 seek time 规整：
    /// - 若 time 明显超出 duration（例如来自上一首歌的残留进度），则回退到 0，避免被 clamp 到末尾导致“进度拉到最后”。
    /// - 另外避免设置到精确 duration（部分情况下会表现为立刻播放完）。
    private func clampInitialSeekTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        guard time.isFinite else { return 0 }
        if time > duration + 1.0 { return 0 }
        let safeMax = Swift.max(0, duration - 0.05)
        return clamp(time, min: 0, max: safeMax)
    }

    private func clampPlaybackRate(_ value: Float) -> Float {
        clamp(value, min: 0.5, max: 2.0)
    }

    private func volumeCacheKey(for url: URL) -> String {
        PathKey.canonical(for: url)
    }

    private func volumeCacheLookupKeys(for url: URL) -> [String] {
        PathKey.lookupKeys(for: url)
    }

    private func cachedLoudnessMeasurement(for url: URL) -> LoudnessMeasurement? {
        if let session = sessionLoudnessMeasurement(for: url) {
            return session
        }
        let snapshot = FileValidationSnapshot.load(for: url)
        guard let measurement = volumeAnalysisStore?.measurement(for: url) else { return nil }
        storeSessionLoudness(measurement, for: url, snapshot: snapshot)
        return measurement
    }

    private func sessionLoudnessMeasurement(for url: URL) -> LoudnessMeasurement? {
        let key = volumeCacheKey(for: url)
        let snapshot = FileValidationSnapshot.load(for: url)
        sessionLoudnessLock.lock()
        sessionLoudnessAccessSequence &+= 1
        if var entry = sessionLoudnessEntries[key] {
            guard entry.snapshot == snapshot else {
                sessionLoudnessEntries.removeValue(forKey: key)
                sessionLoudnessLock.unlock()
                return nil
            }
            entry.accessSequence = sessionLoudnessAccessSequence
            sessionLoudnessEntries[key] = entry
            sessionLoudnessLock.unlock()
            return entry.measurement
        }
        sessionLoudnessLock.unlock()
        return nil
    }

    private func storeSessionLoudness(
        _ measurement: LoudnessMeasurement,
        for url: URL,
        snapshot: FileValidationSnapshot
    ) {
        let key = volumeCacheKey(for: url)
        sessionLoudnessLock.lock()
        sessionLoudnessAccessSequence &+= 1
        sessionLoudnessEntries[key] = SessionLoudnessEntry(
            snapshot: snapshot,
            measurement: measurement,
            accessSequence: sessionLoudnessAccessSequence
        )
        if sessionLoudnessEntries.count > sessionLoudnessCapacity,
           let oldest = sessionLoudnessEntries.min(by: {
               if $0.value.accessSequence == $1.value.accessSequence { return $0.key < $1.key }
               return $0.value.accessSequence < $1.value.accessSequence
           })?.key {
            sessionLoudnessEntries.removeValue(forKey: oldest)
        }
        sessionLoudnessLock.unlock()
    }

    private func clearSessionLoudnessCache() {
        sessionLoudnessLock.lock()
        sessionLoudnessEntries.removeAll(keepingCapacity: false)
        sessionLoudnessAccessSequence = 0
        sessionLoudnessLock.unlock()
    }

    private func currentVolumeCacheEpoch() -> UInt64 {
        volumeCacheEpochLock.lock()
        defer { volumeCacheEpochLock.unlock() }
        return volumeCacheEpoch
    }

    @discardableResult
    private func bumpVolumeCacheEpoch() -> UInt64 {
        volumeCacheEpochLock.lock()
        defer { volumeCacheEpochLock.unlock() }
        volumeCacheEpoch &+= 1
        return volumeCacheEpoch
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
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

    @discardableResult
    private func bumpPlaybackAnalysisGeneration() -> UInt64 {
        playbackAnalysisGenerationLock.lock()
        defer { playbackAnalysisGenerationLock.unlock() }
        playbackAnalysisGeneration &+= 1
        return playbackAnalysisGeneration
    }

    private func currentPlaybackAnalysisGeneration() -> UInt64 {
        playbackAnalysisGenerationLock.lock()
        defer { playbackAnalysisGenerationLock.unlock() }
        return playbackAnalysisGeneration
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
        guard volumePreanalysisStartReason == .autoIdle else { return }
        cancelVolumeNormalizationPreanalysis()
    }

    private static var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTest.XCTestCase") != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func makeDefaultVolumeAnalysisStore() -> VolumeAnalysisStore? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("MusicPlayer", isDirectory: true)
        let databaseURL = directory.appendingPathComponent(
            "volume-analysis.sqlite3",
            isDirectory: false
        )
        let legacyURL = directory.appendingPathComponent("volume-cache.json", isDirectory: false)
        do {
            return try VolumeAnalysisStore(databaseURL: databaseURL, legacyJSONURL: legacyURL)
        } catch {
            PersistenceLogger.log("初始化音量分析数据库失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func makeVolumeAnalysisStore(
        legacyOrDatabaseURL url: URL,
        analysisCapacity: Int,
        now: @escaping @Sendable () -> TimeInterval
    ) -> VolumeAnalysisStore? {
        let isDatabase = url.pathExtension.lowercased() == "sqlite3"
        let databaseURL = isDatabase
            ? url
            : url.deletingPathExtension().appendingPathExtension("sqlite3")
        do {
            return try VolumeAnalysisStore(
                databaseURL: databaseURL,
                legacyJSONURL: isDatabase ? nil : url,
                analysisCapacity: analysisCapacity,
                now: now
            )
        } catch {
            PersistenceLogger.log("初始化测试音量分析数据库失败：\(error.localizedDescription)")
            return nil
        }
    }

    override init() {
        let isTesting = Self.isRunningUnderXCTest
        immersivePlaybackAnalyzer = isTesting
            ? ImmersivePlaybackAnalyzer(cacheFileURL: nil)
            : ImmersivePlaybackAnalyzer()
        let volumeStore = isTesting ? nil : Self.makeDefaultVolumeAnalysisStore()
        volumeAnalysisStore = volumeStore
        volumeAnalysisPersistenceAvailable = isTesting || volumeStore != nil
        playbackStateStore = PlaybackStateStore(disablesPersistence: isTesting)
        appPreferencesStore = .shared
        shouldPersistUserPreferences = !isTesting
        super.init()
        testModeSilent = isTesting
        finishInitialization(loadUserPreferences: !isTesting)
    }

    init(
        volumeCacheFileURLOverride: URL,
        immersiveCacheFileURLOverride: URL? = nil,
        initialImmersivePlaybackEnabled: Bool = false,
        volumeAnalysisCapacity: Int = 20_000,
        volumeAnalysisNow: @escaping @Sendable () -> TimeInterval = {
            Date().timeIntervalSince1970
        },
        appPreferencesStore: AppPreferencesStore = .shared,
        loadUserPreferences: Bool = false,
        immersivePlaybackAnalyzerOverride: ImmersivePlaybackAnalyzer? = nil
    ) {
        immersivePlaybackAnalyzer = immersivePlaybackAnalyzerOverride
            ?? ImmersivePlaybackAnalyzer(cacheFileURL: immersiveCacheFileURLOverride)
        let volumeStore = Self.makeVolumeAnalysisStore(
            legacyOrDatabaseURL: volumeCacheFileURLOverride,
            analysisCapacity: volumeAnalysisCapacity,
            now: volumeAnalysisNow
        )
        volumeAnalysisStore = volumeStore
        volumeAnalysisPersistenceAvailable = volumeStore != nil
        playbackStateStore = PlaybackStateStore(disablesPersistence: true)
        self.appPreferencesStore = appPreferencesStore
        shouldPersistUserPreferences = loadUserPreferences
        super.init()
        testModeSilent = Self.isRunningUnderXCTest
        isImmersivePlaybackEnabled = initialImmersivePlaybackEnabled
        finishInitialization(loadUserPreferences: loadUserPreferences)
    }

    private func finishInitialization(loadUserPreferences: Bool) {
        configureAudioSession()
        observeAudioSessionNotifications()
        volumeNormalizationCacheCount = 0
        if let volumeAnalysisStore {
            normalizationQueue.async { [weak self] in
                let count = volumeAnalysisStore.analysisCount
                DispatchQueue.main.async {
                    self?.volumeNormalizationCacheCount = count
                }
            }
        } else if !volumeAnalysisPersistenceAvailable {
            PersistenceLogger.log("音量分析数据库不可用，已降级为有界会话缓存")
            DispatchQueue.main.async {
                PersistenceLogger.notifyUser(
                    title: "音量分析缓存不可写",
                    subtitle: "当前播放仍会均衡，重启后可能需要重新分析"
                )
            }
        }
        guard loadUserPreferences else { return }
        loadCoherentPlayerPreferences()
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
        if !analyzeVolumesDuringPlayback {
            _ = bumpPlaybackAnalysisGeneration()
        }
        let d = UserDefaults.standard
        d.set(analyzeVolumesDuringPlayback, forKey: userAnalyzeVolumesDuringPlaybackKey)
    }

    func saveAutoPreanalyzeVolumesWhenIdlePreference() {
        let d = UserDefaults.standard
        d.set(autoPreanalyzeVolumesWhenIdle, forKey: userAutoPreanalyzeVolumesWhenIdleKey)
    }

    private func loadNormalizationTargetLevelPreference() {
        let d = UserDefaults.standard
        if d.object(forKey: userNormalizationTargetLUFSKey) != nil {
            let v = d.float(forKey: userNormalizationTargetLUFSKey)
            normalizationTargetLUFS = clamp(v, min: -30.0, max: -8.0)
        }
    }

    func saveNormalizationTargetLevelPreference() {
        normalizationTargetLUFS = clamp(normalizationTargetLUFS, min: -30.0, max: -8.0)
        let d = UserDefaults.standard
        d.set(normalizationTargetLUFS, forKey: userNormalizationTargetLUFSKey)
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
    private var pendingLoadGeneration: UInt64?
    private var pendingPlaybackPersistsState: Bool?
    private var pendingResumeTask: Task<Void, Never>?
    private var resumeRequestGeneration: UInt64 = 0
    private var playbackIntentGeneration: UInt64 = 0
    private struct DeferredTerminalReplay {
        let generation: UInt64
        let url: URL
        let bypassConfirm: Bool
        let intentGeneration: UInt64
    }
    private var deferredTerminalReplay: DeferredTerminalReplay?
    private var deferredTerminalReplayFallbackTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var artworkAttemptedPathKey: String? = nil

    /// The track the user most recently selected. During an asynchronous load this
    /// intentionally differs from `currentFile`, which remains the installed player.
    var playbackTargetURL: URL? {
        pendingPlaybackURL ?? currentFile?.url
    }

    var canTogglePlayback: Bool {
        playbackTargetURL != nil
    }

    private func clearPendingLoadTask(ifCurrent generation: UInt64) {
        guard pendingLoadGeneration == generation else { return }
        pendingLoadTask = nil
        pendingLoadGeneration = nil
        pendingPlaybackURL = nil
        pendingPlaybackPersistsState = nil
    }

    /// Rebinds the installed AVAudioPlayer after a replacement request is
    /// cancelled or fails. The underlying player may have recovered from a
    /// transient route stop while the old reconciliation task was waiting, so
    /// transport UI and the timer must be synchronized from the player itself.
    private func rebindInstalledPlayer(
        to generation: UInt64,
        hadCompleted: Bool
    ) {
        guard let installedPlayer = player else { return }
        cancelUnexpectedStopReconciliation()
        activePlayerGeneration = generation
        completedLoadGeneration = hadCompleted ? generation : nil
        playbackClock.currentTime = installedPlayer.currentTime
        playbackClock.duration = installedPlayer.duration

        if installedPlayer.isPlaying {
            isPlaying = true
            startTimer()
        } else {
            isPlaying = false
            stopTimer()
            if isPlaybackRequested, completedLoadGeneration != generation {
                reconcileUnexpectedStop(of: installedPlayer, generation: generation)
            }
        }

        if isImmersivePlaybackEnabled {
            analyzeBoundsForCurrentTrack()
        }
        scheduleImmersiveEndIfNeeded()
    }

    /// A failed request leaves the installed player intact. Rebind that player to the
    /// latest request generation so a later resume can still route its completion.
    private func finishPendingLoadFailure(ifCurrent generation: UInt64) {
        guard pendingLoadGeneration == generation else { return }
        let failedURL = pendingPlaybackURL
        let activePlayerHadCompleted = completedLoadGeneration == activePlayerGeneration
        pendingLoadTask = nil
        pendingLoadGeneration = nil
        pendingPlaybackURL = nil
        pendingPlaybackPersistsState = nil
        if pendingSeekRequest?.url == failedURL {
            pendingSeekRequest = nil
        }
        rebindInstalledPlayer(
            to: generation,
            hadCompleted: activePlayerHadCompleted
        )
    }

    private func resolvePreservedPlayerAfterReloadFailure(generation: UInt64, url: URL) {
        guard generation == loadGeneration else { return }
        guard completedLoadGeneration == generation else {
            if isPlaybackRequested, !isPlaying {
                resume(bypassConfirm: true)
            }
            return
        }
        guard isPlaybackRequested else { return }

        if isLooping {
            resume(bypassConfirm: true)
        } else {
            setPlaybackIntent(false)
            postPlaybackFinished(
                generation: generation,
                url: url,
                persist: persistPlaybackState
            )
        }
    }

    /// Cancels a superseded selection while keeping the installed player usable.
    /// A fresh generation prevents the cancelled task from committing later, and
    /// rebinds completion routing to the player that remains installed.
    @discardableResult
    private func cancelPendingLoadPreservingCurrentPlayer() -> Bool {
        guard pendingLoadGeneration != nil else { return false }
        let cancelledURL = pendingPlaybackURL
        let activePlayerHadCompleted = completedLoadGeneration == activePlayerGeneration
        pendingLoadTask?.cancel()
        pendingLoadTask = nil
        pendingLoadGeneration = nil
        pendingPlaybackURL = nil
        pendingPlaybackPersistsState = nil
        if pendingSeekRequest?.url == cancelledURL {
            pendingSeekRequest = nil
        }
        invalidateResumeRequest()
        let generation = nextLoadGeneration()
        if player != nil {
            rebindInstalledPlayer(
                to: generation,
                hadCompleted: activePlayerHadCompleted
            )
        }
        return true
    }

    @discardableResult
    private func setPlaybackIntent(_ requested: Bool) -> UInt64 {
        isPlaybackRequested = requested
        playbackIntentGeneration &+= 1
        return playbackIntentGeneration
    }

    @discardableResult
    private func invalidateResumeRequest() -> UInt64 {
        pendingResumeTask?.cancel()
        pendingResumeTask = nil
        resumeRequestGeneration &+= 1
        return resumeRequestGeneration
    }

    private func cancelUnexpectedStopReconciliation() {
        unexpectedStopReconciliationTask?.cancel()
        unexpectedStopReconciliationTask = nil
    }

    private func reconcileUnexpectedStop(
        of capturedPlayer: AVAudioPlayer,
        generation: UInt64
    ) {
        cancelUnexpectedStopReconciliation()
        unexpectedStopReconciliationTask = Task { @MainActor [weak self, weak capturedPlayer] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, let capturedPlayer else { return }
            self.unexpectedStopReconciliationTask = nil
            guard self.player === capturedPlayer,
                  self.activePlayerGeneration == generation,
                  self.completedLoadGeneration != generation else { return }

            if capturedPlayer.isPlaying {
                guard self.isPlaybackRequested else {
                    // The device may resume the underlying player after the user
                    // (or a failed replacement) has already settled on pause.
                    // Keep transport intent authoritative instead of allowing
                    // inaudible UI state to diverge from actual output.
                    capturedPlayer.pause()
                    self.isPlaying = false
                    self.saveCurrentProgress()
                    self.stopTimer()
                    return
                }
                self.isPlaying = true
                self.startTimer()
                self.scheduleImmersiveEndIfNeeded()
                return
            }

            // A newer selection owns playback intent. The old player stopping must
            // not turn that pending autostart request into a paused load.
            guard generation == self.loadGeneration,
                  self.pendingPlaybackURL == nil else {
                self.isPlaying = false
                self.saveCurrentProgress()
                self.stopTimer()
                return
            }

            // AVAudioPlayer can reach EOF without delivering its delegate callback.
            // Reuse the normal terminal path near the logical end; otherwise settle
            // into a resumable paused state after a route/system interruption.
            let end = self.effectivePlaybackEndTime
            if end > 0, capturedPlayer.currentTime >= max(0, end - 0.15) {
                self.handlePlayerFinishedOnMain(capturedPlayer, successfully: true)
                return
            }
            self.setPlaybackIntent(false)
            self.isPlaying = false
            self.saveCurrentProgress()
            self.stopTimer()
        }
    }

    private func deferReplayUntilPendingTerminalCallback(
        url: URL,
        bypassConfirm: Bool
    ) {
        guard player != nil, currentFile?.url == url else { return }
        immersiveEndTask?.cancel()
        immersiveEndTask = nil
        let intentGeneration = setPlaybackIntent(false)
        isPlaying = false
        stopTimer()
        let replay = DeferredTerminalReplay(
            generation: activePlayerGeneration,
            url: url,
            bypassConfirm: bypassConfirm,
            intentGeneration: intentGeneration
        )
        deferredTerminalReplay = replay
        deferredTerminalReplayFallbackTask?.cancel()
        deferredTerminalReplayFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let pending = self.deferredTerminalReplay,
                  pending.generation == replay.generation,
                  pending.url == replay.url,
                  pending.intentGeneration == replay.intentGeneration else { return }
            self.deferredTerminalReplay = nil
            self.deferredTerminalReplayFallbackTask = nil
            self.completedLoadGeneration = replay.generation
            guard replay.generation == self.activePlayerGeneration,
                  replay.generation == self.loadGeneration,
                  replay.url == self.currentFile?.url,
                  replay.intentGeneration == self.playbackIntentGeneration,
                  self.pendingPlaybackURL == nil else { return }
            self.resume(bypassConfirm: replay.bypassConfirm)
        }
    }

    private func consumeDeferredTerminalReplayIfNeeded(
        generation: UInt64,
        url: URL?
    ) -> Bool {
        guard let replay = deferredTerminalReplay,
              replay.generation == generation,
              replay.url == url else { return false }
        deferredTerminalReplay = nil
        deferredTerminalReplayFallbackTask?.cancel()
        deferredTerminalReplayFallbackTask = nil
        completedLoadGeneration = generation
        isPlaying = false
        stopTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard replay.generation == self.activePlayerGeneration,
                  replay.generation == self.loadGeneration,
                  replay.url == self.currentFile?.url,
                  replay.intentGeneration == self.playbackIntentGeneration,
                  self.pendingPlaybackURL == nil else { return }
            self.resume(bypassConfirm: replay.bypassConfirm)
        }
        return true
    }

    // MARK: - Next-track preloading (reduce gaps between tracks)
    private struct PreloadedNext {
        let url: URL
        let player: AVAudioPlayer
        let playbackBounds: PlaybackBounds?
        let generation: UInt64
    }
    private let preloadLock = NSLock()
    private var nextPreloadTask: Task<Void, Never>?
    private var preloadedNext: PreloadedNext? = nil
    private var preloadGeneration: UInt64 = 0
    private var preloadTargetURL: URL?

    /// Test/diagnostic visibility for the single prepared handoff. The player
    /// itself stays private so callers cannot mutate transport state off-main.
    var preparedNextTrackURL: URL? {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        return preloadedNext?.url
    }

    private func preloadedEntryIfMatching(url: URL) -> PreloadedNext? {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        guard let entry = preloadedNext, entry.url == url else { return nil }
        return entry
    }

    private func consumePreloadedEntryIfMatching(url: URL) -> PreloadedNext? {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        guard let entry = preloadedNext, entry.url == url else { return nil }
        preloadedNext = nil
        preloadTargetURL = nil
        return entry
    }

    @discardableResult
    private func resetPreloadedNext() -> UInt64 {
        preloadLock.lock()
        preloadGeneration &+= 1
        preloadedNext = nil
        preloadTargetURL = nil
        let generation = preloadGeneration
        preloadLock.unlock()
        return generation
    }

    private func storePreloadedNext(
        url: URL,
        player: AVAudioPlayer,
        playbackBounds: PlaybackBounds?,
        generation: UInt64
    ) {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        guard generation == preloadGeneration else { return }
        preloadedNext = PreloadedNext(
            url: url,
            player: player,
            playbackBounds: playbackBounds,
            generation: generation
        )
    }

    private func updatePreloadedBoundsIfMatching(
        _ bounds: PlaybackBounds,
        url: URL,
        player: AVAudioPlayer,
        generation: UInt64
    ) {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        guard generation == preloadGeneration,
              let entry = preloadedNext,
              entry.generation == generation,
              entry.url == url,
              entry.player === player else { return }
        preloadedNext = PreloadedNext(
            url: entry.url,
            player: entry.player,
            playbackBounds: bounds,
            generation: entry.generation
        )
    }

    private func beginPreload(for url: URL) -> UInt64 {
        preloadLock.lock()
        preloadGeneration &+= 1
        preloadedNext = nil
        preloadTargetURL = url
        let generation = preloadGeneration
        preloadLock.unlock()
        return generation
    }

    private func markPreloadFailed(generation: UInt64) {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        guard generation == preloadGeneration else { return }
        preloadedNext = nil
        preloadTargetURL = nil
    }

    func hasNextPreloadPlan(for url: URL) -> Bool {
        preloadLock.lock()
        defer { preloadLock.unlock() }
        return preloadTargetURL == url
    }

    func cancelNextPreload() {
        nextPreloadTask?.cancel()
        nextPreloadTask = nil
        resetPreloadedNext()
    }

    /// 预加载“下一首”的 AVAudioPlayer（并按需提前写入音量均衡缓存）。
    /// - 目标：减少曲目切换时的空隙；尽量不增加常驻内存（仅保留 1 个预加载播放器）。
    func preloadNextTrack(_ file: AudioFile) {
        let url = file.url

        // 已预加载同一首：不重复
        if preloadedEntryIfMatching(url: url) != nil { return }

        // 只保留一个预加载实例：新目标到来时取消旧任务并丢弃旧预加载
        nextPreloadTask?.cancel()
        let generation = beginPreload(for: url)

        // 捕获当前设置（避免后台线程直接读取 @Published）
        let capturedRate = playbackRate
        let capturedNormalizationEnabled = isNormalizationEnabled
        let capturedRequireAnalysisBeforePlayback = requireVolumeAnalysisBeforePlayback
        let capturedImmersivePlaybackEnabled = isImmersivePlaybackEnabled
        let shouldPrewarmNormalization = capturedNormalizationEnabled && capturedRequireAnalysisBeforePlayback && !hasVolumeNormalizationCache(for: url)

        nextPreloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }

            // 1) Prepare AVAudioPlayer
            do {
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
                p.numberOfLoops = 0
                p.enableRate = true
                p.rate = self.clampPlaybackRate(capturedRate)
                p.prepareToPlay()

                if Task.isCancelled { return }
                let playbackBounds: PlaybackBounds?
                if capturedImmersivePlaybackEnabled {
                    playbackBounds = await self.immersivePlaybackAnalyzer.bounds(
                        for: url,
                        onLateBounds: { [weak self, weak p] bounds in
                            guard let self, let p else { return }
                            self.updatePreloadedBoundsIfMatching(
                                bounds,
                                url: url,
                                player: p,
                                generation: generation
                            )
                            self.handleLateImmersiveBounds(
                                bounds,
                                for: url,
                                player: p
                            )
                        }
                    )
                } else {
                    playbackBounds = nil
                }
                if Task.isCancelled { return }
                self.storePreloadedNext(
                    url: url,
                    player: p,
                    playbackBounds: playbackBounds,
                    generation: generation
                )
            } catch {
                self.markPreloadFailed(generation: generation)
                return
            }

            if Task.isCancelled { return }

            // 2) Optional: prewarm volume normalization cache so "require analysis before playback" won't block next track.
            if shouldPrewarmNormalization {
                _ = self.calculateNormalizedVolume(for: url, persist: true, cancellationCheck: { Task.isCancelled })
            }
        }
    }

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

    private func retireCurrentPlayerForReplacement() -> AVAudioPlayer? {
        let previousPlayer = player
        cancelUnexpectedStopReconciliation()
        saveCurrentProgress()
        immersiveEndTask?.cancel()
        immersiveEndTask = nil
        volumeRampTask?.cancel()
        volumeRampTask = nil
        previousPlayer?.pause()
        isPlaying = false
        stopTimer()
        playbackClock.currentTime = 0
        activePlaybackBounds = nil
        return previousPlayer
    }

    private func applyLoadedPlaybackBounds(
        _ analyzedBounds: PlaybackBounds?,
        to loadedPlayer: AVAudioPlayer,
        url: URL
    ) {
        let bounds = isImmersivePlaybackEnabled
            ? validatedPlaybackBounds(analyzedBounds, duration: loadedPlayer.duration)
            : PlaybackBounds.fullRange(duration: loadedPlayer.duration)
        activePlaybackBounds = isImmersivePlaybackEnabled ? bounds : nil
        completedLoadGeneration = nil

        let requestedTime: TimeInterval?
        if let request = pendingSeekRequest, request.url == url {
            requestedTime = clampInitialSeekTime(request.time, duration: loadedPlayer.duration)
        } else {
            requestedTime = nil
        }
        let initialTime = ImmersivePlaybackPolicy.initialPosition(
            requested: requestedTime,
            bounds: bounds,
            isEnabled: isImmersivePlaybackEnabled
        )
        loadedPlayer.currentTime = initialTime
        playbackClock.currentTime = initialTime
        pendingSeekRequest = nil
    }

    private func validatedPlaybackBounds(
        _ analyzedBounds: PlaybackBounds?,
        duration: TimeInterval
    ) -> PlaybackBounds {
        let fullRange = PlaybackBounds.fullRange(duration: duration)
        guard let analyzedBounds else { return fullRange }
        let durationTolerance = max(0.25, duration * 0.005)
        guard analyzedBounds.physicalDuration.isFinite,
              abs(analyzedBounds.physicalDuration - duration) <= durationTolerance,
              analyzedBounds.audibleStart.isFinite,
              analyzedBounds.audibleEnd.isFinite,
              analyzedBounds.audibleStart >= 0,
              analyzedBounds.audibleEnd > analyzedBounds.audibleStart,
              analyzedBounds.audibleEnd <= duration + durationTolerance else {
            return fullRange
        }
        return PlaybackBounds(
            audibleStart: min(analyzedBounds.audibleStart, duration),
            audibleEnd: min(analyzedBounds.audibleEnd, duration),
            physicalDuration: duration
        )
    }

    private func handleLateImmersiveBounds(
        _ bounds: PlaybackBounds,
        for url: URL,
        player capturedPlayer: AVAudioPlayer
    ) {
        let owner = WeakAudioPlayerBox(player: self)
        let playerBox = WeakAVAudioPlayerBox(player: capturedPlayer)
        Task { @MainActor in
            guard let self = owner.player else { return }
            guard self.isImmersivePlaybackEnabled else { return }

            guard let currentPlayer = playerBox.player,
                  self.player === currentPlayer,
                  self.currentFile?.url == url else {
                if self.pendingPlaybackURL == url {
                    self.pendingLateImmersiveBounds = (url, bounds)
                }
                return
            }
            guard self.completedLoadGeneration != self.activePlayerGeneration else { return }

            let validatedBounds = self.validatedPlaybackBounds(
                bounds,
                duration: currentPlayer.duration
            )
            self.activePlaybackBounds = validatedBounds
            currentPlayer.numberOfLoops = 0
            if currentPlayer.currentTime < validatedBounds.audibleStart {
                currentPlayer.currentTime = validatedBounds.audibleStart
                self.playbackClock.currentTime = validatedBounds.audibleStart
            }
            self.scheduleImmersiveEndIfNeeded()
        }
    }

    private func analyzeBoundsForCurrentTrack() {
        immersiveAnalysisTask?.cancel()
        immersiveAnalysisTask = nil
        guard isImmersivePlaybackEnabled,
              let url = currentFile?.url,
              let capturedPlayer = player
        else { return }

        let generation = activePlayerGeneration
        immersiveAnalysisTask = Task { [weak self] in
            guard let self else { return }
            let bounds = await self.immersivePlaybackAnalyzer.bounds(
                for: url,
                onLateBounds: { [weak self, weak capturedPlayer] bounds in
                    guard let self, let capturedPlayer else { return }
                    self.handleLateImmersiveBounds(
                        bounds,
                        for: url,
                        player: capturedPlayer
                    )
                }
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.isImmersivePlaybackEnabled else { return }
                guard generation == self.loadGeneration else { return }
                guard self.player === capturedPlayer, self.currentFile?.url == url else { return }

                let validatedBounds = self.validatedPlaybackBounds(
                    bounds,
                    duration: capturedPlayer.duration
                )
                self.activePlaybackBounds = validatedBounds
                self.completedLoadGeneration = nil
                capturedPlayer.numberOfLoops = 0
                if capturedPlayer.currentTime < validatedBounds.audibleStart {
                    capturedPlayer.currentTime = validatedBounds.audibleStart
                    self.playbackClock.currentTime = validatedBounds.audibleStart
                }
                self.scheduleImmersiveEndIfNeeded()
            }
        }
    }

    private func scheduleImmersiveEndIfNeeded() {
        immersiveEndTask?.cancel()
        immersiveEndTask = nil
        guard isImmersivePlaybackEnabled,
              isPlaying,
              completedLoadGeneration != activePlayerGeneration,
              let bounds = activePlaybackBounds,
              let capturedPlayer = player,
              let url = currentFile?.url
        else { return }

        let generation = activePlayerGeneration
        let mediaSecondsRemaining = max(0, bounds.audibleEnd - capturedPlayer.currentTime)
        let effectiveRate = max(0.5, Double(capturedPlayer.rate))
        let delaySeconds = mediaSecondsRemaining / effectiveRate
        immersiveEndTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delaySeconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(delaySeconds, 86_400) * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard generation == self.loadGeneration else { return }
            guard self.player === capturedPlayer, self.currentFile?.url == url else { return }

            if capturedPlayer.currentTime < bounds.audibleEnd - 0.02 {
                self.scheduleImmersiveEndIfNeeded()
                return
            }
            self.completeImmersiveBoundaryIfNeeded(
                player: capturedPlayer,
                bounds: bounds,
                generation: generation,
                url: url
            )
        }
    }

    private func completeImmersiveBoundaryIfNeeded(
        player capturedPlayer: AVAudioPlayer,
        bounds: PlaybackBounds,
        generation: UInt64,
        url: URL
    ) {
        guard generation == loadGeneration else { return }
        guard player === capturedPlayer, currentFile?.url == url else { return }
        guard completedLoadGeneration != generation else { return }

        let action = ImmersivePlaybackPolicy.endAction(
            isEnabled: isImmersivePlaybackEnabled,
            isPlaying: isPlaying,
            isLooping: isLooping,
            isPersistentPlayback: persistPlaybackState,
            currentTime: capturedPlayer.currentTime,
            bounds: bounds
        )
        switch action {
        case .none:
            scheduleImmersiveEndIfNeeded()
        case .loopToStart:
            capturedPlayer.currentTime = bounds.audibleStart
            playbackClock.currentTime = bounds.audibleStart
            lastSavedTime = bounds.audibleStart
            let didContinue = capturedPlayer.isPlaying || capturedPlayer.play()
            guard didContinue else {
                completedLoadGeneration = generation
                setPlaybackIntent(false)
                isPlaying = false
                stopTimer()
                postPlaybackFailure(
                    url: url,
                    message: "无法继续循环播放：\(url.lastPathComponent)",
                    persist: persistPlaybackState
                )
                return
            }
            isPlaying = true
            startTimer()
            scheduleImmersiveEndIfNeeded()
        case .advance, .stop:
            completedLoadGeneration = generation
            setPlaybackIntent(false)
            capturedPlayer.pause()
            playbackClock.currentTime = bounds.audibleEnd
            isPlaying = false
            stopTimer()
            saveCurrentProgress()
            if action == .stop {
                capturedPlayer.stop()
            }
            postPlaybackFinished(generation: generation, url: url, persist: persistPlaybackState)
        }
    }

    private func postPlaybackFinished(generation: UInt64, url: URL?, persist: Bool) {
        completionEventSequence &+= 1
        let completionEventID = completionEventSequence
        playbackFinishedHandler?(generation, completionEventID, url, persist)
        var userInfo: [String: Any] = [
            "playbackGeneration": generation,
            "completionEventID": completionEventID,
            "persist": persist
        ]
        if let url { userInfo["url"] = url }
        NotificationCenter.default.post(
            name: .audioPlayerDidFinish,
            object: nil,
            userInfo: userInfo
        )
    }

    private func postPlaybackFailure(url: URL, message: String, persist: Bool) {
        playbackFailedHandler?(url, message, persist)
        NotificationCenter.default.post(
            name: .audioPlayerDidFailToPlay,
            object: nil,
            userInfo: [
                "url": url,
                "message": message,
                "persist": persist
            ]
        )
    }

    private func postPlaybackLoaded(url: URL, persist: Bool) {
        playbackLoadedHandler?(url, persist)
        NotificationCenter.default.post(
            name: .audioPlayerDidLoadFile,
            object: nil,
            userInfo: [
                "url": url,
                "persist": persist
            ]
        )
    }

    func play(_ file: AudioFile, persist: Bool = true, bypassConfirm: Bool = false) {
        // 兼容旧签名：默认自动开始播放
        play(file, autostart: true, persist: persist, bypassConfirm: bypassConfirm)
    }

    /// Handles an explicit track selection without restarting the same request.
    /// This is the single selection entry point for list and IPC surfaces because
    /// `currentFile` can still describe the old player while a new file is loading.
    func selectOrResume(
        _ file: AudioFile,
        persist: Bool = true,
        bypassConfirm: Bool = false
    ) {
        if pendingPlaybackURL == file.url,
           pendingPlaybackPersistsState == persist {
            if !isPlaybackRequested {
                resume(bypassConfirm: bypassConfirm)
            }
            return
        }

        if currentFile?.url == file.url {
            let wasAwaitingTerminalCallback = isPlaying && player?.isPlaying == false
            let cancelledDifferentSelection = cancelPendingLoadPreservingCurrentPlayer()
            if persistPlaybackState != persist {
                persistPlaybackState = persist
                if persist {
                    saveLastPlayedFile(file, initialTime: playbackClock.currentTime)
                }
            }
            if wasAwaitingTerminalCallback {
                deferReplayUntilPendingTerminalCallback(
                    url: file.url,
                    bypassConfirm: bypassConfirm
                )
            } else if cancelledDifferentSelection {
                if player?.isPlaying != true {
                    resume(bypassConfirm: bypassConfirm)
                }
            } else if !isPlaybackRequested {
                resume(bypassConfirm: bypassConfirm)
            }
            return
        }

        play(file, persist: persist, bypassConfirm: bypassConfirm)
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
        deferredTerminalReplay = nil
        deferredTerminalReplayFallbackTask?.cancel()
        deferredTerminalReplayFallbackTask = nil
        cancelUnexpectedStopReconciliation()
        _ = bumpPlaybackAnalysisGeneration()
        pendingLoadTask?.cancel()
        pendingLoadTask = nil
        pendingLoadGeneration = nil
        pendingPlaybackURL = nil
        pendingPlaybackPersistsState = nil
        invalidateResumeRequest()
        setPlaybackIntent(autostart)
        immersiveAnalysisTask?.cancel()
        immersiveAnalysisTask = nil
        pendingLateImmersiveBounds = nil
        immersiveEndTask?.cancel()
        immersiveEndTask = nil

        let immersiveEnabledAtRequest = self.isImmersivePlaybackEnabled
        let url = file.url
        if pendingSeekRequest?.url != url {
            pendingSeekRequest = nil
        }
        let generation = nextLoadGeneration()

        // 即将播放“某一首”时：取消旧的下一首预加载任务，并丢弃不匹配的预加载播放器（避免占用内存）
        nextPreloadTask?.cancel()
        nextPreloadTask = nil
        if preloadedEntryIfMatching(url: url) == nil {
            resetPreloadedNext()
        }

        // 快路径：如果目标曲目已被预加载且不需要阻塞式的“播放前必须分析”，直接无缝切换
        let needsBlockingAnalysis = autostart
            && isNormalizationEnabled
            && requireVolumeAnalysisBeforePlayback
            && !hasVolumeNormalizationCache(for: url)
        let preloadedEntry = preloadedEntryIfMatching(url: url)
        let hasRequiredImmersiveBounds = !isImmersivePlaybackEnabled || preloadedEntry?.playbackBounds != nil
        if autostart,
           !needsBlockingAnalysis,
           hasRequiredImmersiveBounds,
           let entry = consumePreloadedEntryIfMatching(url: url) {
            // 到这里说明下一首已就绪：直接切换并开播（避免再走异步初始化）
            let previousPlayer = self.retireCurrentPlayerForReplacement()
            let prepared = entry.player
            self.player = prepared
            self.activePlayerGeneration = generation
            prepared.delegate = self
            prepared.numberOfLoops = (self.isLooping && !self.isImmersivePlaybackEnabled) ? -1 : 0
            prepared.enableRate = true
            prepared.rate = self.clampPlaybackRate(self.playbackRate)
            self.persistPlaybackState = persist
            self.currentFile = file
            self.playbackClock.duration = prepared.duration
            self.lastSavedTime = 0
            self.applyLoadedPlaybackBounds(entry.playbackBounds, to: prepared, url: url)

            // 切歌时释放上一首封面，避免内存随播放历史增长
            self.artworkLoadTask?.cancel()
            self.artworkLoadTask = nil
            self.artworkImage = nil
            self.artworkAttemptedPathKey = nil
            self.loadArtworkIfNeeded(for: url)

            postPlaybackLoaded(url: url, persist: persist)

            let allowBackgroundAnalysis = (!self.requireVolumeAnalysisBeforePlayback) || (!autostart) || self.hasVolumeNormalizationCache(for: url)
            self.applyVolumeNormalization(for: url, mode: .immediate, allowBackgroundAnalysis: allowBackgroundAnalysis)

            self.loadLyricsIfNeeded(for: file)

            let didStart = prepared.play()
            previousPlayer?.stop()
            if didStart {
                self.isPlaying = true
                self.startTimer()
                self.scheduleImmersiveEndIfNeeded()
                if self.persistPlaybackState {
                    self.saveLastPlayedFile(file, initialTime: self.playbackClock.currentTime)
                }
            } else {
                self.setPlaybackIntent(false)
                self.isPlaying = false
                self.stopTimer()
                postPlaybackFailure(
                    url: url,
                    message: "无法开始播放：\(url.lastPathComponent)",
                    persist: persist
                )
                if !self.isLooping {
                    self.completedLoadGeneration = generation
                    self.postPlaybackFinished(generation: generation, url: url, persist: persist)
                }
            }
            return
        }

        // 在后台初始化播放器，并添加 20s 超时保护，避免 UI 卡死
        pendingPlaybackURL = url
        pendingPlaybackPersistsState = persist
        pendingLoadGeneration = generation
        pendingLoadTask = Task { [weak self] in
            guard let self = self else { return }
            if let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url) {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.finishPendingLoadFailure(ifCurrent: generation)
                    let shouldAdvance = self.isPlaybackRequested && !self.isLooping
                    self.postPlaybackFailure(url: url, message: reason, persist: persist)
                    if shouldAdvance {
                        self.postPlaybackFinished(generation: generation, url: url, persist: persist)
                    }
                    if self.loadGeneration == generation, !self.isPlaying {
                        self.setPlaybackIntent(false)
                    }
                }
                return
            }
            do {
                let newPlayer: AVAudioPlayer
                var preloadedBounds: PlaybackBounds?
                if let entry = self.consumePreloadedEntryIfMatching(url: url) {
                    let prepared = entry.player
                    preloadedBounds = entry.playbackBounds
                    prepared.numberOfLoops = 0
                    prepared.prepareToPlay()
                    newPlayer = prepared
                } else {
                    newPlayer = try await AsyncTimeout.withTimeout(20) {
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
                            p.numberOfLoops = 0
                            p.prepareToPlay()
                            return p
                        }.value
                    }
                }

                let playbackBounds: PlaybackBounds?
                if immersiveEnabledAtRequest {
                    if let preloadedBounds {
                        playbackBounds = preloadedBounds
                    } else {
                        playbackBounds = await self.immersivePlaybackAnalyzer.bounds(
                            for: url,
                            onLateBounds: { [weak self, weak newPlayer] bounds in
                                guard let self, let newPlayer else { return }
                                self.handleLateImmersiveBounds(
                                    bounds,
                                    for: url,
                                    player: newPlayer
                                )
                            }
                        )
                    }
                } else {
                    playbackBounds = nil
                }
                if Task.isCancelled { return }

                // 若用户启用“播放前必须分析”，则在真正切歌/开播前先产出缓存，避免播放中音量变化
                let shouldBlockForNormalization = await MainActor.run {
                    generation == self.loadGeneration
                        && self.isPlaybackRequested
                        && self.isNormalizationEnabled
                        && self.requireVolumeAnalysisBeforePlayback
                        && !self.hasVolumeNormalizationCache(for: url)
                }
                let didAttemptRequiredNormalization: Bool
                if shouldBlockForNormalization {
                    didAttemptRequiredNormalization = true
                    _ = self.calculateNormalizedVolume(
                        for: url,
                        persist: true,
                        cancellationCheck: { Task.isCancelled }
                    )
                    if Task.isCancelled { return }
                } else {
                    didAttemptRequiredNormalization = false
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.clearPendingLoadTask(ifCurrent: generation)
                    // 到这里说明新曲目可被 AVAudioPlayer 正常初始化，才切换并停止旧播放器
                    let previousPlayer = self.retireCurrentPlayerForReplacement()
                    self.player = newPlayer
                    self.activePlayerGeneration = generation
                    newPlayer.delegate = self
                    newPlayer.numberOfLoops = (self.isLooping && !self.isImmersivePlaybackEnabled) ? -1 : 0
                    newPlayer.enableRate = true
                    newPlayer.rate = self.clampPlaybackRate(self.playbackRate)
                    self.persistPlaybackState = persist
                    self.currentFile = file
                    self.playbackClock.duration = newPlayer.duration
                    self.lastSavedTime = 0
                    let lateBounds: PlaybackBounds?
                    if self.pendingLateImmersiveBounds?.url == url {
                        lateBounds = self.pendingLateImmersiveBounds?.bounds
                    } else {
                        lateBounds = nil
                    }
                    self.pendingLateImmersiveBounds = nil
                    self.applyLoadedPlaybackBounds(
                        lateBounds ?? playbackBounds,
                        to: newPlayer,
                        url: url
                    )
                    let shouldStart = self.isPlaybackRequested
                    let requiresDeferredNormalization = shouldStart
                        && self.isNormalizationEnabled
                        && self.requireVolumeAnalysisBeforePlayback
                        && !self.hasVolumeNormalizationCache(for: url)
                        && !didAttemptRequiredNormalization
                    // 切歌时释放上一首封面，避免内存随播放历史增长
                    self.artworkLoadTask?.cancel()
                    self.artworkLoadTask = nil
                    self.artworkImage = nil
                    self.artworkAttemptedPathKey = nil

                    // 仅在“真正开始播放”时才加载封面（省内存：浏览/选中不触发）
                    if shouldStart {
                        self.loadArtworkIfNeeded(for: url)
                    }

                    self.postPlaybackLoaded(url: url, persist: persist)

                    // 应用音量均衡（异步计算，避免主线程阻塞）
                    let allowBackgroundAnalysis = (!self.requireVolumeAnalysisBeforePlayback) || (!shouldStart) || self.hasVolumeNormalizationCache(for: url)
                    self.applyVolumeNormalization(for: url, mode: .immediate, allowBackgroundAnalysis: allowBackgroundAnalysis)

	                    // 加载歌词（异步）
	                    self.loadLyricsIfNeeded(for: file)

                    if shouldStart {
                        previousPlayer?.stop()
                        if requiresDeferredNormalization {
                            self.isPlaying = false
                            self.stopTimer()
                            let intentGeneration = self.playbackIntentGeneration
                            let resumeGeneration = self.invalidateResumeRequest()
                            self.startPlayerAfterRequiredNormalization(
                                newPlayer,
                                url: url,
                                playerGeneration: generation,
                                intentGeneration: intentGeneration,
                                resumeGeneration: resumeGeneration,
                                persist: persist,
                                fileToPersist: file,
                                advanceOnFailure: true
                            )
                        } else if newPlayer.play() {
		                            self.isPlaying = true
		                            self.startTimer()
		                            self.scheduleImmersiveEndIfNeeded()
                            // 若封面尚未加载（例如刚切歌、或 autostart=true 但封面任务被取消），在开播时再确保触发一次
                            self.loadArtworkIfNeeded(for: url)
                            if self.persistPlaybackState {
                                self.saveLastPlayedFile(file, initialTime: self.playbackClock.currentTime)
                            }
                        } else {
	                            self.setPlaybackIntent(false)
                            self.isPlaying = false
	                        self.stopTimer()
                            self.postPlaybackFailure(
                                url: url,
                                message: "无法开始播放：\(url.lastPathComponent)",
                                persist: persist
                            )
                            if !self.isLooping {
                                self.completedLoadGeneration = generation
                                self.postPlaybackFinished(generation: generation, url: url, persist: persist)
                            }
                        }
                    } else {
	                    previousPlayer?.stop()
                        self.isPlaying = false
                        self.stopTimer()
                        if self.persistPlaybackState { self.saveLastPlayedFile(file) }
                        // 恢复时（autostart=false）也保存一次进度，避免“路径已更新但时间仍是上一首歌”的错配长期残留。
	                        self.saveCurrentProgress()
	                    }
	                    if self.isImmersivePlaybackEnabled, playbackBounds == nil {
	                        self.analyzeBoundsForCurrentTrack()
	                    }
		                }
	            } catch is TimeoutError {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.finishPendingLoadFailure(ifCurrent: generation)
                    let shouldAdvance = self.isPlaybackRequested && !self.isLooping
                    self.debugLog("加载音频超时(20s): \(url.lastPathComponent)")
                    self.postPlaybackFailure(
                        url: url,
                        message: "加载超时(20s)：\(url.lastPathComponent)",
                        persist: persist
                    )
                    if shouldAdvance {
                        self.postPlaybackFinished(generation: generation, url: url, persist: persist)
                    }
                    if self.loadGeneration == generation, !self.isPlaying {
                        self.setPlaybackIntent(false)
                    }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.finishPendingLoadFailure(ifCurrent: generation)
                    let shouldAdvance = self.isPlaybackRequested && !self.isLooping
                    self.debugLog("播放音频失败: \(error)")
                    self.postPlaybackFailure(
                        url: url,
                        message: "播放失败：\(url.lastPathComponent)\n\(error.localizedDescription)",
                        persist: persist
                    )
                    if shouldAdvance {
                        self.postPlaybackFinished(generation: generation, url: url, persist: persist)
                    }
                    if self.loadGeneration == generation, !self.isPlaying {
                        self.setPlaybackIntent(false)
                    }
                }
            }
        }
    }

    private func startPlayerAfterRequiredNormalization(
        _ capturedPlayer: AVAudioPlayer,
        url: URL,
        playerGeneration: UInt64,
        intentGeneration: UInt64,
        resumeGeneration: UInt64,
        persist: Bool,
        fileToPersist: AudioFile? = nil,
        advanceOnFailure: Bool = false
    ) {
        pendingResumeTask = Task { [weak self] in
            guard let self else { return }
            _ = self.calculateNormalizedVolume(
                for: url,
                persist: true,
                cancellationCheck: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard resumeGeneration == self.resumeRequestGeneration else { return }
                guard intentGeneration == self.playbackIntentGeneration, self.isPlaybackRequested else { return }
                self.pendingResumeTask = nil
                guard playerGeneration == self.activePlayerGeneration else { return }
                guard self.player === capturedPlayer, self.currentFile?.url == url else { return }

                self.applyVolumeNormalization(
                    for: url,
                    mode: .immediate,
                    allowBackgroundAnalysis: false
                )
                if capturedPlayer.play() {
                    self.isPlaying = true
                    self.startTimer()
                    self.scheduleImmersiveEndIfNeeded()
                    if let fileToPersist {
                        self.loadArtworkIfNeeded(for: url)
                        if persist {
                            self.saveLastPlayedFile(
                                fileToPersist,
                                initialTime: self.playbackClock.currentTime
                            )
                        }
                    }
                } else {
                    self.setPlaybackIntent(false)
                    self.isPlaying = false
                    self.stopTimer()
                    self.postPlaybackFailure(
                        url: url,
                        message: "无法开始播放：\(url.lastPathComponent)",
                        persist: persist
                    )
                    if advanceOnFailure, !self.isLooping {
                        self.completedLoadGeneration = playerGeneration
                        self.postPlaybackFinished(
                            generation: playerGeneration,
                            url: url,
                            persist: persist
                        )
                    }
                }
            }
        }
    }

    func pause() {
        deferredTerminalReplay = nil
        deferredTerminalReplayFallbackTask?.cancel()
        deferredTerminalReplayFallbackTask = nil
        cancelUnexpectedStopReconciliation()
        setPlaybackIntent(false)
        invalidateResumeRequest()
        immersiveEndTask?.cancel()
        immersiveEndTask = nil
        player?.pause()
        isPlaying = false
        stopTimer()
        saveCurrentProgress() // 暂停时保存进度
    }
    
    func resume(bypassConfirm: Bool = false) {
        guard deferredTerminalReplay == nil else { return }
        guard pendingLoadGeneration != nil || player != nil else { return }
        // 若当前为扬声器且来自“耳机→扬声器”的切换，仅对用户显式开始播放做一次确认
        if !bypassConfirm, !isHeadphoneOutput, shouldConfirmSpeakerPlayback {
            requestSpeakerConfirm { [weak self] in
                self?.shouldConfirmSpeakerPlayback = false
                self?.resume(bypassConfirm: true)
            }
            return
        }
        // An explicit resume supersedes any grace-period reconciliation that
        // belonged to a transient stop or a cancelled replacement. In particular,
        // required normalization may defer player.play() beyond that grace period.
        cancelUnexpectedStopReconciliation()
        let intentGeneration = setPlaybackIntent(true)
        let resumeGeneration = invalidateResumeRequest()
        // A selected track is still loading. Keep the play intent so that request
        // starts when ready, rather than briefly restarting the superseded player.
        if pendingLoadGeneration != nil { return }
        guard let player = player else { return }
        let playerGeneration = activePlayerGeneration
        let isReplayingCompletedTrack = completedLoadGeneration == activePlayerGeneration
        completedLoadGeneration = nil
        if isReplayingCompletedTrack, !isImmersivePlaybackEnabled {
            player.currentTime = 0
            playbackClock.currentTime = 0
        }
        if isImmersivePlaybackEnabled, let bounds = activePlaybackBounds {
            let resumeTime = ImmersivePlaybackPolicy.initialPosition(
                requested: player.currentTime,
                bounds: bounds,
                isEnabled: true
            )
            player.currentTime = resumeTime
            playbackClock.currentTime = resumeTime
        }
        if let url = currentFile?.url {
            // 仅在用户开始播放时加载封面（省内存）
            loadArtworkIfNeeded(for: url)
        }
        // 若用户开启“播放前必须分析”，且当前曲目尚未缓存，则先完成一次分析再开始播放，避免播放中音量变化
        if isNormalizationEnabled,
           requireVolumeAnalysisBeforePlayback,
           let url = currentFile?.url,
           !hasVolumeNormalizationCache(for: url) {
            startPlayerAfterRequiredNormalization(
                player,
                url: url,
                playerGeneration: playerGeneration,
                intentGeneration: intentGeneration,
                resumeGeneration: resumeGeneration,
                persist: persistPlaybackState,
                advanceOnFailure: true
            )
            return
        }
        if player.play() {
            isPlaying = true
            startTimer()
            scheduleImmersiveEndIfNeeded()
        } else {
            let shouldAdvance = isPlaybackRequested && !isLooping
            completedLoadGeneration = playerGeneration
            setPlaybackIntent(false)
            isPlaying = false
            stopTimer()
            if let url = currentFile?.url {
                postPlaybackFailure(
                    url: url,
                    message: "无法继续播放：\(url.lastPathComponent)",
                    persist: persistPlaybackState
                )
                if shouldAdvance {
                    postPlaybackFinished(
                        generation: playerGeneration,
                        url: url,
                        persist: persistPlaybackState
                    )
                }
            }
        }
    }

    /// 切换播放/暂停（用于快捷键/菜单）
    func togglePlayPause() {
        if isPlaybackRequested || isPlaying {
            pause()
        } else if canTogglePlayback {
            resume()
        }
    }
    
    private func requestSpeakerConfirm(proceed: @escaping () -> Void) {
        speakerConfirmProceed = proceed
        showSpeakerConfirm = true
    }

    @MainActor
    func clearArtworkCache() {
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        artworkImage = nil
        artworkAttemptedPathKey = nil
        // Keep legacy cache fully cleared as well (even if UI no longer uses it).
        ArtworkCache.shared.clear()
    }
    
	    func stop() {
	        deferredTerminalReplay = nil
	        deferredTerminalReplayFallbackTask?.cancel()
	        deferredTerminalReplayFallbackTask = nil
	        cancelUnexpectedStopReconciliation()
	        _ = bumpPlaybackAnalysisGeneration()
	        setPlaybackIntent(false)
	        invalidateResumeRequest()
	        pendingLoadTask?.cancel()
	        pendingLoadTask = nil
	        pendingLoadGeneration = nil
	        pendingPlaybackURL = nil
	        pendingPlaybackPersistsState = nil
	        pendingSeekRequest = nil
	        immersiveAnalysisTask?.cancel()
	        immersiveAnalysisTask = nil
	        immersiveEndTask?.cancel()
	        immersiveEndTask = nil
	        let generation = nextLoadGeneration()
	        activePlayerGeneration = generation
	        completedLoadGeneration = nil
	        cancelNextPreload()
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
	        deferredTerminalReplay = nil
	        deferredTerminalReplayFallbackTask?.cancel()
	        deferredTerminalReplayFallbackTask = nil
	        cancelUnexpectedStopReconciliation()
	        _ = bumpPlaybackAnalysisGeneration()
	        setPlaybackIntent(false)
	        invalidateResumeRequest()
	        pendingLoadTask?.cancel()
	        pendingLoadTask = nil
	        pendingLoadGeneration = nil
	        pendingPlaybackURL = nil
	        pendingPlaybackPersistsState = nil
	        pendingSeekRequest = nil
	        immersiveAnalysisTask?.cancel()
	        immersiveAnalysisTask = nil
	        immersiveEndTask?.cancel()
	        immersiveEndTask = nil
	        let generation = nextLoadGeneration()
	        activePlayerGeneration = generation
	        completedLoadGeneration = nil
	        cancelNextPreload()
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
	        activePlaybackBounds = nil
        lyricsTimeline = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        artworkImage = nil
        artworkAttemptedPathKey = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
	        playbackClock.duration = 0
        // 可选：清理最近播放缓存，避免清空后再次自动恢复
        if clearLastPlayed {
            playbackStateStore.clearAll()
        }
    }
    
    func seek(to time: TimeInterval) {
        let requestedTime = time.isFinite ? max(0, time) : 0

        // While a replacement is loading, the installed player and its bounds still
        // belong to the previous track. Bind the seek to the selected target and
        // clamp it only after that target's real duration and immersive bounds exist.
        if let pendingURL = pendingPlaybackURL {
            pendingSeekRequest = PendingSeekRequest(
                url: pendingURL,
                time: requestedTime,
                source: .user
            )
            playbackClock.currentTime = requestedTime
            return
        }

        let targetTime: TimeInterval
        if let bounds = activePlaybackBounds {
            targetTime = ImmersivePlaybackPolicy.seekPosition(
                requested: requestedTime,
                bounds: bounds,
                isEnabled: isImmersivePlaybackEnabled
            )
        } else {
            targetTime = requestedTime
        }
        if let player {
            player.currentTime = targetTime
        } else if let targetURL = playbackTargetURL {
            pendingSeekRequest = PendingSeekRequest(
                url: targetURL,
                time: requestedTime,
                source: .user
            )
        }
        playbackClock.currentTime = targetTime
        completedLoadGeneration = nil
        scheduleImmersiveEndIfNeeded()
    }

        /// 用于跨启动恢复：把初始进度绑定到目标文件，加载完成时再做防错 clamp。
        func prepareInitialSeekForRestore(to time: TimeInterval, for url: URL) {
            pendingSeekRequest = PendingSeekRequest(url: url, time: time, source: .restore)
            playbackClock.currentTime = time
        }

    /// 重新载入当前曲目的底层播放器，尽量保留播放/进度状态（用于完全刷新、外部文件被覆盖的情况）
	    func reloadCurrentPreservingState() {
	        guard let file = currentFile else { return }
	        guard pendingPlaybackURL == nil || pendingPlaybackURL == file.url else { return }
	        deferredTerminalReplay = nil
	        deferredTerminalReplayFallbackTask?.cancel()
	        deferredTerminalReplayFallbackTask = nil
	        cancelUnexpectedStopReconciliation()
	        let prevTime = playbackClock.currentTime
	        let immersiveEnabled = isImmersivePlaybackEnabled
	        let url = file.url

        pendingLoadTask?.cancel()
        pendingLoadTask = nil
        pendingLoadGeneration = nil
        pendingPlaybackURL = nil
        pendingPlaybackPersistsState = nil
        invalidateResumeRequest()
	        let generation = nextLoadGeneration()
        pendingPlaybackURL = url
        pendingPlaybackPersistsState = persistPlaybackState
        pendingLoadGeneration = generation
        pendingSeekRequest = PendingSeekRequest(
            url: url,
            time: prevTime,
            source: .reloadBaseline
        )
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
	                        p.numberOfLoops = 0
	                        p.prepareToPlay()
	                        return p
	                    }.value
	                }
	                let playbackBounds: PlaybackBounds?
	                if immersiveEnabled {
	                    playbackBounds = await self.immersivePlaybackAnalyzer.bounds(for: url)
	                } else {
	                    playbackBounds = nil
	                }
	                if Task.isCancelled { return }

                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.clearPendingLoadTask(ifCurrent: generation)
                    if self.pendingSeekRequest?.url == url,
                       self.pendingSeekRequest?.source == .reloadBaseline,
                       let previousPlayer = self.player {
                        self.pendingSeekRequest = PendingSeekRequest(
                            url: url,
                            time: previousPlayer.currentTime,
                            source: .reloadBaseline
                        )
                    }
                    // 切换播放器
                    self.player?.stop()
	                    self.player = newPlayer
	                    self.activePlayerGeneration = generation
	                    newPlayer.delegate = self
	                    newPlayer.numberOfLoops = (self.isLooping && !self.isImmersivePlaybackEnabled) ? -1 : 0
	                    newPlayer.enableRate = true
	                    newPlayer.rate = self.clampPlaybackRate(self.playbackRate)
	                    self.playbackClock.duration = newPlayer.duration
	                    self.applyLoadedPlaybackBounds(playbackBounds, to: newPlayer, url: url)
	                    let shouldStart = self.isPlaybackRequested
	                    let requiresDeferredNormalization = shouldStart
	                        && self.isNormalizationEnabled
	                        && self.requireVolumeAnalysisBeforePlayback
	                        && !self.hasVolumeNormalizationCache(for: url)

                    // 重建音量、进度与定时器
	                    self.loadArtworkIfNeeded(for: url)
	                    self.postPlaybackLoaded(url: url, persist: self.persistPlaybackState)
	                    self.applyVolumeNormalization(
	                        for: url,
	                        allowBackgroundAnalysis: !requiresDeferredNormalization
	                    )
	                    if shouldStart {
	                        if requiresDeferredNormalization {
	                            self.isPlaying = false
	                            self.stopTimer()
	                            let intentGeneration = self.playbackIntentGeneration
	                            let resumeGeneration = self.invalidateResumeRequest()
	                            self.startPlayerAfterRequiredNormalization(
	                                newPlayer,
	                                url: url,
	                                playerGeneration: generation,
	                                intentGeneration: intentGeneration,
	                                resumeGeneration: resumeGeneration,
	                                persist: self.persistPlaybackState,
	                                fileToPersist: file,
	                                advanceOnFailure: true
	                            )
	                        } else if newPlayer.play() {
	                            self.isPlaying = true
	                            self.startTimer()
	                            self.scheduleImmersiveEndIfNeeded()
	                        } else {
	                            self.setPlaybackIntent(false)
	                            self.isPlaying = false
	                            self.stopTimer()
	                            self.postPlaybackFailure(
	                                url: url,
	                                message: "无法开始播放：\(url.lastPathComponent)",
	                                persist: self.persistPlaybackState
	                            )
	                            if !self.isLooping {
	                                self.completedLoadGeneration = generation
	                                self.postPlaybackFinished(
	                                    generation: generation,
	                                    url: url,
	                                    persist: self.persistPlaybackState
	                                )
	                            }
	                        }
	                    } else {
                        self.isPlaying = false
                        self.stopTimer()
                    }
	                    if self.isImmersivePlaybackEnabled, playbackBounds == nil {
	                        self.analyzeBoundsForCurrentTrack()
	                    }
                }
            } catch is TimeoutError {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.finishPendingLoadFailure(ifCurrent: generation)
                    self.debugLog("重新载入当前曲目超时(20s): \(url.lastPathComponent)")
                    self.resolvePreservedPlayerAfterReloadFailure(generation: generation, url: url)
                }
            } catch {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.finishPendingLoadFailure(ifCurrent: generation)
                    self.debugLog("重新载入当前曲目失败: \(error)")
                    self.resolvePreservedPlayerAfterReloadFailure(generation: generation, url: url)
                }
            }
        }
    }
    
    func setVolume(_ newVolume: Float) {
        volume = newVolume.isFinite ? max(0, min(1, newVolume)) : 0.5
        saveUserVolume()
        updatePlayerVolume()
    }

    func setPlaybackRate(_ newRate: Float) {
        playbackRate = newRate.isFinite ? clampPlaybackRate(newRate) : 1
        savePlaybackRatePreference()
        updatePlayerRate()
        scheduleImmersiveEndIfNeeded()
    }
    
    func toggleNormalization() {
        isNormalizationEnabled.toggle()
        if !isNormalizationEnabled {
            _ = bumpPlaybackAnalysisGeneration()
        }
        saveNormalizationPreference()
        if let currentFile = currentFile {
            let mode: VolumeApplyMode = isPlaying ? .smooth : .immediate
            applyVolumeNormalization(for: currentFile.url, mode: mode)
        } else if let player = player {
            setAVAudioPlayerVolume(player, volume)
        }
    }

    func setNormalizationEnabled(_ enabled: Bool) {
        guard enabled != isNormalizationEnabled else { return }
        toggleNormalization()
    }

    var effectivePlaybackEndTime: TimeInterval {
        guard isImmersivePlaybackEnabled, let bounds = activePlaybackBounds else {
            return playbackClock.duration
        }
        return bounds.audibleEnd
    }

    var effectivePlaybackStartTime: TimeInterval {
        guard isImmersivePlaybackEnabled, let bounds = activePlaybackBounds else { return 0 }
        return bounds.audibleStart
    }

    var playbackRequestGeneration: UInt64 { loadGeneration }

    func toggleImmersivePlayback() {
        setImmersivePlaybackEnabled(!isImmersivePlaybackEnabled)
    }

    func setImmersivePlaybackEnabled(_ enabled: Bool) {
        guard enabled != isImmersivePlaybackEnabled else { return }
        isImmersivePlaybackEnabled = enabled
        saveImmersivePlaybackPreference()
        completedLoadGeneration = nil
        immersiveEndTask?.cancel()
        immersiveEndTask = nil
        immersiveAnalysisTask?.cancel()
        immersiveAnalysisTask = nil
        cancelNextPreload()
        if enabled, let player, player.duration.isFinite, player.duration > 0 {
            activePlaybackBounds = .fullRange(duration: player.duration)
        }
        updateLoopSetting()

        if enabled {
            scheduleImmersiveEndIfNeeded()
            analyzeBoundsForCurrentTrack()
        } else {
            activePlaybackBounds = nil
            refreshPlaybackTimerPrecisionIfNeeded()
        }
    }

    @discardableResult
    func clearImmersivePlaybackCache() async -> Result<
        ImmersivePlaybackAnalyzer.CacheClearReport,
        ImmersivePlaybackAnalyzer.CachePersistenceError
    > {
        let result = await immersivePlaybackAnalyzer.removeAll()
        if case .success = result, isImmersivePlaybackEnabled {
            await MainActor.run { [weak self] in
                self?.analyzeBoundsForCurrentTrack()
            }
        }
        return result
    }

    func flushImmersivePlaybackCachePersistence(timeout: TimeInterval = 2) {
        let analyzer = immersivePlaybackAnalyzer
        let completion = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            await analyzer.flushPersistence()
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + timeout)
    }
    
    func setPlaybackMode(_ mode: PlaybackMode) {
        guard mode != playbackMode else { return }
        playbackMode = mode
        updateLoopSetting()
        savePlaybackModePreference()
        scheduleImmersiveEndIfNeeded()
    }

    /// Resolve persisted state from the new single-value preference or the two
    /// legacy booleans. Invalid legacy combinations are deterministic:
    /// repeat-one wins true/true, while false/false returns to shuffle.
    nonisolated static func resolvedPlaybackMode(
        storedRawValue: String?,
        legacyLooping: Bool,
        legacyShuffling: Bool
    ) -> PlaybackMode {
        if let storedRawValue, let stored = PlaybackMode(rawValue: storedRawValue) {
            return stored
        }
        switch (legacyLooping, legacyShuffling) {
        case (true, _): return .repeatOne
        case (false, _): return .shuffle
        }
    }
    
    private func updateLoopSetting() {
        player?.numberOfLoops = (isLooping && !isImmersivePlaybackEnabled) ? -1 : 0
    }

    private func updatePlayerRate() {
        guard let player else { return }
        player.enableRate = true
        player.rate = clampPlaybackRate(playbackRate)
    }
    
    private func startTimer() {
        // 确保只存在一个计时器，并使用 .common 模式防止 UI 交互导致暂停
        cancelUnexpectedStopReconciliation()
        stopTimer()
        let interval = playbackClockUpdateInterval()
	        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
	            guard let self = self, let player = self.player else { return }
            // 若系统层面导致播放器停止（例如音频路由变化/耳机断开），
            // AVAudioPlayer 可能会自行变为未播放状态，但未必触发 delegate 回调。
            // 这里做保护性检测以同步应用内播放状态与 UI。
            if self.isPlaying && !player.isPlaying {
                self.isPlaying = false
                self.saveCurrentProgress()
                self.stopTimer()
                self.reconcileUnexpectedStop(
                    of: player,
                    generation: self.activePlayerGeneration
                )
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

    private func playbackClockUpdateInterval() -> TimeInterval {
        if showLyrics, let timeline = lyricsTimeline, timeline.isSynced {
            return 0.1
        }
        return 0.25
    }

    private func refreshPlaybackTimerPrecisionIfNeeded() {
        guard isPlaying, player != nil else { return }
        startTimer()
    }
    
    // MARK: - 删除当前或待播放项后的回调处理
    /// 删除命中已安装播放器或异步加载目标时，由上层调用本方法。
    /// 若只删除旧播放器、而另一个目标仍在加载，则停止旧播放器并保留新请求。
    /// - Parameters:
    ///   - removedURL: 被删除曲目的 URL
    ///   - remainingFiles: 删除后当前播放列表剩余的文件（用于随机/顺序继续播放）
    ///   - playNext: 可选的“获取下一首”的闭包（若上层有顺序管理器可传入），未提供时将不处理顺序下一首
    func handleRemovedTrack(
        _ removedURL: URL,
        remainingFiles: [AudioFile],
        playNext: (() -> AudioFile?)? = nil,
        playRandom: (() -> AudioFile?)? = nil,
        restoreInstalledSelection: (() -> Void)? = nil
    ) {
        let removesPendingTarget = pendingPlaybackURL == removedURL
        let removesInstalledTrack = currentFile?.url == removedURL
        guard removesPendingTarget || removesInstalledTrack else { return }

        if removesPendingTarget, !removesInstalledTrack {
            let shouldContinuePlayback = isPlaybackRequested
            _ = cancelPendingLoadPreservingCurrentPlayer()
            guard player != nil, currentFile != nil else {
                if shouldContinuePlayback {
                    transitionAfterRemovingActiveTrack(
                        remainingFiles: remainingFiles,
                        playNext: playNext,
                        playRandom: playRandom
                    )
                } else {
                    // A cancelled non-autostart restore must remain paused; deleting
                    // its target must not silently start the next queue item.
                    stopAndClearCurrent(clearLastPlayed: true)
                }
                return
            }
            restoreInstalledSelection?()
            if isPlaybackRequested, player?.isPlaying != true {
                resume(bypassConfirm: true)
            }
            return
        }

        if removesInstalledTrack,
           !removesPendingTarget,
           pendingPlaybackURL != nil {
            let removedPlayer = retireCurrentPlayerForReplacement()
            removedPlayer?.delegate = nil
            removedPlayer?.stop()
            player = nil
            currentFile = nil
            activePlaybackBounds = nil
            completedLoadGeneration = nil
            playbackClock.currentTime = 0
            playbackClock.duration = 0
            lyricsTimeline = nil
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkImage = nil
            artworkAttemptedPathKey = nil
            clearLastPlayedFileIfMatching(removedURL)
            return
        }

        transitionAfterRemovingActiveTrack(
            remainingFiles: remainingFiles,
            playNext: playNext,
            playRandom: playRandom
        )
    }

    private func transitionAfterRemovingActiveTrack(
        remainingFiles: [AudioFile],
        playNext: (() -> AudioFile?)?,
        playRandom: (() -> AudioFile?)?
    ) {
        // 单曲循环：立即停止并清空当前歌曲
        if isLooping {
            stopAndClearCurrent(clearLastPlayed: true)
            return
        }
        // 随机模式：从剩余文件中随机一首继续播放；若空则停止并清空
        if isShuffling {
            if let next = playRandom?() ?? remainingFiles.randomElement() {
                stopAndClearCurrent(clearLastPlayed: true)
                selectOrResume(next)
            } else {
                stopAndClearCurrent(clearLastPlayed: true)
            }
            return
        }
        // 其他模式：如果提供了顺序“下一首”，尝试获取并播放；否则与空列表时相同处理
        if let nextProvider = playNext, let next = nextProvider() {
            stopAndClearCurrent(clearLastPlayed: true)
            selectOrResume(next)
        } else {
            stopAndClearCurrent(clearLastPlayed: true)
        }
    }
    
    // MARK: - 保存和加载上次播放的歌曲
    private func saveLastPlayedFile(_ file: AudioFile, initialTime: TimeInterval? = nil) {
        playbackStateStore.saveState(fileURL: file.url, time: initialTime ?? 0)
    }

    private func clearLastPlayedFileIfMatching(_ url: URL) {
        playbackStateStore.clearIfMatching(url)
    }
    
			    private func saveCurrentProgress() {
			        guard let currentFile else { return }
			        // 临时播放（不持久化）时不保存播放进度
			        guard persistPlaybackState else { return }
			        let time = player?.currentTime ?? playbackClock.currentTime
			        playbackStateStore.saveState(fileURL: currentFile.url, time: time)
			        debugLog("保存播放进度: \(time) 秒")
			    }

    @discardableResult
    func flushPlaybackStatePersistence() -> Bool {
        saveCurrentProgress()
        return playbackStateStore.flush()
    }

    @discardableResult
    func rekeyPersistedPlaybackState(
        from oldURL: URL,
        to newURL: URL
    ) -> PlaybackStateStore.RekeyResult {
        playbackStateStore.rekeyIfMatching(from: oldURL, to: newURL)
    }
    
	    func loadLastPlayedFile() {
	        guard let state = playbackStateStore.loadState() else {
	            debugLog("没有找到上次播放的文件路径")
	            return
	        }
	        debugLog("尝试加载上次播放的文件: \(state.filePath)")
	        if FileManager.default.fileExists(atPath: state.filePath) {
	            let url = URL(fileURLWithPath: state.filePath)
	            debugLog("文件存在，发送加载通知，播放时间: \(state.lastPlayedTime)")
	            NotificationCenter.default.post(
	                name: .loadLastPlayedFile,
	                object: nil,
                userInfo: ["url": url, "time": state.lastPlayedTime]
            )
	        } else {
	            debugLog("文件不存在: \(state.filePath)")
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
                        let updated = AudioFile(url: current.url, metadata: current.metadata, lyricsTimeline: timeline, duration: current.duration)
                        self.currentFile = updated
                    }
                case .failure:
                    self.lyricsTimeline = nil
                }
            }
        }
    }

    // MARK: - Artwork loading（低内存：只生成缩略图，不保留原始 Data / 不做跨曲目缓存）
    private func loadArtworkIfNeeded(for url: URL) {
        guard let current = currentFile, current.url == url else { return }

        let key = url.path
        if artworkAttemptedPathKey == key { return }
        artworkAttemptedPathKey = key

        // 若已有图（例如刚加载完又触发一次），不重复做事
        if artworkImage != nil { return }

        artworkLoadTask?.cancel()
        artworkLoadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            guard let data = await self.fetchArtworkData(for: url) else { return }
            if Task.isCancelled { return }
            guard let cgImage = Self.makeThumbnailCGImage(from: data, maxPixel: 600) else { return }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.currentFile?.url == url else { return }
                self.artworkImage = NSImage(cgImage: cgImage, size: NSSize(width: 300, height: 300))
            }
        }
    }

    private static func makeThumbnailCGImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // Avoid caching decoded pixels globally; we already keep only a tiny thumbnail.
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
        if Thread.isMainThread {
            handlePlayerFinishedOnMain(player, successfully: flag)
        } else {
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player else { return }
                self.handlePlayerFinishedOnMain(player, successfully: flag)
            }
        }
    }

    private func handlePlayerFinishedOnMain(_ player: AVAudioPlayer, successfully flag: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        // 仅处理来自“当前”播放器实例的回调，忽略已被切换掉的旧实例，避免误将新歌置为暂停
        guard player === self.player else { return }
        cancelUnexpectedStopReconciliation()
        // The same AVAudioPlayer can be replayed before an already-queued EOF callback
        // reaches the main queue. If it is playing again, that callback belongs to the
        // previous playback cycle and must not advance the newly started cycle.
        guard !player.isPlaying else { return }
        let generation = activePlayerGeneration
        if consumeDeferredTerminalReplayIfNeeded(
            generation: generation,
            url: currentFile?.url
        ) {
            return
        }
        guard completedLoadGeneration != generation else { return }

        // 异常结束只能收敛到一次失败；循环模式不得反复重试坏文件。
        if !flag {
            let shouldAdvance = generation == loadGeneration
                && isPlaybackRequested
                && !isLooping
            let url = currentFile?.url
            if let url {
                postPlaybackFailure(
                    url: url,
                    message: "播放异常结束：\(url.lastPathComponent)",
                    persist: persistPlaybackState
                )
            }
            completedLoadGeneration = generation
            if generation == loadGeneration {
                setPlaybackIntent(false)
            }
            isPlaying = false
            stopTimer()
            player.stop()
            if shouldAdvance {
                postPlaybackFinished(
                    generation: generation,
                    url: url,
                    persist: persistPlaybackState
                )
            }
            return
        }

        // A delayed EOF must not override a newer load request or a user pause.
        // Keep the active-player completion latch so an explicit replay can
        // restart from the correct boundary, but do not loop or advance.
        guard generation == loadGeneration, isPlaybackRequested else {
            completedLoadGeneration = generation
            isPlaying = false
            stopTimer()
            return
        }

        if isLooping, isImmersivePlaybackEnabled {
            let bounds = activePlaybackBounds ?? .fullRange(duration: player.duration)
            player.currentTime = bounds.audibleStart
            playbackClock.currentTime = bounds.audibleStart
            if player.play() {
                isPlaying = true
                startTimer()
                scheduleImmersiveEndIfNeeded()
            } else {
                completedLoadGeneration = generation
                if generation == loadGeneration {
                    setPlaybackIntent(false)
                }
                isPlaying = false
                stopTimer()
                if let url = currentFile?.url {
                    postPlaybackFailure(
                        url: url,
                        message: "无法继续循环播放：\(url.lastPathComponent)",
                        persist: persistPlaybackState
                    )
                }
            }
            return
        }

        // 成功自然结束且未开启单曲循环时，推进到现有播放范围的下一首。
        if !isLooping {
            completedLoadGeneration = generation
            if generation == loadGeneration {
                setPlaybackIntent(false)
            }
            isPlaying = false
            player.currentTime = 0
            playbackClock.currentTime = 0
            stopTimer()
            postPlaybackFinished(
                generation: generation,
                url: currentFile?.url,
                persist: persistPlaybackState
            )
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if Thread.isMainThread {
            handleDecodeErrorOnMain(player, error: error)
        } else {
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player else { return }
                self.handleDecodeErrorOnMain(player, error: error)
            }
        }
    }

    private func handleDecodeErrorOnMain(_ player: AVAudioPlayer, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard player === self.player else { return }
        let generation = activePlayerGeneration
        if consumeDeferredTerminalReplayIfNeeded(
            generation: generation,
            url: currentFile?.url
        ) {
            return
        }
        guard completedLoadGeneration != generation else { return }
        let shouldAdvance = generation == loadGeneration
            && isPlaybackRequested
            && !isLooping
        if let url = currentFile?.url {
            postPlaybackFailure(
                url: url,
                message: "解码失败：\(url.lastPathComponent)\n\(error?.localizedDescription ?? "")",
                persist: persistPlaybackState
            )
        }
        completedLoadGeneration = generation
        if generation == loadGeneration {
            setPlaybackIntent(false)
        }
        isPlaying = false
        stopTimer()
        player.stop()
        // 非循环播放继续下一首；循环播放停在失败曲目，避免无限重试。
        if shouldAdvance {
            postPlaybackFinished(
                generation: generation,
                url: currentFile?.url,
                persist: persistPlaybackState
            )
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

    private func desiredPlayerVolume(for url: URL) -> Float {
        if !isNormalizationEnabled { return volume }
        if let measurement = cachedLoudnessMeasurement(for: url) {
            return LoudnessNormalizationPolicy.outputVolume(
                userVolume: volume,
                measurement: measurement,
                targetLUFS: currentNormalizationTargetLUFS()
            )
        }
        return volume
    }

    private func startVolumeRamp(on player: AVAudioPlayer, to targetVolume: Float, duration: Double) {
        volumeRampTask?.cancel()
        let start = player.volume
        if abs(start - targetVolume) < 0.001 {
            setAVAudioPlayerVolume(player, targetVolume)
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
                self.setAVAudioPlayerVolume(thisPlayer, start + (targetVolume - start) * t)
                try? await Task.sleep(nanoseconds: stepDurationNs)
            }
            if self.player === thisPlayer {
                self.setAVAudioPlayerVolume(thisPlayer, targetVolume)
            }
        }
    }

    /// Sets AVAudioPlayer.volume, respecting testModeSilent flag.
    /// When testModeSilent is true, forces volume to 0 regardless of requested value.
    private func setAVAudioPlayerVolume(_ player: AVAudioPlayer, _ volume: Float) {
        player.volume = testModeSilent ? 0 : volume
    }

    private func applyPlayerVolumeOnMain(_ clamped: Float, mode: VolumeApplyMode) {
        guard let player = self.player else { return }
        switch mode {
        case .immediate:
            self.volumeRampTask?.cancel()
            setAVAudioPlayerVolume(player, clamped)
        case .smooth:
            let duration = self.normalizationFadeDuration
            guard duration > 0, self.isPlaying else {
                self.volumeRampTask?.cancel()
                setAVAudioPlayerVolume(player, clamped)
                return
            }
            self.startVolumeRamp(on: player, to: clamped, duration: duration)
        }
    }

    private func setPlayerVolume(_ targetVolume: Float, mode: VolumeApplyMode) {
        let clamped = max(0, min(1, targetVolume))
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.applyPlayerVolumeOnMain(clamped, mode: mode)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
	    
	    /// 应用音量均衡（异步）
	    private func applyVolumeNormalization(for url: URL, mode: VolumeApplyMode = .immediate, allowBackgroundAnalysis: Bool = true) {
            let fileKey = volumeCacheKey(for: url)

            // 先立即/平滑应用当前可得的结果（有缓存则命中，否则保持用户音量）
            setPlayerVolume(desiredPlayerVolume(for: url), mode: mode)

            // 若均衡已关闭，不再后台分析
            guard isNormalizationEnabled else { return }

            let hasCache = cachedLoudnessMeasurement(for: url) != nil
            // 若已有缓存，无需再排队分析
            guard !hasCache else { return }
            guard allowBackgroundAnalysis else { return }

            // Automatic idle analysis is owned by PlaybackCoordinator after its
            // cooldown. A paused load must not bypass that policy and start a full
            // decode immediately.
            guard analyzeVolumesDuringPlayback else { return }

            // 后台计算并更新
            let analysisGeneration = currentPlaybackAnalysisGeneration()
            normalizationQueue.async { [weak self] in
                guard let self else { return }
                guard self.currentPlaybackAnalysisGeneration() == analysisGeneration else { return }
                // 避免同一路径重复排队分析
                let inFlightKeys = self.volumeCacheLookupKeys(for: url)
                if inFlightKeys.contains(where: { self.normalizationInFlight.contains($0) }) { return }
                self.normalizationInFlight.insert(fileKey)
                defer {
                    for key in inFlightKeys {
                        self.normalizationInFlight.remove(key)
                    }
                }

                _ = self.calculateNormalizedVolume(
                    for: url,
                    cancellationCheck: {
                        self.currentPlaybackAnalysisGeneration() != analysisGeneration
                    }
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.currentPlaybackAnalysisGeneration() == analysisGeneration else { return }
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
	        } else if let player = player {
	            setAVAudioPlayerVolume(player, volume)
	        }
	    }
	    
	    /// 计算归一化音量
    func calculateNormalizedVolume(
        for url: URL,
        persist: Bool = true,
        cancellationCheck: (() -> Bool)? = nil,
        evictCacheKeyOnSuccess: String? = nil
    ) -> Float {
        _ = persist // SQLite commits each derived result incrementally.
        _ = evictCacheKeyOnSuccess // Capacity eviction is owned by the store's LRU.
        let cacheEpochAtRequest = currentVolumeCacheEpoch()
        // UI preferences may change while a utility-queue scan is running.
        // Use one lock-protected value for the complete request; the persisted
        // measurement remains target-independent and can be reapplied later.
        let targetLUFS = currentNormalizationTargetLUFS()

        if let cached = cachedLoudnessMeasurement(for: url) {
            return LoudnessNormalizationPolicy.outputVolume(
                userVolume: 1,
                measurement: cached,
                targetLUFS: targetLUFS
            )
        }

        // All full-track scans share one lane, keeping memory and decoder pressure bounded.
        volumeAnalysisLock.lock()
        defer { volumeAnalysisLock.unlock() }
        if cancellationCheck?() == true || Task.isCancelled { return 1 }
        guard currentVolumeCacheEpoch() == cacheEpochAtRequest else { return 1 }
        if let cached = cachedLoudnessMeasurement(for: url) {
            return LoudnessNormalizationPolicy.outputVolume(
                userVolume: 1,
                measurement: cached,
                targetLUFS: targetLUFS
            )
        }

        let snapshotBefore = FileValidationSnapshot.load(for: url)
        guard snapshotBefore.exists else { return 1 }
        let result = analyzeAudioLevel(for: url, cancellationCheck: cancellationCheck)
        guard case .success(let measurement) = result else {
            if case .failure(let error) = result {
                volumeAnalysisStore?.recordFailure(error, for: url, snapshot: snapshotBefore)
                if error != .cancelled {
                    debugLog("音量均衡分析失败：\(url.lastPathComponent)（\(error.localizedDescription)）")
                }
            }
            return 1
        }
        if cancellationCheck?() == true || Task.isCancelled { return 1 }
        let snapshotAfter = FileValidationSnapshot.load(for: url)
        guard snapshotBefore == snapshotAfter,
              currentVolumeCacheEpoch() == cacheEpochAtRequest else {
            debugLog("响度分析期间文件发生变化，丢弃结果：\(url.lastPathComponent)")
            return 1
        }

        // A valid analysis must affect this playback session even when SQLite
        // is temporarily read-only or the disk is full.
        storeSessionLoudness(measurement, for: url, snapshot: snapshotAfter)

        if let store = volumeAnalysisStore {
            switch store.save(measurement: measurement, for: url, snapshot: snapshotAfter) {
            case .success(let count):
                DispatchQueue.main.async { [weak self] in
                    self?.volumeNormalizationCacheCount = count
                }
            case .failure(let error):
                // Persistence is an optimization; a valid in-memory result may
                // still normalize the current playback request.
                debugLog(error.message)
            }
        }

        let integratedDescription = measurement.integratedLoudnessLUFS.map {
            String(format: "%.2f", $0)
        } ?? "silence"
        debugLog(
            "文件: \(url.lastPathComponent), integrated: "
                + "\(integratedDescription) LUFS, "
                + "estimated peak: \(measurement.estimatedTruePeakDbTP), "
                + "目标: \(targetLUFS) LUFS"
        )
        return LoudnessNormalizationPolicy.outputVolume(
            userVolume: 1,
            measurement: measurement,
            targetLUFS: targetLUFS
        )
    }

    func analyzeAudioLevel(
        for url: URL,
        cancellationCheck: (() -> Bool)? = nil
    ) -> Result<LoudnessMeasurement, LoudnessAnalysisError> {
        LoudnessAnalyzer.analyze(url: url, cancellationCheck: cancellationCheck)
    }


    @discardableResult
    func clearVolumeCache(forceProtectedData: Bool = false) -> VolumeCacheClearResult {
        cancelVolumeNormalizationPreanalysis()
        _ = bumpPlaybackAnalysisGeneration()
        _ = bumpVolumeCacheEpoch()
        let result = volumeAnalysisStore?.clear(forceProtectedData: forceProtectedData)
            ?? (volumeAnalysisPersistenceAvailable
                ? .cleared(analysisCount: 0, failureCount: 0, removedProtectedLegacy: false)
                : .failed("音量分析数据库不可用"))
        if case .cleared = result {
            clearSessionLoudnessCache()
            DispatchQueue.main.async { [weak self] in
                self?.volumeNormalizationCacheCount = 0
            }
        }
        return result
    }

    @discardableResult
    func flushVolumeCachePersistence() -> VolumeCacheFlushResult {
        volumeAnalysisStore?.flush()
            ?? (volumeAnalysisPersistenceAvailable ? .flushed : .failed("音量分析数据库不可用"))
    }

    func hasVolumeNormalizationCache(for url: URL) -> Bool {
        cachedLoudnessMeasurement(for: url) != nil
    }

    func hasMissingVolumeNormalizationCache<URLs: Sequence>(in urls: URLs) -> Bool
    where URLs.Element == URL {
        if let store = volumeAnalysisStore {
            for url in urls
            where cachedLoudnessMeasurement(for: url) == nil && store.shouldRetryAnalysis(for: url) {
                return true
            }
            return false
        }
        for url in urls where cachedLoudnessMeasurement(for: url) == nil {
            return true
        }
        return false
    }

    var nextVolumeNormalizationRetryDate: Date? {
        volumeAnalysisStore?.nextRetryDate
    }

    func volumeNormalizationValidCacheKeysAsync(for urls: [URL]) async -> Set<String> {
        let store = volumeAnalysisStore
        let persisted = await Task.detached(priority: .utility) {
            store?.validPathKeys(for: urls) ?? []
        }.value
        var result = persisted
        for url in urls where sessionLoudnessMeasurement(for: url) != nil {
            result.insert(volumeCacheKey(for: url))
        }
        return result
    }

    func startVolumeNormalizationPreanalysis<URLs: Sequence>(
        urls: URLs,
        reason: VolumePreanalysisStartReason = .manual
    ) where URLs.Element == URL {
        let generation = bumpVolumePreanalysisGeneration()
        volumePreanalysisStartReason = reason
        volumePreanalysisTask?.cancel()
        volumePreanalysisTask = nil

        var seen = Set<String>()
        var targets: [URL] = []
        let limit = reason == .autoIdle ? 2 : Int.max
        for url in urls {
            let key = volumeCacheKey(for: url)
            guard seen.insert(key).inserted,
                  !hasVolumeNormalizationCache(for: url) else { continue }
            if reason == .autoIdle,
               let volumeAnalysisStore,
               !volumeAnalysisStore.shouldRetryAnalysis(for: url) {
                continue
            }
            targets.append(url)
            if targets.count == limit { break }
        }

        guard !targets.isEmpty else {
            volumePreanalysisStartReason = .manual
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentVolumePreanalysisGeneration() == generation else { return }
                self.isVolumePreanalysisRunning = false
                self.volumePreanalysisCurrentFileName = ""
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.currentVolumePreanalysisGeneration() == generation else { return }
            self.isVolumePreanalysisRunning = true
            self.volumePreanalysisTotal = targets.count
            self.volumePreanalysisCompleted = 0
            self.volumePreanalysisCurrentFileName = ""
        }

        volumePreanalysisTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let analysisQueue = self.normalizationQueue
            let playerBox = WeakAudioPlayerBox(player: self)
            var completed = 0
            for url in targets {
                if Task.isCancelled
                    || self.currentVolumePreanalysisGeneration() != generation { break }
                await MainActor.run {
                    guard self.currentVolumePreanalysisGeneration() == generation else { return }
                    self.volumePreanalysisCurrentFileName = url.lastPathComponent
                }

                let result = await withCheckedContinuation {
                    (continuation: CheckedContinuation<VolumePreanalysisItemResult, Never>) in
                    analysisQueue.async { [playerBox] in
                        guard let player = playerBox.player,
                              player.currentVolumePreanalysisGeneration() == generation else {
                            continuation.resume(returning: .failed)
                            return
                        }
                        if player.hasVolumeNormalizationCache(for: url) {
                            continuation.resume(returning: .alreadyCached)
                            return
                        }
                        _ = player.calculateNormalizedVolume(
                            for: url,
                            cancellationCheck: { [playerBox] in
                                guard let player = playerBox.player else { return true }
                                return player.currentVolumePreanalysisGeneration() != generation
                            }
                        )
                        continuation.resume(
                            returning: player.hasVolumeNormalizationCache(for: url)
                                ? .analyzed
                                : .failed
                        )
                    }
                }

                if Task.isCancelled
                    || self.currentVolumePreanalysisGeneration() != generation { break }
                completed += 1
                let completedSnapshot = completed
                let cacheCount = self.volumeAnalysisStore?.analysisCount ?? 0
                await MainActor.run {
                    guard self.currentVolumePreanalysisGeneration() == generation else { return }
                    self.volumePreanalysisCompleted = completedSnapshot
                    self.volumeNormalizationCacheCount = cacheCount
                }
                _ = result
            }

            await MainActor.run {
                guard self.currentVolumePreanalysisGeneration() == generation else { return }
                self.volumePreanalysisTask = nil
                self.isVolumePreanalysisRunning = false
                self.volumePreanalysisCurrentFileName = ""
                self.volumePreanalysisStartReason = .manual
            }
        }
    }

    func cancelVolumeNormalizationPreanalysis() {
        let generation = bumpVolumePreanalysisGeneration()
        volumePreanalysisTask?.cancel()
        volumePreanalysisTask = nil
        volumePreanalysisStartReason = .manual
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.currentVolumePreanalysisGeneration() == generation else { return }
            self.isVolumePreanalysisRunning = false
            self.volumePreanalysisCurrentFileName = ""
        }
    }

    private func loadCoherentPlayerPreferences() {
        let preferences = appPreferencesStore.load()
        volume = preferences.volume
        playbackRate = preferences.playbackRate
        playbackMode = PlaybackMode(rawValue: preferences.playbackMode.rawValue) ?? .shuffle
    }

    private func saveUserVolume() {
        guard shouldPersistUserPreferences else { return }
        guard appPreferencesStore.persistenceState == .writable else {
            volume = appPreferencesStore.load().volume
            notifyProtectedCoherentPreferencesIfNeeded()
            return
        }
        _ = appPreferencesStore.update { $0.volume = volume }
        appPreferencesStore.schedulePersistence()
    }

    private func savePlaybackRatePreference() {
        guard shouldPersistUserPreferences else { return }
        guard appPreferencesStore.persistenceState == .writable else {
            playbackRate = appPreferencesStore.load().playbackRate
            notifyProtectedCoherentPreferencesIfNeeded()
            return
        }
        _ = appPreferencesStore.update { $0.playbackRate = playbackRate }
        appPreferencesStore.schedulePersistence()
    }

    /// 加载用户的播放控制开关
    private func loadUserPlaybackSwitches() {
        let d = UserDefaults.standard
        if d.object(forKey: userNormalizationKey) != nil {
            isNormalizationEnabled = d.bool(forKey: userNormalizationKey)
        }
        if d.object(forKey: userImmersivePlaybackEnabledKey) != nil {
            isImmersivePlaybackEnabled = d.bool(forKey: userImmersivePlaybackEnabledKey)
        }
        updateLoopSetting()
    }

    private func saveNormalizationPreference() {
        let d = UserDefaults.standard
        d.set(isNormalizationEnabled, forKey: userNormalizationKey)
    }

    private func savePlaybackModePreference() {
        guard shouldPersistUserPreferences,
              let mode = AppPreferencesStore.PlaybackMode(rawValue: playbackMode.rawValue) else { return }
        guard appPreferencesStore.persistenceState == .writable else {
            playbackMode = PlaybackMode(rawValue: appPreferencesStore.load().playbackMode.rawValue) ?? .shuffle
            updateLoopSetting()
            notifyProtectedCoherentPreferencesIfNeeded()
            return
        }
        _ = appPreferencesStore.update { $0.playbackMode = mode }
        _ = appPreferencesStore.persist()
    }

    private func notifyProtectedCoherentPreferencesIfNeeded() {
        guard !didNotifyProtectedCoherentPreferences else { return }
        didNotifyProtectedCoherentPreferences = true
        PersistenceLogger.notifyUser(
            title: "播放器偏好处于只读保护模式",
            subtitle: "设置已恢复为安全的持久值"
        )
    }

    @discardableResult
    func flushUserPreferencesPersistence() -> Result<Void, AppPreferencesStore.PersistenceError> {
        guard shouldPersistUserPreferences else { return .success(()) }
        return appPreferencesStore.flush()
    }

    private func saveImmersivePlaybackPreference() {
        UserDefaults.standard.set(
            isImmersivePlaybackEnabled,
            forKey: userImmersivePlaybackEnabledKey
        )
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

}

extension Notification.Name {
    static let audioPlayerDidFinish = Notification.Name("audioPlayerDidFinish")
    static let loadLastPlayedFile = Notification.Name("loadLastPlayedFile")
    static let audioPlayerDidFailToPlay = Notification.Name("audioPlayerDidFailToPlay")
    static let audioPlayerDidLoadFile = Notification.Name("audioPlayerDidLoadFile")
}
