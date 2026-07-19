import AVFoundation
import XCTest
@testable import MusicPlayer

final class ImmersivePlaybackAnalyzerTests: XCTestCase {
    func testDetectorFindsSustainedAudioWithSafetyPadding() {
        let configuration = detectorConfiguration()
        let head = metrics(
            from: 0,
            through: 2,
            audibleRanges: [1.0 ..< 2.1]
        )
        let tail = metrics(
            from: 8,
            through: 10,
            audibleRanges: [8.0 ..< 8.5]
        )

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleStart, 0.75, accuracy: 0.001)
        XCTAssertEqual(bounds.audibleEnd, 8.75, accuracy: 0.001)
        XCTAssertEqual(bounds.physicalDuration, 10)
    }

    func testDetectorRejectsSilenceIsolatedSpikeAndInvalidMetrics() {
        let configuration = detectorConfiguration()
        let silence = metrics(from: 0, through: 2, audibleRanges: [])
        let silentTail = metrics(from: 8, through: 10, audibleRanges: [])

        XCTAssertEqual(
            ImmersivePlaybackAnalyzer.detectBounds(
                physicalDuration: 10,
                headMetrics: silence,
                tailMetrics: silentTail,
                configuration: configuration
            ),
            .fullRange(duration: 10)
        )

        let oneWindowSpike = metrics(
            from: 0,
            through: 2,
            audibleRanges: [1.0 ..< 1.1]
        )
        XCTAssertEqual(
            ImmersivePlaybackAnalyzer.detectBounds(
                physicalDuration: 10,
                headMetrics: oneWindowSpike,
                tailMetrics: silentTail,
                configuration: configuration
            ),
            .fullRange(duration: 10)
        )

        let invalid = [
            ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: 0,
                duration: 0.1,
                rmsDBFS: .nan,
                peakDBFS: -20
            )
        ]
        XCTAssertEqual(
            ImmersivePlaybackAnalyzer.detectBounds(
                physicalDuration: 10,
                headMetrics: invalid,
                tailMetrics: silentTail,
                configuration: configuration
            ),
            .fullRange(duration: 10)
        )
    }

    func testDetectorRejectsTooShortTracksAndOverTrim() {
        let configuration = detectorConfiguration()
        let shortHead = metrics(from: 0, through: 2, audibleRanges: [0.5 ..< 1.5])
        XCTAssertEqual(
            ImmersivePlaybackAnalyzer.detectBounds(
                physicalDuration: 2,
                headMetrics: shortHead,
                tailMetrics: shortHead,
                configuration: configuration
            ),
            .fullRange(duration: 2)
        )

        let head = metrics(from: 0, through: 5, audibleRanges: [4.0 ..< 5.1])
        let tail = metrics(from: 5, through: 10, audibleRanges: [5.0 ..< 6.0])
        XCTAssertEqual(
            ImmersivePlaybackAnalyzer.detectBounds(
                physicalDuration: 10,
                headMetrics: head,
                tailMetrics: tail,
                configuration: configuration
            ),
            .fullRange(duration: 10)
        )
    }

    func testDetectorPreservesQuietCountInAndIgnoresIsolatedTailReverb() {
        let configuration = detectorConfiguration()
        var head = metrics(
            from: 0,
            through: 3,
            audibleRanges: [2.0 ..< 3.1]
        )
        head[5] = ImmersivePlaybackAnalyzer.WindowMetric(
            startTime: 0.5,
            duration: 0.1,
            rmsDBFS: -65,
            peakDBFS: -55
        )
        for index in 10 ... 14 {
            head[index] = ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: Double(index) * 0.1,
                duration: 0.1,
                rmsDBFS: -65,
                peakDBFS: -55
            )
        }

        var tail = metrics(
            from: 7,
            through: 10,
            audibleRanges: [7.0 ..< 8.1]
        )
        guard let reverbIndex = tail.firstIndex(where: { abs($0.startTime - 8.8) < 0.001 }) else {
            XCTFail("Expected a tail metric at 8.8 seconds")
            return
        }
        tail[reverbIndex] = ImmersivePlaybackAnalyzer.WindowMetric(
            startTime: 8.8,
            duration: 0.1,
            rmsDBFS: -65,
            peakDBFS: -55
        )

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleStart, 0.25, accuracy: 0.001)
        XCTAssertEqual(bounds.audibleEnd, 8.35, accuracy: 0.001)
    }

    func testDetectorUsesTrackRelativeGateForLongQuietFade() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 3, audibleRanges: [0 ..< 3.1])
        var tail = metrics(from: 5, through: 10, audibleRanges: [5 ..< 8.0])
        let fadeLevels: [(rms: Double, peak: Double)] = [
            (-30, -22), (-35, -27), (-40, -32), (-45, -37), (-50, -42),
            (-55, -47), (-60, -52), (-65, -57), (-70, -62), (-75, -67),
        ]
        for (offset, levels) in fadeLevels.enumerated() {
            let index = 30 + offset
            tail[index] = ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: 8 + Double(offset) * 0.1,
                duration: 0.1,
                rmsDBFS: levels.rms,
                peakDBFS: levels.peak
            )
        }

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        // Keep the fade down through the protection floor, then remove the
        // genuinely silent suffix.
        XCTAssertEqual(bounds.audibleEnd, 9.15, accuracy: 0.001)
        XCTAssertGreaterThan(10 - bounds.audibleEnd, 0.75)
    }

    func testDetectorPreservesConstantQuietOutroWhenTailContrastIsLow() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 3, audibleRanges: [0 ..< 3.1])
        let tail = stride(from: 7.0, to: 10.0, by: 0.1).map { start in
            ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: start,
                duration: min(0.1, 10 - start),
                rmsDBFS: -55,
                peakDBFS: -45
            )
        }

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 10, accuracy: 0.001)
    }

    func testDetectorPreservesSustainedQuietOutroAfterLoudSection() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 5, audibleRanges: [0 ..< 5.1])
        var tail = metrics(from: 30, through: 60, audibleRanges: [])
        for index in tail.indices {
            let start = tail[index].startTime
            let levels: (rms: Double, peak: Double)
            if start < 35 {
                levels = (-10, -5)
            } else if start < 58 {
                levels = (-50, -45)
            } else {
                levels = (-120, -100)
            }
            tail[index] = ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: start,
                duration: tail[index].duration,
                rmsDBFS: levels.rms,
                peakDBFS: levels.peak
            )
        }

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 60,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 58.25, accuracy: 0.001)
    }

    func testDetectorTrimsLongSilenceWhenAudioOccupiesLessThanReferencePercentile() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 5, audibleRanges: [0 ..< 5.1])
        let tail = metrics(from: 30, through: 60, audibleRanges: [30 ..< 32])

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 60,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 32.25, accuracy: 0.001)
        XCTAssertGreaterThan(60 - bounds.audibleEnd, 27)
    }

    func testDetectorPreservesSustainedQuietPhraseInsideNoiseFloor() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 5, audibleRanges: [0 ..< 5.1])
        var tail = metrics(from: 30, through: 60, audibleRanges: [30 ..< 35])
        for index in tail.indices where tail[index].startTime >= 35 {
            let start = tail[index].startTime
            let isQuietPhrase = (52 ..< 52.5).contains(start)
            tail[index] = ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: start,
                duration: tail[index].duration,
                rmsDBFS: isQuietPhrase ? -55 : -66,
                peakDBFS: isQuietPhrase ? -45 : -63
            )
        }

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 60,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 52.75, accuracy: 0.001)
    }

    func testDetectorPreservesWeakCodaAboveProtectionFloorBeforeNineSecondsOfSilence() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 5, audibleRanges: [0 ..< 5.1])
        var tail = metrics(from: 30, through: 60, audibleRanges: [30 ..< 45])
        for index in tail.indices where (50 ..< 50.5).contains(tail[index].startTime) {
            tail[index] = ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: tail[index].startTime,
                duration: tail[index].duration,
                rmsDBFS: -66,
                peakDBFS: -58
            )
        }

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 60,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 50.75, accuracy: 0.001)
        XCTAssertGreaterThan(60 - bounds.audibleEnd, 9)
    }

    func testDetectorDoesNotMistakeSteppedQuietOutroForProgressiveFade() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 5, audibleRanges: [0 ..< 5.1])
        var tail = metrics(from: 30, through: 60, audibleRanges: [])
        for index in tail.indices {
            let start = tail[index].startTime
            let levels: (rms: Double, peak: Double)
            if start < 35 {
                levels = (-10, -5)
            } else if start < 50 {
                levels = (-50, -45)
            } else if start < 58 {
                levels = (-60, -55)
            } else {
                levels = (-120, -100)
            }
            tail[index] = ImmersivePlaybackAnalyzer.WindowMetric(
                startTime: start,
                duration: tail[index].duration,
                rmsDBFS: levels.rms,
                peakDBFS: levels.peak
            )
        }

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 60,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 58.25, accuracy: 0.001)
    }

    func testDetectorDoesNotTrimAQuietSuffixShorterThanMinimum() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 3, audibleRanges: [0 ..< 3.1])
        let tail = metrics(from: 7, through: 10, audibleRanges: [7 ..< 9.5])

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 10, accuracy: 0.001)
    }

    func testDetectorPreservesAnIsolatedLoudTransientInsideOtherwiseQuietTail() {
        let configuration = detectorConfiguration()
        let head = metrics(from: 0, through: 5, audibleRanges: [0 ..< 4.5])
        var tail = metrics(from: 30, through: 60, audibleRanges: [])
        guard let clickIndex = tail.firstIndex(where: { abs($0.startTime - 50) < 0.001 }) else {
            XCTFail("Expected a tail metric at 50 seconds")
            return
        }
        tail[clickIndex] = ImmersivePlaybackAnalyzer.WindowMetric(
            startTime: 50,
            duration: 0.1,
            rmsDBFS: -8,
            peakDBFS: -1
        )

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 60,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        XCTAssertEqual(bounds.audibleEnd, 50.35, accuracy: 0.001)
        XCTAssertGreaterThan(bounds.audibleEnd, 50)
    }

    func testAnalyzerFindsBoundsInSyntheticWAVAndReloadsCacheAfterColdStart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("fixture.wav")
        let cacheURL = directory.appendingPathComponent("bounds-cache.json")
        try writeWAV(
            to: audioURL,
            duration: 4,
            audibleRange: 0.8 ..< 3.1
        )

        let bounds: PlaybackBounds
        do {
            let analyzer = ImmersivePlaybackAnalyzer(
                cacheFileURL: cacheURL,
                configuration: integrationConfiguration()
            )
            bounds = await analyzer.bounds(for: audioURL)
            await analyzer.flushPersistence()
        }

        XCTAssertEqual(bounds.physicalDuration, 4, accuracy: 0.01)
        XCTAssertEqual(bounds.audibleStart, 0.7, accuracy: 0.09)
        XCTAssertEqual(bounds.audibleEnd, 3.2, accuracy: 0.09)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        let reloadedAnalyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: cacheURL,
            configuration: integrationConfiguration()
        )
        let cached = await reloadedAnalyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertEqual(cached, bounds)
        let returnedBounds = await reloadedAnalyzer.bounds(for: audioURL)
        XCTAssertEqual(returnedBounds, bounds)
    }

    func testDerivedStorePersistsBoundsIncrementallyAndSeparatesConfigurationVariants() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("derived-source.bin")
        let databaseURL = directory.appendingPathComponent("derived.sqlite3")
        try Data("fixture".utf8).write(to: audioURL)
        let firstConfiguration = ImmersivePlaybackAnalyzer.Configuration(analysisTimeout: 0.5)
        let firstBounds = PlaybackBounds(audibleStart: 0.4, audibleEnd: 3.6, physicalDuration: 4)
        let counter = ImmersiveThreadSafeCounter()

        do {
            let store = try DerivedCacheStore(databaseURL: databaseURL)
            let analyzer = ImmersivePlaybackAnalyzer(
                derivedCacheStore: store,
                legacyCacheFileURL: nil,
                configuration: firstConfiguration,
                analysisOperation: { _, _ in
                    counter.increment()
                    return .init(bounds: firstBounds, isCacheable: true)
                }
            )
            let analyzedBounds = await analyzer.bounds(for: audioURL)
            XCTAssertEqual(analyzedBounds, firstBounds)
            guard case .success = await analyzer.flushPersistence() else {
                return XCTFail("Derived bounds should flush")
            }
            XCTAssertEqual(store.persistedEntryCount(for: .immersive), 1)
        }

        let store = try DerivedCacheStore(databaseURL: databaseURL)
        let reloaded = ImmersivePlaybackAnalyzer(
            derivedCacheStore: store,
            legacyCacheFileURL: nil,
            configuration: firstConfiguration,
            analysisOperation: { _, _ in
                counter.increment()
                return .init(bounds: .fullRange(duration: 9), isCacheable: true)
            }
        )
        let reloadedBounds = await reloaded.cachedBoundsIfValid(for: audioURL)
        XCTAssertEqual(reloadedBounds, firstBounds)
        XCTAssertEqual(counter.value, 1)

        let secondBounds = PlaybackBounds(audibleStart: 0.8, audibleEnd: 3.2, physicalDuration: 4)
        let variantAnalyzer = ImmersivePlaybackAnalyzer(
            derivedCacheStore: store,
            legacyCacheFileURL: nil,
            configuration: .init(leadingSafetyPadding: 0.2, analysisTimeout: 0.5),
            analysisOperation: { _, _ in
                counter.increment()
                return .init(bounds: secondBounds, isCacheable: true)
            }
        )
        let cachedVariantBounds = await variantAnalyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertNil(cachedVariantBounds)
        let analyzedVariantBounds = await variantAnalyzer.bounds(for: audioURL)
        XCTAssertEqual(analyzedVariantBounds, secondBounds)
        _ = await variantAnalyzer.flushPersistence()
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(store.persistedEntryCount(for: .immersive), 2)
    }

    func testDerivedFailurePayloadSurvivesReloadAndFileReplacementClearsCooldown() async throws {
        struct SyntheticFailure: Error {}
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("derived-failure.bin")
        let databaseURL = directory.appendingPathComponent("derived.sqlite3")
        try Data("fixture".utf8).write(to: audioURL)
        let counter = ImmersiveThreadSafeCounter()
        let configuration = ImmersivePlaybackAnalyzer.Configuration(analysisTimeout: 0.5)

        do {
            let store = try DerivedCacheStore(databaseURL: databaseURL)
            let analyzer = ImmersivePlaybackAnalyzer(
                derivedCacheStore: store,
                legacyCacheFileURL: nil,
                configuration: configuration,
                analysisOperation: { _, _ in
                    counter.increment()
                    throw SyntheticFailure()
                }
            )
            _ = await analyzer.bounds(for: audioURL)
            _ = await analyzer.flushPersistence()
        }

        let store = try DerivedCacheStore(databaseURL: databaseURL)
        let analyzer = ImmersivePlaybackAnalyzer(
            derivedCacheStore: store,
            legacyCacheFileURL: nil,
            configuration: configuration,
            analysisOperation: { _, _ in
                counter.increment()
                throw SyntheticFailure()
            }
        )
        _ = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(counter.value, 1, "Persisted failure payload should suppress a retry")

        try Data("replacement-with-new-identity".utf8).write(to: audioURL, options: .atomic)
        _ = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(counter.value, 2, "A replacement identity must invalidate the failure row")
    }

    func testDerivedClearRejectsLateDecodeFromOlderGeneration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("late-after-clear.bin")
        try Data("fixture".utf8).write(to: audioURL)
        let store = try DerivedCacheStore(
            databaseURL: directory.appendingPathComponent("derived.sqlite3")
        )
        let expected = PlaybackBounds(audibleStart: 0.5, audibleEnd: 3.5, physicalDuration: 4)
        let analyzer = ImmersivePlaybackAnalyzer(
            derivedCacheStore: store,
            legacyCacheFileURL: nil,
            configuration: .init(analysisTimeout: 0.02),
            analysisOperation: { _, _ in
                Thread.sleep(forTimeInterval: 0.12)
                return .init(bounds: expected, isCacheable: true)
            }
        )

        let timedOutBounds = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(timedOutBounds, .fullRange(duration: 0))
        guard case .success = await analyzer.removeAll() else {
            return XCTFail("Derived cache clear should succeed")
        }
        try await Task.sleep(nanoseconds: 220_000_000)
        let cachedBounds = await analyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertNil(cachedBounds)
        _ = await analyzer.flushPersistence()
        XCTAssertEqual(store.persistedEntryCount(for: .immersive), 0)
    }

    func testLegacyApplicationSupportJSONMigratesOnceWithDurableMarker() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("legacy-source.bin")
        let legacyURL = directory.appendingPathComponent("immersive-boundaries.json")
        try Data("fixture".utf8).write(to: audioURL)
        let snapshot = FileValidationSnapshot.load(for: audioURL)
        let configuration = ImmersivePlaybackAnalyzer.Configuration(analysisTimeout: 0.5)
        let migratedBounds = PlaybackBounds(audibleStart: 0.4, audibleEnd: 3.6, physicalDuration: 4)
        let legacyBytes = try makeLegacyCacheBytes(
            path: audioURL.path,
            snapshot: snapshot,
            bounds: migratedBounds,
            configuration: configuration
        )
        try legacyBytes.write(to: legacyURL)
        let store = try DerivedCacheStore(
            databaseURL: directory.appendingPathComponent("derived.sqlite3")
        )
        let counter = ImmersiveThreadSafeCounter()
        let analyzer = ImmersivePlaybackAnalyzer(
            derivedCacheStore: store,
            legacyCacheFileURL: legacyURL,
            configuration: configuration,
            analysisOperation: { _, _ in
                counter.increment()
                return .init(bounds: .fullRange(duration: 8), isCacheable: true)
            }
        )

        let migratedCachedBounds = await analyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertEqual(migratedCachedBounds, migratedBounds)
        XCTAssertEqual(counter.value, 0)
        XCTAssertNotNil(
            store.migrationMarker(for: ImmersivePlaybackAnalyzer.legacyMigrationMarkerKey)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        let replacementBounds = PlaybackBounds(audibleStart: 1, audibleEnd: 3, physicalDuration: 4)
        try makeLegacyCacheBytes(
            path: audioURL.path,
            snapshot: snapshot,
            bounds: replacementBounds,
            configuration: configuration
        ).write(to: legacyURL)
        let secondAnalyzer = ImmersivePlaybackAnalyzer(
            derivedCacheStore: store,
            legacyCacheFileURL: legacyURL,
            configuration: configuration,
            analysisOperation: { _, _ in
                counter.increment()
                return .init(bounds: replacementBounds, isCacheable: true)
            }
        )
        let secondCachedBounds = await secondAnalyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertEqual(secondCachedBounds, migratedBounds)
        XCTAssertEqual(counter.value, 0, "A durable marker must prevent a second JSON import")
    }

    func testAggressiveLeadingPaddingWithGeneratedAudio() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("long-silence-before-onset.wav")

        // 2 seconds silence, then 4 seconds audio (total 6s)
        try writeWAV(
            to: audioURL,
            duration: 6,
            audibleRange: 2.0 ..< 6.0
        )

        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: ImmersivePlaybackAnalyzer.Configuration()
        )
        let bounds = await analyzer.bounds(for: audioURL)

        // Should trim to ~0.10s before 2.0s onset = ~1.90s
        XCTAssertEqual(bounds.audibleStart, 1.90, accuracy: 0.15)
        // Trailing should extend to physical end
        XCTAssertEqual(bounds.audibleEnd, 6.0, accuracy: 0.15)
        XCTAssertEqual(bounds.physicalDuration, 6.0, accuracy: 0.01)
    }

    func testAnalyzerKeepsAudioPresentInOnlyOneStereoChannel() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("single-channel-signal.wav")
        try writeWAV(
            to: audioURL,
            duration: 4,
            audibleRange: 0.8 ..< 3.1,
            channelCount: 2,
            audibleChannel: 1
        )

        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: integrationConfiguration()
        )
        let bounds = await analyzer.bounds(for: audioURL)

        XCTAssertEqual(bounds.audibleStart, 0.7, accuracy: 0.09)
        XCTAssertEqual(bounds.audibleEnd, 3.2, accuracy: 0.09)
    }

    func testAnalyzerRejectsSustainedLowLevelTailNoise() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("low-level-tail.wav")
        try writeWAV(
            to: audioURL,
            duration: 36,
            audibleRange: 0 ..< 27,
            lowLevelTailRange: 27 ..< 36
        )

        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: ImmersivePlaybackAnalyzer.Configuration(
                minimumTrackDuration: 1,
                minimumAudibleDuration: 0.5,
                maximumTrimFraction: 0.8
            )
        )
        let bounds = await analyzer.bounds(for: audioURL)

        XCTAssertEqual(bounds.physicalDuration, 36, accuracy: 0.02)
        XCTAssertEqual(bounds.audibleStart, 0, accuracy: 0.02)
        XCTAssertEqual(bounds.audibleEnd, 27.35, accuracy: 0.12)
        XCTAssertGreaterThan(36 - bounds.audibleEnd, 8.5)
    }

    func testCorruptCacheIsIgnoredAndFileReplacementInvalidatesEntry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("fixture.wav")
        let cacheURL = directory.appendingPathComponent("bounds-cache.json")
        try Data("not-json".utf8).write(to: cacheURL)
        try writeWAV(
            to: audioURL,
            duration: 4,
            audibleRange: 0.8 ..< 3.1
        )

        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: cacheURL,
            configuration: integrationConfiguration()
        )
        let original = await analyzer.bounds(for: audioURL)
        XCTAssertGreaterThan(original.audibleStart, 0)

        try writeWAV(
            to: audioURL,
            duration: 5,
            audibleRange: 0.4 ..< 4.5
        )
        let staleCachedBounds = await analyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertNil(staleCachedBounds)

        let replacement = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(replacement.physicalDuration, 5, accuracy: 0.01)
        XCTAssertLessThan(replacement.audibleStart, original.audibleStart)
        XCTAssertGreaterThan(replacement.audibleEnd, original.audibleEnd)
    }

    func testAggressiveLeadingEntryWithLongSilence() {
        // Long leading silence should trim to ~0.10s before onset (new default padding)
        let configuration = ImmersivePlaybackAnalyzer.Configuration()
        let head = metrics(
            from: 0,
            through: 5,
            audibleRanges: [3.0 ..< 5.1]
        )
        let tail = metrics(
            from: 8,
            through: 10,
            audibleRanges: [8.0 ..< 10.1]
        )

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        // 3.0s onset - 0.10s padding = 2.90s start
        XCTAssertEqual(bounds.audibleStart, 2.90, accuracy: 0.01)
        // Tail extends to physical end
        XCTAssertEqual(bounds.audibleEnd, 10.0, accuracy: 0.01)
    }

    func testSlowDecodeFallsBackAtDeadlineWithoutBlockingCacheActor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("slow-source.bin")
        try Data("fixture".utf8).write(to: audioURL)

        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: .init(analysisTimeout: 0.05),
            analysisOperation: { _, _ in
                Thread.sleep(forTimeInterval: 0.5)
                return .init(bounds: .fullRange(duration: 4), isCacheable: true)
            }
        )

        let start = ContinuousClock.now
        let bounds = await analyzer.bounds(for: audioURL)
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(250))
        XCTAssertEqual(bounds, .fullRange(duration: 0))

        let flushStart = ContinuousClock.now
        let flushResult = await analyzer.flushPersistence()
        XCTAssertLessThan(flushStart.duration(to: .now), .milliseconds(100))
        guard case .success = flushResult else {
            return XCTFail("Cache flush should not wait for the decode worker")
        }
    }

    func testLateSuccessfulDecodePopulatesCacheAfterPlaybackDeadline() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("late-success.bin")
        try Data("fixture".utf8).write(to: audioURL)
        let expected = PlaybackBounds(
            audibleStart: 0.5,
            audibleEnd: 3.5,
            physicalDuration: 4
        )
        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: .init(analysisTimeout: 0.02),
            analysisOperation: { _, _ in
                Thread.sleep(forTimeInterval: 0.10)
                return .init(bounds: expected, isCacheable: true)
            }
        )

        let immediate = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(immediate, .fullRange(duration: 0))
        let deadline = Date().addingTimeInterval(1)
        var cached: PlaybackBounds?
        repeat {
            try await Task.sleep(nanoseconds: 20_000_000)
            cached = await analyzer.cachedBoundsIfValid(for: audioURL)
        } while cached == nil && Date() < deadline
        XCTAssertEqual(cached, expected)
    }

    func testReadFailureUsesSignatureBoundNegativeCache() async throws {
        struct SyntheticFailure: Error {}
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("unsupported.bin")
        try Data("fixture".utf8).write(to: audioURL)
        let counter = ImmersiveThreadSafeCounter()

        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: .init(analysisTimeout: 0.5),
            analysisOperation: { _, _ in
                counter.increment()
                throw SyntheticFailure()
            }
        )

        _ = await analyzer.bounds(for: audioURL)
        _ = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(counter.value, 1)

        try Data("replacement".utf8).write(to: audioURL, options: .atomic)
        _ = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(counter.value, 2, "A new file signature must clear the failure cooldown")
    }

    func testFutureCacheIsQuarantinedByteForByteBeforeCurrentCacheIsCreated() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("immersive-boundaries.json")
        let futureBytes = Data(
            "{\"formatVersion\":99,\"algorithmVersion\":99,\"future\":\"preserve\"}".utf8
        )
        try futureBytes.write(to: cacheURL)

        let analyzer = ImmersivePlaybackAnalyzer(cacheFileURL: cacheURL)
        let clearResult = await analyzer.removeAll()
        guard case .success = clearResult else {
            return XCTFail("A future derived cache should be preserved then replaced with a clean active cache")
        }

        let quarantineDirectory = directory.appendingPathComponent("CacheQuarantine", isDirectory: true)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        let preserved = try XCTUnwrap(quarantined.first)
        XCTAssertEqual(try Data(contentsOf: preserved), futureBytes)

        let activeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        XCTAssertEqual(activeObject["formatVersion"] as? Int, 2)
    }

    func testFailedClearRestoresInMemoryEntries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("source.bin")
        try Data("fixture".utf8).write(to: audioURL)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedParent)
        let cacheURL = blockedParent.appendingPathComponent("cache.json")

        let expected = PlaybackBounds(audibleStart: 0.5, audibleEnd: 3.5, physicalDuration: 4)
        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: cacheURL,
            configuration: .init(analysisTimeout: 0.5),
            analysisOperation: { _, _ in
                .init(bounds: expected, isCacheable: true)
            }
        )
        let analyzed = await analyzer.bounds(for: audioURL)
        XCTAssertEqual(analyzed, expected)

        let clearResult = await analyzer.removeAll()
        guard case .failure = clearResult else {
            return XCTFail("Clear should report the storage failure")
        }
        let cachedAfterFailedClear = await analyzer.cachedBoundsIfValid(for: audioURL)
        XCTAssertEqual(cachedAfterFailedClear, expected)
    }

    func testIsolatedWeakAnacrusisPreserved() {
        // Single weak pickup note before main onset must not be trimmed
        let configuration = ImmersivePlaybackAnalyzer.Configuration()
        var head = metrics(
            from: 0,
            through: 5,
            audibleRanges: [2.0 ..< 5.1]
        )
        // Replace window at exactly 1.8s with protected-level anacrusis (RMS -70 dBFS)
        guard let index = head.firstIndex(where: { abs($0.startTime - 1.8) < 0.001 }) else {
            XCTFail("Test setup failed: no metric window at 1.8s")
            return
        }
        head[index] = ImmersivePlaybackAnalyzer.WindowMetric(
            startTime: head[index].startTime,
            duration: head[index].duration,
            rmsDBFS: -70,
            peakDBFS: -60
        )

        let tail = metrics(from: 8, through: 10, audibleRanges: [8.0 ..< 10.1])

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        // Must include the 1.8s anacrusis - 0.10s padding = 1.70s
        XCTAssertEqual(bounds.audibleStart, 1.70, accuracy: 0.001)
    }

    func testSustainedFadeInPreserved() {
        // Gradual fade-in spanning 1.0-2.0s must not be trimmed
        let configuration = ImmersivePlaybackAnalyzer.Configuration()
        let silence = metrics(from: 0, through: 1.0, audibleRanges: [])

        // Protected-level content 1.0-2.0s
        var fadeIn: [ImmersivePlaybackAnalyzer.WindowMetric] = []
        var time = 1.0
        while time < 2.0 {
            fadeIn.append(
                ImmersivePlaybackAnalyzer.WindowMetric(
                    startTime: time,
                    duration: 0.05,
                    rmsDBFS: -70,
                    peakDBFS: -60
                )
            )
            time += 0.05
        }

        // Main content from 2.0s
        let main = metrics(from: 2.0, through: 5, audibleRanges: [2.0 ..< 5.1])
        let head = silence + fadeIn + main
        let tail = metrics(from: 8, through: 10, audibleRanges: [8.0 ..< 9.0])

        let bounds = ImmersivePlaybackAnalyzer.detectBounds(
            physicalDuration: 10,
            headMetrics: head,
            tailMetrics: tail,
            configuration: configuration
        )

        // Must include the 1.0s fade-in start - 0.10s padding = ~0.90s
        XCTAssertEqual(bounds.audibleStart, 0.90, accuracy: 0.01)
    }

    private func detectorConfiguration() -> ImmersivePlaybackAnalyzer.Configuration {
        ImmersivePlaybackAnalyzer.Configuration(
            analysisEdgeDuration: 5,
            analysisWindowDuration: 0.1,
            rmsThresholdDBFS: -55,
            peakThresholdDBFS: -42,
            minimumConsecutiveAudibleWindows: 2,
            minimumSustainedAudibleDuration: 0.15,
            leadingSafetyPadding: 0.25,
            trailingSafetyPadding: 0.25,
            minimumTrackDuration: 3,
            minimumAudibleDuration: 2,
            maximumTrimFraction: 0.5,
            minimumUsefulTrim: 0.05
        )
    }

    private func integrationConfiguration() -> ImmersivePlaybackAnalyzer.Configuration {
        ImmersivePlaybackAnalyzer.Configuration(
            analysisEdgeDuration: 5,
            analysisWindowDuration: 0.05,
            rmsThresholdDBFS: -55,
            peakThresholdDBFS: -42,
            minimumConsecutiveAudibleWindows: 2,
            minimumSustainedAudibleDuration: 0.1,
            leadingSafetyPadding: 0.1,
            trailingSafetyPadding: 0.1,
            minimumTrackDuration: 1,
            minimumAudibleDuration: 0.5,
            maximumTrimFraction: 0.8,
            minimumUsefulTrim: 0.05
        )
    }

    private func metrics(
        from start: TimeInterval,
        through end: TimeInterval,
        audibleRanges: [Range<TimeInterval>]
    ) -> [ImmersivePlaybackAnalyzer.WindowMetric] {
        let window = 0.1
        var result: [ImmersivePlaybackAnalyzer.WindowMetric] = []
        var cursor = start
        while cursor < end - 0.000_1 {
            let isAudible = audibleRanges.contains { $0.contains(cursor + window / 2) }
            result.append(
                ImmersivePlaybackAnalyzer.WindowMetric(
                    startTime: cursor,
                    duration: min(window, end - cursor),
                    rmsDBFS: isAudible ? -20 : -120,
                    peakDBFS: isAudible ? -12 : -100
                )
            )
            cursor += window
        }
        return result
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-immersive-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLegacyCacheBytes(
        path: String,
        snapshot: FileValidationSnapshot,
        bounds: PlaybackBounds,
        configuration: ImmersivePlaybackAnalyzer.Configuration
    ) throws -> Data {
        let signature: [String: Any] = [
            "fileSize": snapshot.fileSize,
            "mtimeNs": snapshot.mtimeNs,
            "inode": snapshot.inode.map { NSNumber(value: $0) } ?? NSNull(),
        ]
        let encodedBounds: [String: Any] = [
            "audibleStart": bounds.audibleStart,
            "audibleEnd": bounds.audibleEnd,
            "physicalDuration": bounds.physicalDuration,
        ]
        let entry: [String: Any] = [
            "signature": signature,
            "bounds": encodedBounds,
            "lastAccessedAt": Date().timeIntervalSince1970,
        ]
        return try JSONSerialization.data(withJSONObject: [
            "formatVersion": 2,
            "algorithmVersion": ImmersivePlaybackAnalyzer.algorithmVersion,
            "configurationSignature": configuration.cacheSignature,
            "entries": [path: entry],
            "failures": [:],
        ])
    }

    private func writeWAV(
        to url: URL,
        duration: TimeInterval,
        audibleRange: Range<TimeInterval>,
        channelCount: AVAudioChannelCount = 1,
        audibleChannel: Int = 0,
        lowLevelTailRange: Range<TimeInterval>? = nil
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
        )
        var fileSettings = format.settings
        fileSettings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings
        )
        let frameCapacity: AVAudioFrameCount = 4_096
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        )
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertTrue((0 ..< Int(channelCount)).contains(audibleChannel))
        let totalFrames = Int((duration * sampleRate).rounded())
        var writtenFrames = 0

        while writtenFrames < totalFrames {
            let count = min(Int(frameCapacity), totalFrames - writtenFrames)
            buffer.frameLength = AVAudioFrameCount(count)
            for channelIndex in 0 ..< Int(channelCount) {
                for index in 0 ..< count {
                    let absoluteFrame = writtenFrames + index
                    let time = Double(absoluteFrame) / sampleRate
                    let sample: Float
                    if audibleRange.contains(time) {
                        sample = Float(sin(2 * Double.pi * 440 * time) * 0.25)
                    } else if lowLevelTailRange?.contains(time) == true {
                        // Roughly -66 dBFS RMS: above the old -70 dBFS
                        // protection floor, but far below this track's active tail.
                        sample = Float(sin(2 * Double.pi * 997 * time) * 0.000_71)
                    } else {
                        sample = 0
                    }
                    channels[channelIndex][index] = channelIndex == audibleChannel ? sample : 0
                }
            }
            try file.write(from: buffer)
            writtenFrames += count
        }
    }
}

private final class ImmersiveThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
