import AVFoundation
import XCTest
@testable import MusicPlayer

final class AudioAnalysisTests: XCTestCase {
    func testAnalyzeKnownAmplitudeSineWave() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("sine.wav")
        try writeSineWAV(to: url, amplitude: 0.5, frequency: 440, duration: 1.0)

        let loudness = AudioAnalysis.analyzeRMSLoudness(for: url)
        let unwrapped = try XCTUnwrap(loudness)

        // Sine wave RMS = amplitude / sqrt(2) ≈ 0.5 / 1.414 ≈ 0.3536
        // dB = 20 * log10(0.3536) ≈ -9.03 dB
        XCTAssertEqual(unwrapped, -9.03, accuracy: 0.5)
    }

    func testAnalyzeMonoAndStereoProduceSimilarResults() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let monoURL = directory.appendingPathComponent("mono.wav")
        let stereoURL = directory.appendingPathComponent("stereo.wav")

        try writeSineWAV(to: monoURL, amplitude: 0.3, frequency: 440, duration: 0.5, channels: 1)
        try writeSineWAV(to: stereoURL, amplitude: 0.3, frequency: 440, duration: 0.5, channels: 2)

        let monoLoudness = try XCTUnwrap(AudioAnalysis.analyzeRMSLoudness(for: monoURL))
        let stereoLoudness = try XCTUnwrap(AudioAnalysis.analyzeRMSLoudness(for: stereoURL))

        XCTAssertEqual(monoLoudness, stereoLoudness, accuracy: 0.1)
    }

    func testAnalyzeCancellationViaClosureStopsEarly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("long.wav")
        try writeSineWAV(to: url, amplitude: 0.2, frequency: 440, duration: 10.0)

        var callCount = 0
        let loudness = AudioAnalysis.analyzeRMSLoudness(for: url) {
            callCount += 1
            return callCount >= 3
        }

        XCTAssertNil(loudness, "Should return nil when cancelled")
        XCTAssertGreaterThanOrEqual(callCount, 3, "Cancellation should have been checked at least 3 times")
    }

    func testAnalyzeEmptyFileReturnsNil() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("empty.wav")
        try writeSineWAV(to: url, amplitude: 0.1, frequency: 440, duration: 0.0)

        let loudness = AudioAnalysis.analyzeRMSLoudness(for: url)
        XCTAssertNil(loudness)
    }

    func testAnalyzeNonAudioFileReturnsNil() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("text.mp3")
        try Data("not audio data".utf8).write(to: url)

        let loudness = AudioAnalysis.analyzeRMSLoudness(for: url)
        XCTAssertNil(loudness)
    }

    func testAnalyzeMissingFileReturnsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/missing.wav")
        let loudness = AudioAnalysis.analyzeRMSLoudness(for: url)
        XCTAssertNil(loudness)
    }

    func testAnalyzeVeryQuietFileProducesLowdB() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("quiet.wav")
        try writeSineWAV(to: url, amplitude: 0.01, frequency: 440, duration: 0.5)

        let loudness = try XCTUnwrap(AudioAnalysis.analyzeRMSLoudness(for: url))
        XCTAssertLessThan(loudness, -30.0, "Very quiet file should produce low dB value")
    }

    func testAnalyzeNearClippingAmplitudeProducesHighdB() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("loud.wav")
        try writeSineWAV(to: url, amplitude: 0.95, frequency: 440, duration: 0.5)

        let loudness = try XCTUnwrap(AudioAnalysis.analyzeRMSLoudness(for: url))
        // 0.95 / sqrt(2) ≈ 0.672, 20*log10(0.672) ≈ -3.45 dB
        XCTAssertGreaterThan(loudness, -5.0, "Near-clipping file should produce high dB value")
        XCTAssertLessThan(loudness, 0.0, "Should still be below 0 dB for sub-unity amplitude")
    }

    func testAnalyzeExtensionMismatchWithWAVContent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Create a valid WAV file with mismatched .mp3 extension
        let wavURL = directory.appendingPathComponent("real.wav")
        try writeSineWAV(to: wavURL, amplitude: 0.3, frequency: 440, duration: 0.3)

        // Rename to .mp3 extension (WAV content with MP3 extension)
        let mismatchURL = directory.appendingPathComponent("mismatch.mp3")
        try FileManager.default.moveItem(at: wavURL, to: mismatchURL)

        // AudioAnalysis should handle extension mismatch via alias
        let loudness = AudioAnalysis.analyzeRMSLoudness(for: mismatchURL)
        XCTAssertNotNil(loudness, "Should handle WAV content with MP3 extension via alias")
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-audio-analysis-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSineWAV(
        to url: URL,
        amplitude: Float,
        frequency: Double,
        duration: TimeInterval,
        channels: Int = 1
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let sampleRate = 44100.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        )

        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())

        guard frameCount > 0 else { return }

        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount

        for channel in 0..<channels {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for index in 0..<Int(frameCount) {
                let time = Double(index) / sampleRate
                samples[index] = Float(sin(2 * Double.pi * frequency * time)) * amplitude
            }
        }

        try file.write(from: buffer)
    }
}
