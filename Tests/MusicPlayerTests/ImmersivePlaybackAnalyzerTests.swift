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

        XCTAssertEqual(bounds.audibleEnd, 8.95, accuracy: 0.001)
        XCTAssertGreaterThan(10 - bounds.audibleEnd, 1)
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

    func testDetectorTrimsACompletelyQuietLongTailDespiteAnIsolatedClick() {
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

        XCTAssertEqual(bounds.audibleEnd, 30.25, accuracy: 0.001)
        XCTAssertLessThan(bounds.audibleEnd, 31)
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
