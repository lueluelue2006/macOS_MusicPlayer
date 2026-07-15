import AVFoundation
import Foundation

/// Audio analysis utilities for RMS loudness measurement.
///
/// Design:
/// - Pure analysis functions with minimal dependencies
/// - Cancellation support via closure and Task.isCancelled
/// - Automatic extension/container mismatch handling via temporary aliases
enum AudioAnalysis {
    /// Analyze RMS loudness of an audio file in dB.
    ///
    /// - Parameters:
    ///   - url: File URL to analyze
    ///   - cancellationCheck: Optional closure to check for cancellation
    /// - Returns: RMS loudness in dB, or nil on failure/cancellation
    static func analyzeRMSLoudness(
        for url: URL,
        cancellationCheck: (() -> Bool)? = nil
    ) -> Float? {
        if cancellationCheck?() == true { return nil }
        if Task.isCancelled { return nil }

        do {
            var audioFile: AVAudioFile?
            var aliasURL: URL?

            do {
                audioFile = try AVAudioFile(forReading: url)
            } catch {
                if cancellationCheck?() == true { return nil }
                if Task.isCancelled { return nil }

                // Some files have extensions that don't match the actual container (e.g. `.mp3` name
                // but actually an `.m4a`). AVAudioFile relies on the extension in some cases, so we
                // create a temporary alias with a best-effort extension inferred from magic bytes.
                aliasURL = makeAudioReadAliasIfNeeded(for: url)
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

            return analyzeRMSLoudness(audioFile: audioFile, cancellationCheck: cancellationCheck)
        } catch {
            return nil
        }
    }

    /// Analyze RMS loudness from an open AVAudioFile.
    ///
    /// - Parameters:
    ///   - audioFile: Opened audio file
    ///   - cancellationCheck: Optional closure to check for cancellation
    /// - Returns: RMS loudness in dB, or nil on failure/cancellation
    static func analyzeRMSLoudness(
        audioFile: AVAudioFile,
        cancellationCheck: (() -> Bool)? = nil
    ) -> Float? {
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

        do {
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

                guard let channels = buffer.floatChannelData else { return nil }
                for c in 0..<channelCount {
                    let ptr = channels[c]
                    var i = 0
                    while i < effectiveFrames {
                        let sample = ptr[i]
                        guard sample.isFinite else { return nil }
                        sumSquares += Double(sample * sample)
                        i += 1
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

            guard totalSamples > 0, sumSquares.isFinite, sumSquares >= 0 else { return nil }
            let rms = sqrt(sumSquares / Double(totalSamples))
            let dbValue = 20.0 * log10(max(rms, 1e-10))
            guard dbValue.isFinite else { return nil }
            return Float(dbValue)
        } catch {
            return nil
        }
    }

    /// Create a temporary symlink with a corrected extension if `AVAudioFile(forReading:)` may fail due to
    /// extension/container mismatch. Returns `nil` if no hint is available or alias creation fails.
    private static func makeAudioReadAliasIfNeeded(for url: URL) -> URL? {
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
            return nil
        }
    }
}
