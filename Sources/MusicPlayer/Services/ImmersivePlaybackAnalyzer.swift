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
    static let algorithmVersion = 3
    private static let cacheFormatVersion = 1
    private static let cacheFileName = "immersive-boundaries.json"
    private static let maximumCacheEntries = 5_000
    private static let maximumCacheBytes = 8 * 1_024 * 1_024

    struct Configuration: Equatable, Sendable {
        var analysisEdgeDuration: TimeInterval = 30
        var analysisWindowDuration: TimeInterval = 0.05
        var rmsThresholdDBFS: Double = -60
        var peakThresholdDBFS: Double = -50
        var protectionRMSDBFS: Double = -70
        var protectionPeakDBFS: Double = -60
        var minimumConsecutiveAudibleWindows: Int = 2
        var minimumSustainedAudibleDuration: TimeInterval = 0.12
        var leadingSafetyPadding: TimeInterval = 0.25
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
    }

    private struct CacheFile: Codable {
        let formatVersion: Int
        let algorithmVersion: Int
        let configurationSignature: String
        let entries: [String: CacheEntry]
    }

    private struct AnalysisOutcome {
        let bounds: PlaybackBounds
        let isCacheable: Bool
    }

    private enum AnalysisFailure: Error {
        case cancelled(duration: TimeInterval)
        case readFailed(duration: TimeInterval)

        var fallback: PlaybackBounds {
            switch self {
            case let .cancelled(duration), let .readFailed(duration):
                return .fullRange(duration: duration)
            }
        }
    }

    private let cacheFileURL: URL?
    private let configuration: Configuration
    private var didLoadCache = false
    private var entries: [String: CacheEntry] = [:]
    private var cacheSaveRevision: UInt64 = 0
    private var cacheSaveTask: Task<Void, Never>?

    init(
        cacheFileURL: URL? = ImmersivePlaybackAnalyzer.defaultCacheFileURL(),
        configuration: Configuration = Configuration()
    ) {
        self.cacheFileURL = cacheFileURL
        self.configuration = configuration
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
        guard let entry = entries[key] else { return nil }
        guard entry.signature == signature, entry.bounds.isValid else {
            entries.removeValue(forKey: key)
            scheduleCacheSave()
            return nil
        }
        return entry.bounds
    }

    /// Scans a bounded head/tail region on a cache miss. Read failures and
    /// cancellation always return a full-range fallback instead of partial or
    /// aggressive bounds.
    func bounds(
        for url: URL,
        snapshot suppliedSnapshot: FileValidationSnapshot? = nil
    ) -> PlaybackBounds {
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

        let outcome: AnalysisOutcome
        do {
            outcome = try Self.analyzeFile(at: url, configuration: configuration)
        } catch let failure as AnalysisFailure {
            return failure.fallback
        } catch {
            return .fullRange(duration: 0)
        }

        guard !Task.isCancelled else {
            return .fullRange(duration: outcome.bounds.physicalDuration)
        }

        // Never cache an analysis performed while the source was being
        // replaced or edited.
        let finalSnapshot = FileValidationSnapshot.load(for: url)
        guard let finalSignature = FileSignature(finalSnapshot), finalSignature == initialSignature else {
            return .fullRange(duration: outcome.bounds.physicalDuration)
        }

        if outcome.isCacheable, outcome.bounds.isValid {
            loadCacheIfNeeded()
            let key = PathKey.canonical(for: url)
            if entries[key] == nil, entries.count >= Self.maximumCacheEntries,
               let evictionKey = entries.keys.sorted().first {
                entries.removeValue(forKey: evictionKey)
            }
            entries[key] = CacheEntry(
                signature: finalSignature,
                bounds: outcome.bounds
            )
            scheduleCacheSave()
        }
        return outcome.bounds
    }

    func remove(for url: URL) {
        loadCacheIfNeeded()
        removeEntry(for: url)
    }

    func removeAll() {
        loadCacheIfNeeded()
        entries.removeAll(keepingCapacity: false)
        // Always write the empty envelope so an explicitly requested clear also
        // replaces an unreadable, outdated, or configuration-mismatched file.
        cacheSaveRevision &+= 1
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        persistCacheNow()
    }

    func flushPersistence() {
        loadCacheIfNeeded()
        cacheSaveRevision &+= 1
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        persistCacheNow()
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
        let rawTrailingEnd: TimeInterval?
        if let adaptiveTrailingEnd {
            rawTrailingEnd = adaptiveTrailingEnd
        } else if let sustainedMeaningfulTailEnd,
                  physicalDuration - sustainedMeaningfulTailEnd
                    >= configuration.minimumTrailingQuietSuffixDuration {
            // Preserve a stable quiet outro that the relative gate rejected.
            rawTrailingEnd = sustainedMeaningfulTailEnd
        } else if let sustainedProtectedTailEnd,
                  physicalDuration - sustainedProtectedTailEnd
                    >= configuration.minimumTrailingQuietSuffixDuration {
            // Ultra-quiet sustained content gets the still more conservative
            // protection floor before any terminal silence is removed.
            rawTrailingEnd = sustainedProtectedTailEnd
        } else if leadingRunStart != nil,
                  baselineTrailingRunEnd == nil,
                  sustainedProtectedTailEnd == nil {
            // When the complete tail scan contains no sustained signal even at
            // the protection floor, use its first sample as a conservative
            // operational boundary. A lone click cannot defeat this fallback.
            rawTrailingEnd = tailMetrics.first?.startTime
        } else {
            rawTrailingEnd = nil
        }

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

        let headMetrics: [WindowMetric]
        let tailMetrics: [WindowMetric]
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
              let resourceValues = try? cacheFileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resourceValues.fileSize,
              fileSize <= Self.maximumCacheBytes,
              let data = try? Data(contentsOf: cacheFileURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.formatVersion == Self.cacheFormatVersion,
              cache.algorithmVersion == Self.algorithmVersion,
              cache.configurationSignature == configuration.cacheSignature else {
            return
        }

        var normalized: [String: CacheEntry] = [:]
        normalized.reserveCapacity(min(cache.entries.count, Self.maximumCacheEntries))
        for (path, entry) in cache.entries where entry.bounds.isValid {
            guard normalized.count < Self.maximumCacheEntries else { break }
            normalized[PathKey.canonical(path: path)] = entry
        }
        entries = normalized
    }

    private func removeEntry(for url: URL) {
        let key = PathKey.canonical(for: url)
        guard entries.removeValue(forKey: key) != nil else { return }
        scheduleCacheSave()
    }

    private func scheduleCacheSave() {
        guard cacheFileURL != nil else { return }
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
        persistCacheNow()
    }

    private func persistCacheNow() {
        guard let cacheFileURL else { return }
        let directory = cacheFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var persistedEntries = entries
            var cache = CacheFile(
                formatVersion: Self.cacheFormatVersion,
                algorithmVersion: Self.algorithmVersion,
                configurationSignature: configuration.cacheSignature,
                entries: persistedEntries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(cache)
            while data.count > Self.maximumCacheBytes, !persistedEntries.isEmpty {
                let estimatedLimit = Int(
                    Double(persistedEntries.count)
                        * Double(Self.maximumCacheBytes)
                        * 0.9
                        / Double(data.count)
                )
                let nextLimit = max(0, min(persistedEntries.count - 1, estimatedLimit))
                let keepKeys = Set(persistedEntries.keys.sorted().suffix(nextLimit))
                persistedEntries = persistedEntries.filter { keepKeys.contains($0.key) }
                cache = CacheFile(
                    formatVersion: Self.cacheFormatVersion,
                    algorithmVersion: Self.algorithmVersion,
                    configurationSignature: configuration.cacheSignature,
                    entries: persistedEntries
                )
                data = try encoder.encode(cache)
            }
            if persistedEntries.count != entries.count {
                entries = persistedEntries
            }
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // Analysis remains usable when Application Support is unavailable.
        }
    }
}
