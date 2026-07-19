import AVFoundation
import Foundation

/// The physical and useful playback range of an audio file.
///
/// Bounds are advisory and never modify the source file. An invalid duration or
/// analysis result always collapses to a safe, untrimmed range.
struct PlaybackBounds: Codable, Equatable, Sendable {
    let audibleStart: TimeInterval
    let audibleEnd: TimeInterval
    let physicalDuration: TimeInterval

    init(audibleStart: TimeInterval, audibleEnd: TimeInterval, physicalDuration: TimeInterval) {
        self.audibleStart = audibleStart
        self.audibleEnd = audibleEnd
        self.physicalDuration = physicalDuration
    }

    static func fullRange(duration: TimeInterval) -> PlaybackBounds {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        return PlaybackBounds(
            audibleStart: 0,
            audibleEnd: safeDuration,
            physicalDuration: safeDuration
        )
    }

    var startTime: TimeInterval { audibleStart }
    var endTime: TimeInterval { audibleEnd }
    var hasTrimmedStart: Bool { audibleStart > 0 }
    var hasTrimmedEnd: Bool { audibleEnd < physicalDuration }

    fileprivate var isValid: Bool {
        physicalDuration.isFinite
            && physicalDuration > 0
            && audibleStart.isFinite
            && audibleEnd.isFinite
            && audibleStart >= 0
            && audibleEnd > audibleStart
            && audibleEnd <= physicalDuration
    }
}

