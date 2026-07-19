import AVFoundation
import XCTest
@testable import MusicPlayer

final class LoudnessAnalyzerTests: XCTestCase {
    func testStereo997HzReferenceToneProducesExpectedIntegratedLoudness() throws {
        let amplitude = Float(pow(10, -23.0 / 20.0))
        let fixture = try makeFixture(
            name: "reference-tone",
            sampleRate: 48_000,
            duration: 3,
            channels: 2
        ) { time, _ in
            Float(sin(2 * Double.pi * 997 * time)) * amplitude
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let measurement = try LoudnessAnalyzer.analyze(url: fixture.url).get()
        let loudness = try XCTUnwrap(measurement.integratedLoudnessLUFS)

        XCTAssertEqual(loudness, -23, accuracy: 0.15)
        XCTAssertEqual(measurement.algorithmIdentifier, LoudnessAlgorithm.identifier)
        XCTAssertEqual(measurement.algorithmVersion, 2)
        XCTAssertGreaterThan(measurement.analyzedFrameCount, 0)
        XCTAssertEqual(measurement.sampleRate, 48_000, accuracy: 0.1)
    }

    func testDuplicatedStereoToneIsThreeLUAboveMono() throws {
        let mono = try makeFixture(name: "mono", duration: 2, channels: 1) { time, _ in
            Float(sin(2 * Double.pi * 997 * time) * 0.25)
        }
        let stereo = try makeFixture(name: "stereo", duration: 2, channels: 2) { time, _ in
            Float(sin(2 * Double.pi * 997 * time) * 0.25)
        }
        defer {
            try? FileManager.default.removeItem(at: mono.directory)
            try? FileManager.default.removeItem(at: stereo.directory)
        }

        let monoLUFS = try XCTUnwrap(
            try LoudnessAnalyzer.analyze(url: mono.url).get().integratedLoudnessLUFS
        )
        let stereoLUFS = try XCTUnwrap(
            try LoudnessAnalyzer.analyze(url: stereo.url).get().integratedLoudnessLUFS
        )
        XCTAssertEqual(stereoLUFS - monoLUFS, 3.0103, accuracy: 0.08)
    }

    func testAnalysisIsInvariantAcrossDecodeChunkSizes() throws {
        let fixture = try makeFixture(name: "chunked", duration: 3.2, channels: 2) { time, channel in
            let frequency = channel == 0 ? 997.0 : 1_503.0
            return Float(sin(2 * Double.pi * frequency * time) * 0.32)
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let small = try LoudnessAnalyzer.analyze(url: fixture.url, chunkFrames: 1_024).get()
        let large = try LoudnessAnalyzer.analyze(url: fixture.url, chunkFrames: 32_768).get()

        XCTAssertEqual(
            try XCTUnwrap(small.integratedLoudnessLUFS),
            try XCTUnwrap(large.integratedLoudnessLUFS),
            accuracy: 0.01
        )
        XCTAssertEqual(small.estimatedTruePeakDbTP, large.estimatedTruePeakDbTP, accuracy: 0.03)
        XCTAssertEqual(small.samplePeakDbFS, large.samplePeakDbFS, accuracy: 0.001)
    }

    func testRelativeGateRejectsLongSilence() throws {
        let tone = try makeFixture(name: "tone-only", duration: 2, channels: 1) { time, _ in
            Float(sin(2 * Double.pi * 997 * time) * 0.2)
        }
        let toneThenSilence = try makeFixture(
            name: "tone-silence",
            duration: 4,
            channels: 1
        ) { time, _ in
            time < 2 ? Float(sin(2 * Double.pi * 997 * time) * 0.2) : 0
        }
        defer {
            try? FileManager.default.removeItem(at: tone.directory)
            try? FileManager.default.removeItem(at: toneThenSilence.directory)
        }

        let toneLUFS = try XCTUnwrap(
            try LoudnessAnalyzer.analyze(url: tone.url).get().integratedLoudnessLUFS
        )
        let gatedLUFS = try XCTUnwrap(
            try LoudnessAnalyzer.analyze(url: toneThenSilence.url).get().integratedLoudnessLUFS
        )
        XCTAssertEqual(gatedLUFS, toneLUFS, accuracy: 0.7)
    }

    func testEstimatedTruePeakNeverFallsBelowSamplePeak() throws {
        let fixture = try makeFixture(name: "intersample", duration: 1, channels: 1) { time, _ in
            Float(sin(2 * Double.pi * 18_000 * time + .pi / 4) * 0.82)
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let measurement = try LoudnessAnalyzer.analyze(url: fixture.url).get()
        XCTAssertGreaterThanOrEqual(
            measurement.estimatedTruePeakDbTP + 0.01,
            measurement.samplePeakDbFS
        )
    }

    func testSilenceIsAValidMeasurementWithoutInventingLoudness() throws {
        let fixture = try makeFixture(name: "silence", duration: 1, channels: 1) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let measurement = try LoudnessAnalyzer.analyze(url: fixture.url).get()
        XCTAssertNil(measurement.integratedLoudnessLUFS)
        XCTAssertEqual(measurement.estimatedTruePeakDbTP, -200, accuracy: 0.01)
        XCTAssertEqual(measurement.samplePeakDbFS, -200, accuracy: 0.01)
        XCTAssertEqual(
            LoudnessNormalizationPolicy.outputVolume(userVolume: 0.4, measurement: measurement),
            0.4,
            accuracy: 0.0001
        )
    }

    func testCancellationStopsStreamingAnalysis() throws {
        let fixture = try makeFixture(name: "cancel", duration: 4, channels: 1) { time, _ in
            Float(sin(2 * Double.pi * 440 * time) * 0.2)
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var checks = 0
        let result = LoudnessAnalyzer.analyze(url: fixture.url, chunkFrames: 1_024) {
            checks += 1
            return checks >= 4
        }
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertGreaterThanOrEqual(checks, 4)
    }

    func testOutputVolumeAppliesPeakLimitToFinalMasterVolume() {
        let measurement = LoudnessMeasurement(
            integratedLoudnessLUFS: -24,
            estimatedTruePeakDbTP: -0.5,
            samplePeakDbFS: -1,
            analyzedFrameCount: 1,
            sampleRate: 48_000
        )

        let fullMaster = LoudnessNormalizationPolicy.outputVolume(
            userVolume: 1,
            measurement: measurement
        )
        XCTAssertEqual(fullMaster, Float(pow(10, -0.5 / 20.0)), accuracy: 0.0001)

        let halfMaster = LoudnessNormalizationPolicy.outputVolume(
            userVolume: 0.5,
            measurement: measurement
        )
        XCTAssertEqual(halfMaster, Float(pow(10, -0.5 / 20.0)), accuracy: 0.0001)

        let lowMaster = LoudnessNormalizationPolicy.outputVolume(
            userVolume: 0.1,
            measurement: measurement
        )
        XCTAssertEqual(lowMaster, Float(pow(10, 6.0 / 20.0)) * 0.1, accuracy: 0.0001)
    }

    private func makeFixture(
        name: String,
        sampleRate: Double = 44_100,
        duration: TimeInterval,
        channels: Int,
        sample: (_ time: Double, _ channel: Int) -> Float
    ) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-loudness-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channels)
            )
        )
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let totalFrames = Int((duration * sampleRate).rounded())
        let chunkFrames = 4_096
        var written = 0
        while written < totalFrames {
            let count = min(chunkFrames, totalFrames - written)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(count)
                )
            )
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for frame in 0..<count {
                    samples[frame] = sample(Double(written + frame) / sampleRate, channel)
                }
            }
            try file.write(from: buffer)
            written += count
        }
        return (directory, url)
    }
}
