import Foundation
import AVFoundation
import XCTest
@testable import MusicPlayer

/// Test helper for creating valid audio files
enum TestAudioFixture {
    /// Creates a valid sine wave WAV file for testing
    static func createSineWAV(
        at url: URL,
        amplitude: Float = 0.5,
        frequency: Double = 440,
        duration: TimeInterval = 0.1,
        channels: Int = 1
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let sampleRate = 44100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            throw NSError(domain: "TestAudioFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }

        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())

        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "TestAudioFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM buffer"])
        }
        buffer.frameLength = frameCount

        for channel in 0..<channels {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for index in 0..<Int(frameCount) {
                let time = Double(index) / sampleRate
                samples[index] = Float(sin(2 * Double.pi * frequency * time)) * amplitude
            }
        }

        try file.write(from: buffer)
    }
}

/// Test spy for tracking signature capture operations
actor TestSignatureCaptureCounter: SignatureCaptureCounter {
    private(set) var capturedPaths: [String] = []
    private var isPaused = false
    private var pausedContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordCapture(path: String) async {
        capturedPaths.append(path)

        // Resume waiters that reached their threshold
        var remainingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (threshold, continuation) in countWaiters {
            if capturedPaths.count >= threshold {
                continuation.resume()
            } else {
                remainingWaiters.append((threshold, continuation))
            }
        }
        countWaiters = remainingWaiters

        // Pause if requested
        if isPaused {
            await withCheckedContinuation { continuation in
                pausedContinuations.append(continuation)
            }
        }
    }

    func captureCount() -> Int {
        capturedPaths.count
    }

    func uniqueCaptureCount() -> Int {
        Set(capturedPaths).count
    }

    func reset() {
        capturedPaths.removeAll()
        resumeAll()
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        let pending = pausedContinuations
        pausedContinuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitForCaptureCount(_ threshold: Int) async {
        guard capturedPaths.count < threshold else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((threshold, continuation))
        }
    }

    private func resumeAll() {
        isPaused = false
        let paused = pausedContinuations
        let waiters = countWaiters
        pausedContinuations.removeAll()
        countWaiters.removeAll()
        for continuation in paused {
            continuation.resume()
        }
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }
}