/// Finds and caches conservative audible bounds by scanning only a file's head
/// and tail. Actor isolation intentionally keeps analysis and cache mutations
/// serial without allocating a decoded PCM cache.
actor ImmersivePlaybackAnalyzer {
    static let algorithmVersion = 6
    private static let cacheFormatVersion = 2
    private static let cacheFileName = "immersive-boundaries.json"
    private static let maximumCacheEntries = 5_000
    private static let cacheLowWatermark = 4_500
    private static let maximumCacheBytes = 8 * 1_024 * 1_024
    private static let failureRetryDelay: TimeInterval = 15 * 60
    private static let accessTimestampWriteInterval: TimeInterval = 24 * 60 * 60
    private static let maximumExtendedEdgeDuration: TimeInterval = 120

    struct Configuration: Equatable, Sendable {
        var analysisEdgeDuration: TimeInterval = 30
        var analysisWindowDuration: TimeInterval = 0.05
        var rmsThresholdDBFS: Double = -60
        var peakThresholdDBFS: Double = -50
        var protectionRMSDBFS: Double = -70
        var protectionPeakDBFS: Double = -60
        var minimumConsecutiveAudibleWindows: Int = 2
        var minimumSustainedAudibleDuration: TimeInterval = 0.12
        var leadingSafetyPadding: TimeInterval = 0.10
        var trailingSafetyPadding: TimeInterval = 0.35
        var trailingReferencePercentile: Double = 0.90
        var trailingRelativeDropDB: Double = 32
        var minimumTrailingQuietSuffixDuration: TimeInterval = 0.75
        var trailingConfidenceWindowDuration: TimeInterval = 2
        var minimumTrailingConfidenceDropDB: Double = 18
        var inaudibleTailRMSCeilingDBFS: Double = -62
        var inaudibleTailPeakCeilingDBFS: Double = -55
        var minimumTrailingFadeDropDB: Double = 8
        var minimumTrackDuration: TimeInterval = 3
        var minimumAudibleDuration: TimeInterval = 2
        var maximumTrimFraction: Double = 0.35
        var minimumUsefulTrim: TimeInterval = 0.15
        var analysisTimeout: TimeInterval = 3.0

        var cacheSignature: String {
            [
                "a=\(ImmersivePlaybackAnalyzer.algorithmVersion)",
                "edge=\(analysisEdgeDuration.bitPattern)",
                "window=\(analysisWindowDuration.bitPattern)",
                "rms=\(rmsThresholdDBFS.bitPattern)",
                "peak=\(peakThresholdDBFS.bitPattern)",
                "protectRms=\(protectionRMSDBFS.bitPattern)",
                "protectPeak=\(protectionPeakDBFS.bitPattern)",
                "count=\(minimumConsecutiveAudibleWindows)",
                "sustain=\(minimumSustainedAudibleDuration.bitPattern)",
                "lead=\(leadingSafetyPadding.bitPattern)",
                "trail=\(trailingSafetyPadding.bitPattern)",
                "tailPercentile=\(trailingReferencePercentile.bitPattern)",
                "tailRelativeDrop=\(trailingRelativeDropDB.bitPattern)",
                "tailQuietSuffix=\(minimumTrailingQuietSuffixDuration.bitPattern)",
                "tailConfidenceWindow=\(trailingConfidenceWindowDuration.bitPattern)",
                "tailConfidenceDrop=\(minimumTrailingConfidenceDropDB.bitPattern)",
                "tailInaudibleRms=\(inaudibleTailRMSCeilingDBFS.bitPattern)",
                "tailInaudiblePeak=\(inaudibleTailPeakCeilingDBFS.bitPattern)",
                "tailFadeDrop=\(minimumTrailingFadeDropDB.bitPattern)",
                "track=\(minimumTrackDuration.bitPattern)",
                "audible=\(minimumAudibleDuration.bitPattern)",
                "fraction=\(maximumTrimFraction.bitPattern)",
                "useful=\(minimumUsefulTrim.bitPattern)"
            ].joined(separator: "|")
        }

        fileprivate var isValid: Bool {
            analysisEdgeDuration.isFinite && analysisEdgeDuration > 0
                && analysisWindowDuration.isFinite && analysisWindowDuration > 0
                && rmsThresholdDBFS.isFinite && (-160 ... 0).contains(rmsThresholdDBFS)
                && peakThresholdDBFS.isFinite && (-160 ... 0).contains(peakThresholdDBFS)
                && protectionRMSDBFS.isFinite && (-160 ... rmsThresholdDBFS).contains(protectionRMSDBFS)
                && protectionPeakDBFS.isFinite && (-160 ... peakThresholdDBFS).contains(protectionPeakDBFS)
                && analysisEdgeDuration <= 120
                && analysisWindowDuration <= 1
                && minimumConsecutiveAudibleWindows > 0
                && minimumSustainedAudibleDuration.isFinite && minimumSustainedAudibleDuration > 0
                && leadingSafetyPadding.isFinite && leadingSafetyPadding >= 0
                && trailingSafetyPadding.isFinite && trailingSafetyPadding >= 0
                && trailingReferencePercentile.isFinite
                && (0.5 ... 1).contains(trailingReferencePercentile)
                && trailingRelativeDropDB.isFinite && (0 ... 160).contains(trailingRelativeDropDB)
                && minimumTrailingQuietSuffixDuration.isFinite
                && minimumTrailingQuietSuffixDuration > 0
                && trailingConfidenceWindowDuration.isFinite
                && trailingConfidenceWindowDuration > 0
                && trailingConfidenceWindowDuration <= analysisEdgeDuration
                && minimumTrailingConfidenceDropDB.isFinite
                && (0 ... 160).contains(minimumTrailingConfidenceDropDB)
                && inaudibleTailRMSCeilingDBFS.isFinite
                && (protectionRMSDBFS ... rmsThresholdDBFS).contains(inaudibleTailRMSCeilingDBFS)
                && inaudibleTailPeakCeilingDBFS.isFinite
                && (protectionPeakDBFS ... peakThresholdDBFS).contains(inaudibleTailPeakCeilingDBFS)
                && minimumTrailingFadeDropDB.isFinite
                && (0 ... 160).contains(minimumTrailingFadeDropDB)
                && minimumTrackDuration.isFinite && minimumTrackDuration >= 0
                && minimumAudibleDuration.isFinite && minimumAudibleDuration > 0
                && maximumTrimFraction.isFinite && (0 ... 0.9).contains(maximumTrimFraction)
                && minimumUsefulTrim.isFinite && minimumUsefulTrim >= 0
                && analysisTimeout.isFinite && analysisTimeout > 0 && analysisTimeout <= 30
        }
    }

    struct WindowMetric: Equatable, Sendable {
        let startTime: TimeInterval
        let duration: TimeInterval
        let rmsDBFS: Double
        let peakDBFS: Double

        var endTime: TimeInterval { startTime + duration }
    }

    private struct FileSignature: Codable, Equatable, Sendable {
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?

        init?(_ snapshot: FileValidationSnapshot) {
            guard snapshot.exists else { return nil }
            fileSize = snapshot.fileSize
            mtimeNs = snapshot.mtimeNs
            inode = snapshot.inode
        }
    }

    private struct CacheEntry: Codable, Equatable {
        let signature: FileSignature
        let bounds: PlaybackBounds
        var lastAccessedAt: TimeInterval?
    }

    private struct FailureEntry: Codable, Equatable {
        let signature: FileSignature
        let retryAfter: TimeInterval
        let attemptCount: Int
    }

    private struct CacheFile: Codable {
        let formatVersion: Int
        let algorithmVersion: Int
        let configurationSignature: String
        let entries: [String: CacheEntry]
        let failures: [String: FailureEntry]
    }

    private struct LegacyCacheFile: Codable {
        let formatVersion: Int
        let algorithmVersion: Int
        let configurationSignature: String
        let entries: [String: LegacyCacheEntry]
    }

    private struct LegacyCacheEntry: Codable {
        let signature: FileSignature
        let bounds: PlaybackBounds
    }

    private struct CacheVersionProbe: Codable {
        let formatVersion: Int?
    }

    enum CachePersistenceError: Error, Equatable, LocalizedError, Sendable {
        case blockedByProtectedFile
        case storageUnavailable
        case encodeFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .blockedByProtectedFile: return "受保护的分析文件无法安全替换"
            case .storageUnavailable: return "沉浸分析缓存目录不可访问"
            case .encodeFailed: return "沉浸分析缓存编码失败"
            case .writeFailed: return "沉浸分析缓存写入失败"
            }
        }
    }

    struct CacheFlushReport: Equatable, Sendable {
        let wroteFile: Bool
        let entryCount: Int
        let failureCount: Int
    }

    struct CacheClearReport: Equatable, Sendable {
        let removedEntryCount: Int
        let removedFailureCount: Int
    }

    struct AnalysisOutcome: Sendable {
        let bounds: PlaybackBounds
        let isCacheable: Bool
    }

    typealias AnalysisOperation = @Sendable (URL, Configuration) throws -> AnalysisOutcome

    private enum AnalysisFailure: Error {
        case cancelled(duration: TimeInterval)
        case readFailed(duration: TimeInterval)
        case workerBusy

        var fallback: PlaybackBounds {
            switch self {
            case let .cancelled(duration), let .readFailed(duration):
                return .fullRange(duration: duration)
            case .workerBusy:
                return .fullRange(duration: 0)
            }
        }
    }

    /// Keeps at most one synchronous AVFoundation decode in flight. A timed-out
    /// decoder may ignore cooperative cancellation, so later requests fail fast
    /// instead of accumulating an unbounded actor queue behind it.
    private final class DecodeWorker: @unchecked Sendable {
        private let operation: AnalysisOperation
        private let lock = NSLock()
        private var isBusy = false

        init(operation: @escaping AnalysisOperation) {
            self.operation = operation
        }

        func analyze(
            url: URL,
            configuration: Configuration
        ) throws -> AnalysisOutcome {
            lock.lock()
            guard !isBusy else {
                lock.unlock()
                throw AnalysisFailure.workerBusy
            }
            isBusy = true
            lock.unlock()
            defer {
                lock.lock()
                isBusy = false
                lock.unlock()
            }
            return try operation(url, configuration)
        }
    }

    private let cacheFileURL: URL?
    private let configuration: Configuration
    private let decodeWorker: DecodeWorker
    private var didLoadCache = false
    private var entries: [String: CacheEntry] = [:]
    private var failures: [String: FailureEntry] = [:]
    private var persistenceIsBlocked = false
    private var blockedQuarantineReason: String?
    private var cacheSaveRevision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var cacheEpoch: UInt64 = 0
    private var cacheSaveTask: Task<Void, Never>?
    private var cacheRetryAttempt = 0

    init(
        cacheFileURL: URL? = ImmersivePlaybackAnalyzer.defaultCacheFileURL(),
        configuration: Configuration = Configuration(),
        analysisOperation: @escaping AnalysisOperation = { url, configuration in
            try ImmersivePlaybackAnalyzer.analyzeFile(at: url, configuration: configuration)
        }
    ) {
        self.cacheFileURL = cacheFileURL
        self.configuration = configuration
        decodeWorker = DecodeWorker(operation: analysisOperation)
    }

    nonisolated static func defaultCacheFileURL(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("MusicPlayer", isDirectory: true)
            .appendingPathComponent(cacheFileName, isDirectory: false)
    }

    /// Returns cached bounds when the canonical path and complete file
    /// validation signature still match.
    func cachedBoundsIfValid(
        for url: URL,
        snapshot suppliedSnapshot: FileValidationSnapshot? = nil
    ) -> PlaybackBounds? {
        loadCacheIfNeeded()

        let snapshot = FileValidationSnapshot.load(for: url)
        if let suppliedSnapshot, suppliedSnapshot != snapshot { return nil }
        guard let signature = FileSignature(snapshot) else {
            removeEntry(for: url)
            return nil
        }

        let key = PathKey.canonical(for: url)
        guard var entry = entries[key] else { return nil }
        guard entry.signature == signature, entry.bounds.isValid else {
            entries.removeValue(forKey: key)
            failures.removeValue(forKey: key)
            scheduleCacheSave()
            return nil
        }
        let now = Date().timeIntervalSince1970
        if now - (entry.lastAccessedAt ?? 0) >= Self.accessTimestampWriteInterval {
            entry.lastAccessedAt = now
            entries[key] = entry
            scheduleCacheSave()
        }
        return entry.bounds
    }

    /// Scans a bounded head/tail region on a cache miss. Read failures and
    /// cancellation always return a full-range fallback instead of partial or
    /// aggressive bounds.
    func bounds(
        for url: URL,
        snapshot suppliedSnapshot: FileValidationSnapshot? = nil,
        onLateBounds: (@Sendable (PlaybackBounds) -> Void)? = nil
    ) async -> PlaybackBounds {
        if Task.isCancelled { return .fullRange(duration: 0) }
        if let cached = cachedBoundsIfValid(for: url, snapshot: suppliedSnapshot) {
            return cached
        }

        let initialSnapshot = FileValidationSnapshot.load(for: url)
        if let suppliedSnapshot, suppliedSnapshot != initialSnapshot {
            return .fullRange(duration: 0)
        }
        guard let initialSignature = FileSignature(initialSnapshot) else {
            return .fullRange(duration: 0)
        }
        loadCacheIfNeeded()
        let key = PathKey.canonical(for: url)
        if let failure = failures[key] {
            if failure.signature == initialSignature,
               failure.retryAfter > Date().timeIntervalSince1970 {
                return .fullRange(duration: 0)
            }
            failures.removeValue(forKey: key)
            scheduleCacheSave()
        }
        let capturedEpoch = cacheEpoch
        let worker = decodeWorker
        let analysisConfiguration = configuration

        let outcome: AnalysisOutcome
        do {
            outcome = try await Self.withDeadline(
                configuration.analysisTimeout,
                operation: {
                try worker.analyze(url: url, configuration: analysisConfiguration)
                },
                onLateSuccess: { [weak self] lateOutcome in
                    Task {
                        guard let acceptedBounds = await self?.cacheLateOutcome(
                            lateOutcome,
                            url: url,
                            key: key,
                            expectedSignature: initialSignature,
                            expectedEpoch: capturedEpoch
                        ) else { return }
                        onLateBounds?(acceptedBounds)
                    }
                }
            )
        } catch let failure as AnalysisFailure {
            if case .readFailed = failure {
                recordFailure(for: key, signature: initialSignature)
            }
            return failure.fallback
        } catch TimeoutError.timedOut {
            // A deadline is a playback-latency decision, not proof that the
            // file is bad. The single worker may still finish and cache safely.
            return .fullRange(duration: 0)
        } catch {
            if !Task.isCancelled {
                recordFailure(for: key, signature: initialSignature)
            }
            return .fullRange(duration: 0)
        }

        guard !Task.isCancelled else {
            return .fullRange(duration: outcome.bounds.physicalDuration)
        }
        guard capturedEpoch == cacheEpoch else {
            return outcome.bounds
        }

        // Never cache an analysis performed while the source was being
        // replaced or edited.
        let finalSnapshot = FileValidationSnapshot.load(for: url)
        guard let finalSignature = FileSignature(finalSnapshot), finalSignature == initialSignature else {
            return .fullRange(duration: outcome.bounds.physicalDuration)
        }

        cacheOutcome(outcome, key: key, signature: finalSignature)
        return outcome.bounds
    }

    private func cacheLateOutcome(
        _ outcome: AnalysisOutcome,
        url: URL,
        key: String,
        expectedSignature: FileSignature,
        expectedEpoch: UInt64
    ) -> PlaybackBounds? {
        guard expectedEpoch == cacheEpoch,
              let finalSignature = FileSignature(FileValidationSnapshot.load(for: url)),
              finalSignature == expectedSignature,
              outcome.isCacheable,
              outcome.bounds.isValid else { return nil }
        cacheOutcome(outcome, key: key, signature: finalSignature)
        return outcome.bounds
    }

    private func cacheOutcome(
        _ outcome: AnalysisOutcome,
        key: String,
        signature: FileSignature
    ) {
        guard outcome.isCacheable, outcome.bounds.isValid else { return }
        loadCacheIfNeeded()
        if entries[key] == nil, entries.count >= Self.maximumCacheEntries {
            let removeCount = entries.count - Self.cacheLowWatermark + 1
            for staleKey in entries.sorted(by: { lhs, rhs in
                let lhsAccess = lhs.value.lastAccessedAt ?? 0
                let rhsAccess = rhs.value.lastAccessedAt ?? 0
                if lhsAccess == rhsAccess { return lhs.key < rhs.key }
                return lhsAccess < rhsAccess
            }).prefix(removeCount).map(\.key) {
                entries.removeValue(forKey: staleKey)
            }
        }
        entries[key] = CacheEntry(
            signature: signature,
            bounds: outcome.bounds,
            lastAccessedAt: Date().timeIntervalSince1970
        )
        failures.removeValue(forKey: key)
        scheduleCacheSave()
    }

    func remove(for url: URL) {
        loadCacheIfNeeded()
        removeEntry(for: url)
    }

    @discardableResult
    func removeAll() -> Result<CacheClearReport, CachePersistenceError> {
        loadCacheIfNeeded()
        if persistenceIsBlocked {
            retryProtectedCacheQuarantine()
        }
        guard !persistenceIsBlocked else { return .failure(.blockedByProtectedFile) }
        let previousEntries = entries
        let previousFailures = failures
        let report = CacheClearReport(
            removedEntryCount: previousEntries.count,
            removedFailureCount: previousFailures.count
        )
        entries.removeAll(keepingCapacity: false)
        failures.removeAll(keepingCapacity: false)
        cacheEpoch &+= 1
        cacheSaveRevision &+= 1
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        switch persistCacheNow(force: true) {
        case .success:
            return .success(report)
        case .failure(let error):
            entries = previousEntries
            failures = previousFailures
            cacheEpoch &+= 1
            scheduleCacheSave()
            return .failure(error)
        }
    }

    @discardableResult
    func flushPersistence() -> Result<CacheFlushReport, CachePersistenceError> {
        loadCacheIfNeeded()
        if persistenceIsBlocked {
            retryProtectedCacheQuarantine()
        }
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        let result = persistCacheNow(force: false)
        if case .failure = result {
            scheduleCacheRetry(for: cacheSaveRevision)
        }
        return result
    }

    /// Pure boundary detection over fixed-window measurements. This function
    /// is intentionally independent of AVFoundation so thresholds and safety
    /// rules can be regression tested without touching audio or disk state.
    static func detectBounds(
        physicalDuration: TimeInterval,
        headMetrics: [WindowMetric],
        tailMetrics: [WindowMetric],
        configuration: Configuration = Configuration()
    ) -> PlaybackBounds {
        let fallback = PlaybackBounds.fullRange(duration: physicalDuration)
        guard configuration.isValid,
              physicalDuration.isFinite,
              physicalDuration >= configuration.minimumTrackDuration,
              metricsAreValid(headMetrics, physicalDuration: physicalDuration),
              metricsAreValid(tailMetrics, physicalDuration: physicalDuration) else {
            return fallback
        }

        let leadingRunStart = firstSustainedAudibleRunStart(
            in: headMetrics,
            configuration: configuration
        )
        let baselineTrailingRunEnd = lastSustainedAudibleRunEnd(
            in: tailMetrics,
            configuration: configuration
        )

        // A completely silent (or below-threshold) scan is not enough evidence
        // to remove anything.
        guard leadingRunStart != nil || baselineTrailingRunEnd != nil else { return fallback }

        // Keep the leading edge conservative so a quiet count-in is preserved.
        // The trailing edge is intentionally stricter: its gate is relative to
        // each track's own tail level, requires a sustained run, and is accepted
        // only when the physical ending is demonstrably quieter. An isolated
        // codec spike after established silence can therefore no longer revive
        // the boundary.
        let protectedLeadingStart = headMetrics.first(where: {
            isProtectedAudio($0, configuration: configuration)
        })?.startTime
        let rawLeadingStart = [leadingRunStart, protectedLeadingStart].compactMap { $0 }.min()
        let adaptiveTrailingEnd = confidentAdaptiveTrailingEnd(
            in: tailMetrics,
            physicalDuration: physicalDuration,
            configuration: configuration
        )
        let sustainedMeaningfulTailEnd = lastSustainedAudibleRunEnd(
            in: tailMetrics,
            rmsThresholdDBFS: configuration.inaudibleTailRMSCeilingDBFS,
            peakThresholdDBFS: configuration.inaudibleTailPeakCeilingDBFS,
            configuration: configuration
        )
        let sustainedProtectedTailEnd = lastSustainedAudibleRunEnd(
            in: tailMetrics,
            rmsThresholdDBFS: configuration.protectionRMSDBFS,
            peakThresholdDBFS: configuration.protectionPeakDBFS,
            configuration: configuration
        )
        let candidateTrailingEnd: TimeInterval?
        if let adaptiveTrailingEnd {
            candidateTrailingEnd = adaptiveTrailingEnd
        } else if let sustainedMeaningfulTailEnd,
                  physicalDuration - sustainedMeaningfulTailEnd
                    >= configuration.minimumTrailingQuietSuffixDuration {
            // Preserve a stable quiet outro that the relative gate rejected.
            candidateTrailingEnd = sustainedMeaningfulTailEnd
        } else if let sustainedProtectedTailEnd,
                  physicalDuration - sustainedProtectedTailEnd
                    >= configuration.minimumTrailingQuietSuffixDuration {
            // Ultra-quiet sustained content gets the still more conservative
            // protection floor before any terminal silence is removed.
            candidateTrailingEnd = sustainedProtectedTailEnd
        } else if leadingRunStart != nil,
                  baselineTrailingRunEnd == nil,
                  sustainedProtectedTailEnd == nil {
            // When the complete tail scan contains no sustained signal even at
            // the protection floor, use its first sample as a conservative
            // operational boundary. A lone click cannot defeat this fallback.
            candidateTrailingEnd = tailMetrics.first?.startTime
        } else {
            candidateTrailingEnd = nil
        }
        // Once a discardable suffix is established, never cut before its final
        // individually meaningful window. The threshold stays above the raw
        // protection floor so stable codec/noise floors around -66 dBFS do not
        // revive the whole tail, while a short coda, syllable, or loud transient
        // remains protected even without a sustained run.
        let lastMeaningfulTailEnd = tailMetrics.last(where: {
            $0.rmsDBFS >= configuration.inaudibleTailRMSCeilingDBFS
                || $0.peakDBFS > configuration.inaudibleTailPeakCeilingDBFS
        })?.endTime
        // A relative gate can classify a genuinely musical but very quiet coda
        // as part of the noise floor. Preserve its last sustained run when it
        // is followed by a real quiet suffix. Long low-level encoding noise
        // still reaches the physical end and therefore does not qualify.
        let protectedCodaEnd = sustainedProtectedTailEnd.flatMap { end in
            physicalDuration - end >= configuration.minimumTrailingQuietSuffixDuration
                ? end
                : nil
        }
        let rawTrailingEnd: TimeInterval? = {
            guard let candidateTrailingEnd else { return nil }
            return [candidateTrailingEnd, lastMeaningfulTailEnd, protectedCodaEnd]
                .compactMap { $0 }
                .max()
        }()

        var proposedStart = rawLeadingStart.map {
            max(0, $0 - configuration.leadingSafetyPadding)
        } ?? 0
        var proposedEnd = rawTrailingEnd.map {
            min(physicalDuration, $0 + configuration.trailingSafetyPadding)
        } ?? physicalDuration

        if proposedStart < configuration.minimumUsefulTrim {
            proposedStart = 0
        }
        if physicalDuration - proposedEnd < configuration.minimumUsefulTrim {
            proposedEnd = physicalDuration
        }

        guard proposedStart.isFinite,
              proposedEnd.isFinite,
              proposedStart >= 0,
              proposedEnd <= physicalDuration,
              proposedEnd > proposedStart else {
            return fallback
        }

        let audibleDuration = proposedEnd - proposedStart
        let trimDuration = proposedStart + (physicalDuration - proposedEnd)
        guard audibleDuration >= configuration.minimumAudibleDuration,
              trimDuration / physicalDuration <= configuration.maximumTrimFraction else {
            return fallback
        }

        return PlaybackBounds(
            audibleStart: proposedStart,
            audibleEnd: proposedEnd,
            physicalDuration: physicalDuration
        )
    }

    // MARK: - Detection

    private static func metricsAreValid(
        _ metrics: [WindowMetric],
        physicalDuration: TimeInterval
    ) -> Bool {
        var previousStart = -Double.infinity
        for metric in metrics {
            guard metric.startTime.isFinite,
                  metric.duration.isFinite,
                  metric.rmsDBFS.isFinite,
                  metric.peakDBFS.isFinite,
                  metric.startTime >= 0,
                  metric.duration > 0,
                  metric.endTime <= physicalDuration + 0.001,
                  metric.startTime >= previousStart else {
                return false
            }
            previousStart = metric.startTime
        }
        return true
    }

    private static func isAudible(_ metric: WindowMetric, configuration: Configuration) -> Bool {
        isAudible(
            metric,
            rmsThresholdDBFS: configuration.rmsThresholdDBFS,
            peakThresholdDBFS: configuration.peakThresholdDBFS
        )
    }

    private static func isAudible(
        _ metric: WindowMetric,
        rmsThresholdDBFS: Double,
        peakThresholdDBFS: Double
    ) -> Bool {
        metric.rmsDBFS >= rmsThresholdDBFS || metric.peakDBFS >= peakThresholdDBFS
    }

    private static func isProtectedAudio(_ metric: WindowMetric, configuration: Configuration) -> Bool {
        metric.rmsDBFS >= configuration.protectionRMSDBFS
            || metric.peakDBFS >= configuration.protectionPeakDBFS
    }

    private static func firstSustainedAudibleRunStart(
        in metrics: [WindowMetric],
        configuration: Configuration
    ) -> TimeInterval? {
        var runStart: TimeInterval?
        var runDuration: TimeInterval = 0
        var runCount = 0
        var previousEnd: TimeInterval?

        for metric in metrics {
            let gap = previousEnd.map { metric.startTime - $0 } ?? 0
            let remainsConsecutive = gap <= continuityTolerance(configuration: configuration)

            if isAudible(metric, configuration: configuration) {
                if runStart == nil || !remainsConsecutive {
                    runStart = metric.startTime
                    runDuration = 0
                    runCount = 0
                }
                runDuration += metric.duration
                runCount += 1
                if runCount >= configuration.minimumConsecutiveAudibleWindows,
                   runDuration >= configuration.minimumSustainedAudibleDuration {
                    return runStart
                }
            } else {
                runStart = nil
                runDuration = 0
                runCount = 0
            }
            previousEnd = metric.endTime
        }
        return nil
    }

    private static func lastSustainedAudibleRunEnd(
        in metrics: [WindowMetric],
        configuration: Configuration
    ) -> TimeInterval? {
        lastSustainedAudibleRunEnd(
            in: metrics,
            rmsThresholdDBFS: configuration.rmsThresholdDBFS,
            peakThresholdDBFS: configuration.peakThresholdDBFS,
            configuration: configuration
        )
    }

    private static func lastSustainedAudibleRunEnd(
        in metrics: [WindowMetric],
        rmsThresholdDBFS: Double,
        peakThresholdDBFS: Double,
        configuration: Configuration
    ) -> TimeInterval? {
        var runDuration: TimeInterval = 0
        var runCount = 0
        var runEnd: TimeInterval?
        var previousEnd: TimeInterval?
        var lastQualifiedEnd: TimeInterval?

        for metric in metrics {
            let gap = previousEnd.map { metric.startTime - $0 } ?? 0
            let remainsConsecutive = gap <= continuityTolerance(configuration: configuration)

            if isAudible(
                metric,
                rmsThresholdDBFS: rmsThresholdDBFS,
                peakThresholdDBFS: peakThresholdDBFS
            ) {
                if runEnd == nil || !remainsConsecutive {
                    runDuration = 0
                    runCount = 0
                }
                runDuration += metric.duration
                runCount += 1
                runEnd = metric.endTime
                if runCount >= configuration.minimumConsecutiveAudibleWindows,
                   runDuration >= configuration.minimumSustainedAudibleDuration {
                    lastQualifiedEnd = runEnd
                }
            } else {
                runDuration = 0
                runCount = 0
                runEnd = nil
            }
            previousEnd = metric.endTime
        }
        return lastQualifiedEnd
    }

    private static func confidentAdaptiveTrailingEnd(
        in metrics: [WindowMetric],
        physicalDuration: TimeInterval,
        configuration: Configuration
    ) -> TimeInterval? {
        let referenceMetrics = metrics.filter {
            isAudible($0, configuration: configuration)
        }
        guard !referenceMetrics.isEmpty,
              let referenceRMS = percentile(
                referenceMetrics.map(\.rmsDBFS),
                fraction: configuration.trailingReferencePercentile
              ),
              let referencePeak = percentile(
                referenceMetrics.map(\.peakDBFS),
                fraction: configuration.trailingReferencePercentile
              ) else {
            return nil
        }

        let rmsThreshold = max(
            configuration.rmsThresholdDBFS,
            referenceRMS - configuration.trailingRelativeDropDB
        )
        let peakThreshold = max(
            configuration.peakThresholdDBFS,
            referencePeak - configuration.trailingRelativeDropDB
        )
        guard let sustainedEnd = lastSustainedAudibleRunEnd(
            in: metrics,
            rmsThresholdDBFS: rmsThreshold,
            peakThresholdDBFS: peakThreshold,
            configuration: configuration
        ),
        physicalDuration - sustainedEnd >= configuration.minimumTrailingQuietSuffixDuration else {
            return nil
        }

        let confidenceWindowStart = max(
            metrics.first?.startTime ?? 0,
            max(
                sustainedEnd,
                physicalDuration - configuration.trailingConfidenceWindowDuration
            )
        )
        let terminalRMSValues = metrics.lazy
            .filter { $0.endTime > confidenceWindowStart }
            .map(\.rmsDBFS)
        guard let terminalMedianRMS = percentile(
            Array(terminalRMSValues),
            fraction: 0.5
        ),
        referenceRMS - terminalMedianRMS >= configuration.minimumTrailingConfidenceDropDB,
        trailingSuffixIsSafelyDiscardable(
            in: metrics,
            after: sustainedEnd,
            beforeTerminalWindowAt: confidenceWindowStart,
            configuration: configuration
        ) else {
            return nil
        }
        return sustainedEnd
    }

    /// Distinguishes an inaudible floor or a progressive fade from a sustained
    /// quiet outro. Loud-to-quiet contrast alone is insufficient: spoken
    /// codas and deliberately soft arrangements can remain stable for seconds.
    private static func trailingSuffixIsSafelyDiscardable(
        in metrics: [WindowMetric],
        after sustainedEnd: TimeInterval,
        beforeTerminalWindowAt terminalWindowStart: TimeInterval,
        configuration: Configuration
    ) -> Bool {
        let suffix = metrics.filter { $0.endTime > sustainedEnd }
        guard let suffixRMS = percentile(
            suffix.map(\.rmsDBFS),
            fraction: configuration.trailingReferencePercentile
        ),
        let suffixPeak = percentile(
            suffix.map(\.peakDBFS),
            fraction: configuration.trailingReferencePercentile
        ) else {
            return false
        }

        let sustainedMeaningfulSuffixEnd = lastSustainedAudibleRunEnd(
            in: suffix,
            rmsThresholdDBFS: configuration.inaudibleTailRMSCeilingDBFS,
            peakThresholdDBFS: configuration.inaudibleTailPeakCeilingDBFS,
            configuration: configuration
        )
        if suffixRMS <= configuration.inaudibleTailRMSCeilingDBFS,
           suffixPeak <= configuration.inaudibleTailPeakCeilingDBFS,
           sustainedMeaningfulSuffixEnd == nil {
            return true
        }

        let fadeMetrics = suffix.filter { $0.startTime < terminalWindowStart }
        let comparisonCount = fadeMetrics.count / 3
        let middleMetrics = fadeMetrics
            .dropFirst(comparisonCount)
            .dropLast(comparisonCount)
        guard comparisonCount >= configuration.minimumConsecutiveAudibleWindows,
              let earlyMedian = percentile(
                Array(fadeMetrics.prefix(comparisonCount)).map(\.rmsDBFS),
                fraction: 0.5
              ),
              let middleMedian = percentile(
                Array(middleMetrics).map(\.rmsDBFS),
                fraction: 0.5
              ),
              let lateMedian = percentile(
                Array(fadeMetrics.suffix(comparisonCount)).map(\.rmsDBFS),
                fraction: 0.5
              ) else {
            return false
        }
        let minimumSegmentDrop = configuration.minimumTrailingFadeDropDB / 4
        return earlyMedian - lateMedian >= configuration.minimumTrailingFadeDropDB
            && earlyMedian - middleMedian >= minimumSegmentDrop
            && middleMedian - lateMedian >= minimumSegmentDrop
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty, fraction.isFinite else { return nil }
        let sorted = values.sorted()
        let clampedFraction = min(1, max(0, fraction))
        let index = Int((Double(sorted.count - 1) * clampedFraction).rounded(.down))
        return sorted[index]
    }

    private static func continuityTolerance(configuration: Configuration) -> TimeInterval {
        max(0.01, configuration.analysisWindowDuration * 0.5)
    }

    // MARK: - AVFoundation analysis

    private static func analyzeFile(
        at url: URL,
        configuration: Configuration
    ) throws -> AnalysisOutcome {
        guard configuration.isValid else {
            return AnalysisOutcome(bounds: .fullRange(duration: 0), isCacheable: false)
        }
        if Task.isCancelled { throw AnalysisFailure.cancelled(duration: 0) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AnalysisFailure.readFailed(duration: 0)
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
            throw AnalysisFailure.readFailed(duration: 0)
        }

        let physicalDuration = Double(file.length) / sampleRate
        let fallback = PlaybackBounds.fullRange(duration: physicalDuration)
        guard physicalDuration.isFinite, physicalDuration > 0 else {
            throw AnalysisFailure.readFailed(duration: 0)
        }
        guard physicalDuration >= configuration.minimumTrackDuration else {
            return AnalysisOutcome(bounds: fallback, isCacheable: true)
        }

        let requestedWindowFrames = Int((sampleRate * configuration.analysisWindowDuration).rounded(.up))
        let windowFrameCount = AVAudioFrameCount(max(64, min(requestedWindowFrames, 16_384)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrameCount) else {
            throw AnalysisFailure.readFailed(duration: physicalDuration)
        }

        let edgeFrameCount = AVAudioFramePosition(
            min(Double(file.length), (sampleRate * configuration.analysisEdgeDuration).rounded(.up))
        )
        let tailStart = max(0, file.length - edgeFrameCount)

        var headMetrics: [WindowMetric]
        var tailMetrics: [WindowMetric]
        do {
            headMetrics = try readMetrics(
                from: file,
                using: buffer,
                startFrame: 0,
                frameCount: edgeFrameCount,
                sampleRate: sampleRate,
                physicalDuration: physicalDuration
            )
            tailMetrics = try readMetrics(
                from: file,
                using: buffer,
                startFrame: tailStart,
                frameCount: edgeFrameCount,
                sampleRate: sampleRate,
                physicalDuration: physicalDuration
            )

            // If a complete edge block is silent, continue inward in bounded
            // blocks. This handles long podcast padding without buffering PCM.
            let maximumExtendedFrames = AVAudioFramePosition(
                min(
                    Double(file.length) * configuration.maximumTrimFraction,
                    sampleRate * Self.maximumExtendedEdgeDuration
                ).rounded(.up)
            )
            let maximumScanFrames = max(edgeFrameCount, min(file.length, maximumExtendedFrames))

            var headCursor = edgeFrameCount
            while headCursor < maximumScanFrames,
                  !headMetrics.contains(where: { isProtectedAudio($0, configuration: configuration) }) {
                let count = min(edgeFrameCount, maximumScanFrames - headCursor)
                let next = try readMetrics(
                    from: file,
                    using: buffer,
                    startFrame: headCursor,
                    frameCount: count,
                    sampleRate: sampleRate,
                    physicalDuration: physicalDuration
                )
                guard !next.isEmpty else { break }
                headMetrics.append(contentsOf: next)
                headCursor += count
            }

            let earliestTailFrame = max(0, file.length - maximumScanFrames)
            var extendedTailStart = tailStart
            while extendedTailStart > earliestTailFrame,
                  !tailMetrics.contains(where: { isProtectedAudio($0, configuration: configuration) }) {
                let nextStart = max(earliestTailFrame, extendedTailStart - edgeFrameCount)
                let next = try readMetrics(
                    from: file,
                    using: buffer,
                    startFrame: nextStart,
                    frameCount: extendedTailStart - nextStart,
                    sampleRate: sampleRate,
                    physicalDuration: physicalDuration
                )
                guard !next.isEmpty else { break }
                tailMetrics.insert(contentsOf: next, at: 0)
                extendedTailStart = nextStart
            }
        } catch is CancellationError {
            throw AnalysisFailure.cancelled(duration: physicalDuration)
        } catch {
            throw AnalysisFailure.readFailed(duration: physicalDuration)
        }

        let detected = detectBounds(
            physicalDuration: physicalDuration,
            headMetrics: headMetrics,
            tailMetrics: tailMetrics,
            configuration: configuration
        )
        return AnalysisOutcome(bounds: detected, isCacheable: true)
    }

    /// Races an unstructured decode against a deadline. Unlike a structured
    /// task group, returning on timeout does not wait for a blocking decoder;
    /// cancellation is still propagated and the single decode worker remains
    /// isolated from cache/flush operations.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T,
        onLateSuccess: @escaping @Sendable (T) -> Void
    ) async throws -> T {
        let state = ImmersiveDeadlineState<T>()
        let analysisTask = Task.detached(priority: .utility) {
            do {
                let value = try await operation()
                if !state.resolve(.success(value)) {
                    onLateSuccess(value)
                }
            } catch {
                _ = state.resolve(.failure(error))
            }
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            analysisTask.cancel()
            _ = state.resolve(.failure(TimeoutError.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
            }
        }, onCancel: {
            analysisTask.cancel()
            _ = state.resolve(.failure(CancellationError()))
        })
    }

    private static func readMetrics(
        from file: AVAudioFile,
        using buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        sampleRate: Double,
        physicalDuration: TimeInterval
    ) throws -> [WindowMetric] {
        guard frameCount > 0 else { return [] }
        file.framePosition = startFrame

        let estimatedCount = Int(
            (Double(frameCount) / Double(buffer.frameCapacity)).rounded(.up)
        )
        var metrics: [WindowMetric] = []
        metrics.reserveCapacity(max(1, estimatedCount))

        var cursor = startFrame
        let requestedEnd = min(file.length, startFrame + frameCount)
        while cursor < requestedEnd {
            if Task.isCancelled { throw CancellationError() }

            let remaining = requestedEnd - cursor
            let requestedFrames = AVAudioFrameCount(
                min(AVAudioFramePosition(buffer.frameCapacity), remaining)
            )
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: requestedFrames)
            let actualFrames = AVAudioFramePosition(buffer.frameLength)
            guard actualFrames > 0 else { break }

            let metric = makeMetric(
                from: buffer,
                startTime: Double(cursor) / sampleRate,
                sampleRate: sampleRate,
                physicalDuration: physicalDuration
            )
            metrics.append(metric)
            cursor += actualFrames

            if actualFrames < AVAudioFramePosition(requestedFrames) { break }
        }
        guard cursor >= requestedEnd else {
            throw AnalysisFailure.readFailed(duration: physicalDuration)
        }
        return metrics
    }

    private static func makeMetric(
        from buffer: AVAudioPCMBuffer,
        startTime: TimeInterval,
        sampleRate: Double,
        physicalDuration: TimeInterval
    ) -> WindowMetric {
        guard let channels = buffer.floatChannelData else {
            return WindowMetric(
                startTime: startTime,
                duration: Double(buffer.frameLength) / sampleRate,
                rmsDBFS: .nan,
                peakDBFS: .nan
            )
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var maximumChannelRMS = 0.0
        var maximumPeak = 0.0

        for channelIndex in 0 ..< channelCount {
            let samples = channels[channelIndex]
            var channelSquareSum = 0.0
            var channelPeak = 0.0
            for frameIndex in 0 ..< frameCount {
                let sample = Double(samples[frameIndex])
                guard sample.isFinite else {
                    return WindowMetric(
                        startTime: startTime,
                        duration: Double(frameCount) / sampleRate,
                        rmsDBFS: .nan,
                        peakDBFS: .nan
                    )
                }
                let magnitude = abs(sample)
                channelSquareSum += sample * sample
                channelPeak = max(channelPeak, magnitude)
            }
            let channelRMS = frameCount > 0
                ? sqrt(channelSquareSum / Double(frameCount))
                : 0
            maximumChannelRMS = max(maximumChannelRMS, channelRMS)
            maximumPeak = max(maximumPeak, channelPeak)
        }

        let floorDB = -160.0
        let rmsDB = maximumChannelRMS > 0
            ? max(floorDB, 20 * log10(maximumChannelRMS))
            : floorDB
        let peakDB = maximumPeak > 0
            ? max(floorDB, 20 * log10(maximumPeak))
            : floorDB
        let duration = min(
            Double(frameCount) / sampleRate,
            max(0, physicalDuration - startTime)
        )
        return WindowMetric(
            startTime: startTime,
            duration: duration,
            rmsDBFS: rmsDB,
            peakDBFS: peakDB
        )
    }

    // MARK: - Cache IO

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let cacheFileURL,
              FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }

        let fileSize: Int
        do {
            fileSize = try DerivedCacheFileIO.fileSize(at: cacheFileURL)
        } catch {
            quarantineActiveCache(reason: "unsafe")
            return
        }
        guard fileSize <= Self.maximumCacheBytes else {
            quarantineActiveCache(reason: "oversized")
            return
        }
        guard let data = try? DerivedCacheFileIO.readBoundedRegularFile(
            at: cacheFileURL,
            maximumBytes: Self.maximumCacheBytes
        ) else {
            quarantineActiveCache(reason: "unreadable")
            return
        }

        let decoder = JSONDecoder()
        let probedVersion = (try? decoder.decode(CacheVersionProbe.self, from: data))?.formatVersion
        if let probedVersion, probedVersion > Self.cacheFormatVersion {
            quarantineActiveCache(reason: "future-v\(probedVersion)")
            return
        }

        if probedVersion == Self.cacheFormatVersion,
           let cache = try? decoder.decode(CacheFile.self, from: data),
           cache.algorithmVersion == Self.algorithmVersion,
           cache.configurationSignature == configuration.cacheSignature {
            let normalizedEntryValues = normalizedEntries(cache.entries)
            let normalizedFailureValues = normalizedFailures(cache.failures)
            entries = normalizedEntryValues
            failures = normalizedFailureValues
            if normalizedEntryValues != cache.entries || normalizedFailureValues != cache.failures {
                scheduleCacheSave()
            }
            return
        }

        if probedVersion == 1,
           let legacy = try? decoder.decode(LegacyCacheFile.self, from: data),
           legacy.algorithmVersion == Self.algorithmVersion,
           legacy.configurationSignature == configuration.cacheSignature {
            let now = Date().timeIntervalSince1970
            entries = normalizedEntries(
                legacy.entries.mapValues {
                    CacheEntry(
                        signature: $0.signature,
                        bounds: $0.bounds,
                        lastAccessedAt: now
                    )
                }
            )
            failures = [:]
            scheduleCacheSave()
            return
        }

        quarantineActiveCache(reason: probedVersion == nil ? "corrupt" : "stale")
    }

    private func normalizedEntries(_ source: [String: CacheEntry]) -> [String: CacheEntry] {
        var normalized: [String: CacheEntry] = [:]
        normalized.reserveCapacity(min(source.count, Self.maximumCacheEntries))
        for (path, entry) in source
            .filter({ $0.value.bounds.isValid })
            .sorted(by: { lhs, rhs in
                let lhsAccess = lhs.value.lastAccessedAt ?? 0
                let rhsAccess = rhs.value.lastAccessedAt ?? 0
                if lhsAccess == rhsAccess { return lhs.key < rhs.key }
                return lhsAccess > rhsAccess
            })
            .prefix(Self.maximumCacheEntries) {
            let canonicalPath = PathKey.canonical(path: path)
            guard canonicalPath.utf8.count <= 16 * 1_024,
                  normalized[canonicalPath] == nil else { continue }
            normalized[canonicalPath] = entry
        }
        return normalized
    }

    private func normalizedFailures(_ source: [String: FailureEntry]) -> [String: FailureEntry] {
        var normalized: [String: FailureEntry] = [:]
        normalized.reserveCapacity(min(source.count, 512))
        for (path, failure) in source.sorted(by: { lhs, rhs in
            if lhs.value.retryAfter == rhs.value.retryAfter { return lhs.key < rhs.key }
            return lhs.value.retryAfter > rhs.value.retryAfter
        }) {
            let canonicalPath = PathKey.canonical(path: path)
            guard normalized[canonicalPath] == nil else { continue }
            normalized[canonicalPath] = failure
            if normalized.count == 512 { break }
        }
        return normalized
    }

    private func quarantineActiveCache(reason: String) {
        guard let cacheFileURL else { return }
        do {
            _ = try DerivedCacheFileIO.quarantine(
                cacheFileURL,
                reason: quarantineReason(for: reason)
            )
            persistenceIsBlocked = false
            blockedQuarantineReason = nil
        } catch {
            persistenceIsBlocked = true
            blockedQuarantineReason = reason
        }
    }

    private func quarantineReason(for reason: String) -> DerivedCacheQuarantineReason {
        if reason == "oversized" { return .oversized }
        if reason.hasPrefix("future-v"),
           let version = Int(reason.dropFirst("future-v".count)) {
            return .future(version: version)
        }
        if reason == "stale" { return .legacy(version: Self.algorithmVersion - 1) }
        return .corrupt
    }

    private func retryProtectedCacheQuarantine() {
        guard persistenceIsBlocked, let cacheFileURL else { return }
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            persistenceIsBlocked = false
            blockedQuarantineReason = nil
            return
        }
        quarantineActiveCache(reason: blockedQuarantineReason ?? "corrupt")
    }

    private func removeEntry(for url: URL) {
        let key = PathKey.canonical(for: url)
        let removedEntry = entries.removeValue(forKey: key) != nil
        let removedFailure = failures.removeValue(forKey: key) != nil
        if removedEntry || removedFailure {
            cacheEpoch &+= 1
            scheduleCacheSave()
        }
    }

    private func recordFailure(for key: String, signature: FileSignature) {
        guard !Task.isCancelled else { return }
        let previousAttempts = failures[key]?.signature == signature
            ? failures[key]?.attemptCount ?? 0
            : 0
        let attempts = min(previousAttempts + 1, 8)
        let delay = min(24 * 60 * 60, Self.failureRetryDelay * pow(2, Double(attempts - 1)))
        failures[key] = FailureEntry(
            signature: signature,
            retryAfter: Date().timeIntervalSince1970 + delay,
            attemptCount: attempts
        )
        if failures.count > 512 {
            let overflow = failures.count - 512
            for staleKey in failures
                .sorted(by: { lhs, rhs in
                    if lhs.value.retryAfter == rhs.value.retryAfter { return lhs.key < rhs.key }
                    return lhs.value.retryAfter < rhs.value.retryAfter
                })
                .prefix(overflow)
                .map(\.key) {
                failures.removeValue(forKey: staleKey)
            }
        }
        scheduleCacheSave()
    }

    private func leastRecentlyUsedEntryKey() -> String? {
        entries.min { lhs, rhs in
            let lhsAccess = lhs.value.lastAccessedAt ?? 0
            let rhsAccess = rhs.value.lastAccessedAt ?? 0
            if lhsAccess == rhsAccess { return lhs.key < rhs.key }
            return lhsAccess < rhsAccess
        }?.key
    }

    private func scheduleCacheSave() {
        guard cacheFileURL != nil else { return }
        cacheRetryAttempt = 0
        cacheSaveRevision &+= 1
        let revision = cacheSaveRevision
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.persistCacheIfCurrent(revision)
        }
    }

    private func persistCacheIfCurrent(_ revision: UInt64) {
        guard revision == cacheSaveRevision else { return }
        cacheSaveTask = nil
        if case .failure = persistCacheNow(force: false) {
            scheduleCacheRetry(for: revision)
        } else {
            cacheRetryAttempt = 0
        }
    }

    private func scheduleCacheRetry(for revision: UInt64) {
        guard revision == cacheSaveRevision,
              cacheFileURL != nil,
              !persistenceIsBlocked,
              cacheRetryAttempt < 3 else { return }
        cacheRetryAttempt += 1
        let delay: UInt64
        switch cacheRetryAttempt {
        case 1: delay = 5
        case 2: delay = 30
        default: delay = 120
        }
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.persistCacheIfCurrent(revision)
        }
    }

    private func persistCacheNow(
        force: Bool
    ) -> Result<CacheFlushReport, CachePersistenceError> {
        if persistenceIsBlocked { return .failure(.blockedByProtectedFile) }
        if !force, persistedRevision == cacheSaveRevision {
            return .success(
                CacheFlushReport(
                    wroteFile: false,
                    entryCount: entries.count,
                    failureCount: failures.count
                )
            )
        }
        guard let cacheFileURL else {
            persistedRevision = cacheSaveRevision
            return .success(
                CacheFlushReport(
                    wroteFile: false,
                    entryCount: entries.count,
                    failureCount: failures.count
                )
            )
        }

        var persistedEntries = entries
        var persistedFailures = failures
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded: Data
        do {
            var cache = CacheFile(
                formatVersion: Self.cacheFormatVersion,
                algorithmVersion: Self.algorithmVersion,
                configurationSignature: configuration.cacheSignature,
                entries: persistedEntries,
                failures: persistedFailures
            )
            var data = try encoder.encode(cache)
            while data.count > Self.maximumCacheBytes,
                  !persistedEntries.isEmpty || !persistedFailures.isEmpty {
                if let staleEntry = persistedEntries.min(by: { lhs, rhs in
                    let lhsAccess = lhs.value.lastAccessedAt ?? 0
                    let rhsAccess = rhs.value.lastAccessedAt ?? 0
                    if lhsAccess == rhsAccess { return lhs.key < rhs.key }
                    return lhsAccess < rhsAccess
                })?.key {
                    persistedEntries.removeValue(forKey: staleEntry)
                } else if let staleFailure = persistedFailures.min(by: { lhs, rhs in
                    if lhs.value.retryAfter == rhs.value.retryAfter { return lhs.key < rhs.key }
                    return lhs.value.retryAfter < rhs.value.retryAfter
                })?.key {
                    persistedFailures.removeValue(forKey: staleFailure)
                }
                cache = CacheFile(
                    formatVersion: Self.cacheFormatVersion,
                    algorithmVersion: Self.algorithmVersion,
                    configurationSignature: configuration.cacheSignature,
                    entries: persistedEntries,
                    failures: persistedFailures
                )
                data = try encoder.encode(cache)
            }
            encoded = data
        } catch {
            return .failure(.encodeFailed)
        }

        do {
            try DerivedCacheFileIO.atomicWrite(encoded, to: cacheFileURL)
            entries = persistedEntries
            failures = persistedFailures
            persistedRevision = cacheSaveRevision
            return .success(
                CacheFlushReport(
                    wroteFile: true,
                    entryCount: entries.count,
                    failureCount: failures.count
                )
            )
        } catch {
            return .failure(.writeFailed)
        }
    }
}

private final class ImmersiveDeadlineState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if isResolved, let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
        return true
    }
}
