import AVFoundation
import Foundation

enum LoudnessAlgorithm {
    static let identifier = "itu-bs1770-5-integrated"
    static let version = 2
}

enum EstimatedTruePeakSource: Int, Codable, Equatable, Sendable {
    case oversampled = 1
    case samplePeakFallback = 2
}

struct LoudnessMeasurement: Codable, Equatable, Sendable {
    let integratedLoudnessLUFS: Float?
    let estimatedTruePeakDbTP: Float
    let samplePeakDbFS: Float
    let estimatedTruePeakSource: EstimatedTruePeakSource
    let analyzedFrameCount: Int64
    let sampleRate: Double
    let algorithmIdentifier: String
    let algorithmVersion: Int

    init(
        integratedLoudnessLUFS: Float?,
        estimatedTruePeakDbTP: Float,
        samplePeakDbFS: Float,
        estimatedTruePeakSource: EstimatedTruePeakSource = .oversampled,
        analyzedFrameCount: Int64,
        sampleRate: Double,
        algorithmIdentifier: String = LoudnessAlgorithm.identifier,
        algorithmVersion: Int = LoudnessAlgorithm.version
    ) {
        self.integratedLoudnessLUFS = integratedLoudnessLUFS
        self.estimatedTruePeakDbTP = estimatedTruePeakDbTP
        self.samplePeakDbFS = samplePeakDbFS
        self.estimatedTruePeakSource = estimatedTruePeakSource
        self.analyzedFrameCount = analyzedFrameCount
        self.sampleRate = sampleRate
        self.algorithmIdentifier = algorithmIdentifier
        self.algorithmVersion = algorithmVersion
    }

    var usesCurrentAlgorithm: Bool {
        algorithmIdentifier == LoudnessAlgorithm.identifier
            && algorithmVersion == LoudnessAlgorithm.version
    }
}

enum LoudnessAnalysisError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case unreadableFile
    case emptyFile
    case unsupportedFormat
    case unsupportedChannelLayout(channelCount: Int)
    case invalidSample
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "响度分析已取消"
        case .unreadableFile:
            return "无法读取音频文件"
        case .emptyFile:
            return "音频文件为空"
        case .unsupportedFormat:
            return "音频格式不受响度分析支持"
        case .unsupportedChannelLayout(let channelCount):
            return "不支持 \(channelCount) 声道且布局未知的音频"
        case .invalidSample:
            return "音频包含无效采样值"
        case .decodeFailed:
            return "音频解码失败"
        }
    }
}

enum LoudnessNormalizationPolicy {
    static let defaultTargetLUFS: Float = -16
    static let defaultMaximumGainDb: Float = 6
    static let defaultEstimatedTruePeakCeilingDbTP: Float = -1

    static func outputVolume(
        userVolume: Float,
        measurement: LoudnessMeasurement,
        targetLUFS: Float = defaultTargetLUFS,
        maximumGainDb: Float = defaultMaximumGainDb,
        estimatedTruePeakCeilingDbTP: Float = defaultEstimatedTruePeakCeilingDbTP
    ) -> Float {
        let clampedUserVolume = max(0, min(1, userVolume))
        guard measurement.usesCurrentAlgorithm,
              let measuredLUFS = measurement.integratedLoudnessLUFS,
              measuredLUFS.isFinite,
              measurement.estimatedTruePeakDbTP.isFinite,
              targetLUFS.isFinite,
              maximumGainDb.isFinite,
              estimatedTruePeakCeilingDbTP.isFinite else {
            return clampedUserVolume
        }

        let loudnessScalar = linearGain(decibels: targetLUFS - measuredLUFS)
        let maximumBoostScalar = linearGain(decibels: maximumGainDb)
        let peakSafeOutputScalar = linearGain(
            decibels: estimatedTruePeakCeilingDbTP - measurement.estimatedTruePeakDbTP
        )
        guard loudnessScalar.isFinite,
              maximumBoostScalar.isFinite,
              peakSafeOutputScalar.isFinite else {
            return clampedUserVolume
        }

        return max(
            0,
            min(
                1,
                clampedUserVolume * loudnessScalar,
                clampedUserVolume * maximumBoostScalar,
                peakSafeOutputScalar
            )
        )
    }

    private static func linearGain(decibels: Float) -> Float {
        Float(pow(10, Double(decibels) / 20))
    }
}

/// Streaming ITU-R BS.1770 integrated-loudness analysis with bounded memory.
///
/// The peak value is an estimate produced by AVAudioConverter oversampling. It is
/// deliberately named `estimatedTruePeak` and must not be presented as a fully
/// conformance-tested dBTP meter.
enum LoudnessAnalyzer {
    private static let absoluteGateLUFS = -70.0
    private static let relativeGateOffsetLU = -10.0
    private static let loudnessOffset = -0.691
    private static let maximumStoredBlocks = 200_000
    private static let maximumInitialBlockReservation = 8_192
    private static let maximumTruePeakNoProgressPasses = 4

    static func analyze(
        url: URL,
        chunkFrames: AVAudioFrameCount = 32_768,
        cancellationCheck: (() -> Bool)? = nil
    ) -> Result<LoudnessMeasurement, LoudnessAnalysisError> {
        if isCancelled(cancellationCheck) { return .failure(.cancelled) }

        var audioFile: AVAudioFile?
        var aliasURL: URL?
        do {
            do {
                audioFile = try AVAudioFile(forReading: url)
            } catch {
                if isCancelled(cancellationCheck) { return .failure(.cancelled) }
                aliasURL = AudioAnalysis.makeAudioReadAliasIfNeeded(for: url)
                if let aliasURL {
                    audioFile = try AVAudioFile(forReading: aliasURL)
                } else {
                    return .failure(.unreadableFile)
                }
            }

            guard let audioFile else { return .failure(.unreadableFile) }
            defer {
                if let aliasURL {
                    try? FileManager.default.removeItem(at: aliasURL)
                }
            }
            return analyze(
                audioFile: audioFile,
                chunkFrames: chunkFrames,
                cancellationCheck: cancellationCheck
            )
        } catch {
            return isCancelled(cancellationCheck)
                ? .failure(.cancelled)
                : .failure(.unreadableFile)
        }
    }

    static func analyze(
        audioFile: AVAudioFile,
        chunkFrames: AVAudioFrameCount = 32_768,
        cancellationCheck: (() -> Bool)? = nil
    ) -> Result<LoudnessMeasurement, LoudnessAnalysisError> {
        if isCancelled(cancellationCheck) { return .failure(.cancelled) }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let effectiveChunkFrames = min(chunkFrames, 65_536)
        guard sampleRate.isFinite,
              sampleRate >= 8_000,
              sampleRate <= 384_000,
              channelCount > 0,
              channelCount <= 32,
              effectiveChunkFrames > 0 else {
            return .failure(.unsupportedFormat)
        }
        guard audioFile.length > 0 else { return .failure(.emptyFile) }

        let weights: [Double]
        do {
            weights = try channelWeights(for: format)
        } catch let error as LoudnessAnalysisError {
            return .failure(error)
        } catch {
            return .failure(.unsupportedChannelLayout(channelCount: channelCount))
        }
        guard weights.count == channelCount else {
            return .failure(.unsupportedChannelLayout(channelCount: channelCount))
        }

        audioFile.framePosition = 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: effectiveChunkFrames) else {
            return .failure(.unsupportedFormat)
        }

        let blockFrames = max(1, Int((sampleRate * 0.4).rounded()))
        let hopFrames = max(1, Int((sampleRate * 0.1).rounded()))
        var energyRing = [Double](repeating: 0, count: blockFrames)
        var energyRingIndex = 0
        var energyRingCount = 0
        var energyWindowSum = 0.0
        var totalFilteredEnergy = 0.0
        var blockEnergies: [Double] = []
        let estimatedBlockCount = max(1, Int(audioFile.length) / hopFrames)
        blockEnergies.reserveCapacity(
            min(maximumInitialBlockReservation, maximumStoredBlocks, estimatedBlockCount)
        )

        var filters = (0..<channelCount).map { _ in
            KWeightingFilter(sampleRate: sampleRate)
        }
        var samplePeak = 0.0
        var processedFrames: Int64 = 0
        let totalFrames = audioFile.length

        do {
            while audioFile.framePosition < totalFrames {
                if isCancelled(cancellationCheck) { return .failure(.cancelled) }
                let remaining = totalFrames - audioFile.framePosition
                let framesToRead = AVAudioFrameCount(
                    min(AVAudioFramePosition(effectiveChunkFrames), remaining)
                )
                try audioFile.read(into: buffer, frameCount: framesToRead)
                let frameCount = Int(buffer.frameLength)
                if frameCount == 0 { break }
                guard let channels = buffer.floatChannelData else {
                    return .failure(.unsupportedFormat)
                }

                for frame in 0..<frameCount {
                    var frameEnergy = 0.0
                    for channel in 0..<channelCount {
                        let raw = Double(channels[channel][frame])
                        guard raw.isFinite else { return .failure(.invalidSample) }
                        samplePeak = max(samplePeak, abs(raw))
                        let weighted = filters[channel].process(raw)
                        frameEnergy += weights[channel] * weighted * weighted
                    }

                    totalFilteredEnergy += frameEnergy
                    if energyRingCount == blockFrames {
                        energyWindowSum -= energyRing[energyRingIndex]
                    } else {
                        energyRingCount += 1
                    }
                    energyRing[energyRingIndex] = frameEnergy
                    energyWindowSum += frameEnergy
                    energyRingIndex += 1
                    if energyRingIndex == blockFrames { energyRingIndex = 0 }

                    processedFrames += 1
                    if energyRingCount == blockFrames,
                       (processedFrames - Int64(blockFrames)) % Int64(hopFrames) == 0 {
                        guard blockEnergies.count < maximumStoredBlocks else {
                            return .failure(.unsupportedFormat)
                        }
                        blockEnergies.append(max(0, energyWindowSum / Double(blockFrames)))
                    }
                }
            }
        } catch {
            return isCancelled(cancellationCheck)
                ? .failure(.cancelled)
                : .failure(.decodeFailed)
        }

        guard processedFrames > 0 else { return .failure(.emptyFile) }
        // A sub-400 ms file has no complete BS.1770 gating block. Retain a
        // deterministic whole-file fallback so short samples remain playable.
        if blockEnergies.isEmpty {
            blockEnergies.append(max(0, totalFilteredEnergy / Double(processedFrames)))
        }

        let integrated = integratedLoudness(blockEnergies: blockEnergies)
        let samplePeakDbFS = decibels(amplitude: samplePeak)
        let estimatedPeak: (amplitude: Double, source: EstimatedTruePeakSource)
        do {
            estimatedPeak = try estimateTruePeak(
                audioFile: audioFile,
                chunkFrames: effectiveChunkFrames,
                samplePeak: samplePeak,
                cancellationCheck: cancellationCheck
            )
        } catch let error as LoudnessAnalysisError {
            return .failure(error)
        } catch {
            estimatedPeak = (samplePeak, .samplePeakFallback)
        }
        if isCancelled(cancellationCheck) { return .failure(.cancelled) }

        return .success(
            LoudnessMeasurement(
                integratedLoudnessLUFS: integrated.map(Float.init),
                estimatedTruePeakDbTP: Float(
                    decibels(amplitude: max(samplePeak, estimatedPeak.amplitude))
                ),
                samplePeakDbFS: Float(samplePeakDbFS),
                estimatedTruePeakSource: estimatedPeak.source,
                analyzedFrameCount: processedFrames,
                sampleRate: sampleRate
            )
        )
    }

    private static func integratedLoudness(blockEnergies: [Double]) -> Double? {
        var absoluteEnergySum = 0.0
        var absoluteBlockCount = 0
        for energy in blockEnergies where energy.isFinite && energy > 0 {
            if loudness(energy: energy) > absoluteGateLUFS {
                absoluteEnergySum += energy
                absoluteBlockCount += 1
            }
        }
        guard absoluteBlockCount > 0 else { return nil }

        let absoluteMean = absoluteEnergySum / Double(absoluteBlockCount)
        let relativeThreshold = loudness(energy: absoluteMean) + relativeGateOffsetLU
        var relativeEnergySum = 0.0
        var relativeBlockCount = 0
        for energy in blockEnergies where energy.isFinite && energy > 0 {
            let blockLoudness = loudness(energy: energy)
            if blockLoudness > absoluteGateLUFS, blockLoudness > relativeThreshold {
                relativeEnergySum += energy
                relativeBlockCount += 1
            }
        }
        guard relativeBlockCount > 0 else { return nil }

        let result = loudness(energy: relativeEnergySum / Double(relativeBlockCount))
        return result.isFinite ? result : nil
    }

    private static func loudness(energy: Double) -> Double {
        loudnessOffset + 10 * log10(max(energy, 1e-20))
    }

    private static func decibels(amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-10))
    }

    private static func channelWeights(for format: AVAudioFormat) throws -> [Double] {
        let channelCount = Int(format.channelCount)
        if channelCount == 1 { return [1] }
        if channelCount == 2 { return [1, 1] }

        guard let tag = format.channelLayout?.layoutTag else {
            throw LoudnessAnalysisError.unsupportedChannelLayout(channelCount: channelCount)
        }

        if tag == kAudioChannelLayoutTag_MPEG_3_0_A
            || tag == kAudioChannelLayoutTag_MPEG_3_0_B {
            return [1, 1, 1]
        }
        if tag == kAudioChannelLayoutTag_Quadraphonic {
            return [1, 1, 1.41, 1.41]
        }
        if tag == kAudioChannelLayoutTag_MPEG_5_0_A {
            return [1, 1, 1, 1.41, 1.41]
        }
        if tag == kAudioChannelLayoutTag_MPEG_5_0_B {
            return [1, 1, 1.41, 1.41, 1]
        }
        if tag == kAudioChannelLayoutTag_MPEG_5_0_C
            || tag == kAudioChannelLayoutTag_MPEG_5_0_D {
            return [1, 1, 1, 1.41, 1.41]
        }
        if tag == kAudioChannelLayoutTag_MPEG_5_1_A {
            return [1, 1, 1, 0, 1.41, 1.41]
        }
        if tag == kAudioChannelLayoutTag_MPEG_5_1_B {
            return [1, 1, 1.41, 1.41, 1, 0]
        }
        if tag == kAudioChannelLayoutTag_MPEG_5_1_C
            || tag == kAudioChannelLayoutTag_MPEG_5_1_D {
            return [1, 1, 1, 1.41, 1.41, 0]
        }
        throw LoudnessAnalysisError.unsupportedChannelLayout(channelCount: channelCount)
    }

    private static func estimateTruePeak(
        audioFile: AVAudioFile,
        chunkFrames: AVAudioFrameCount,
        samplePeak: Double,
        cancellationCheck: (() -> Bool)?
    ) throws -> (amplitude: Double, source: EstimatedTruePeakSource) {
        let inputFormat = audioFile.processingFormat
        let inputRate = inputFormat.sampleRate
        let outputRate = min(192_000, inputRate * 4)
        guard outputRate > inputRate * 1.001,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputRate,
                channels: inputFormat.channelCount,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: max(1, min(chunkFrames, 32_768))
              ),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 32_768
              ) else {
            return (samplePeak, .samplePeakFallback)
        }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        audioFile.framePosition = 0
        var reachedEnd = false
        var readFailed = false
        var peak = samplePeak
        var noProgressPasses = 0

        while true {
            if isCancelled(cancellationCheck) {
                throw LoudnessAnalysisError.cancelled
            }
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                requestedFrames, inputStatus in
                if reachedEnd || readFailed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if audioFile.framePosition >= audioFile.length {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let remaining = audioFile.length - audioFile.framePosition
                    let requested = AVAudioFrameCount(
                        max(
                            1,
                            min(
                                AVAudioFramePosition(requestedFrames),
                                AVAudioFramePosition(inputBuffer.frameCapacity),
                                remaining
                            )
                        )
                    )
                    try audioFile.read(into: inputBuffer, frameCount: requested)
                    guard inputBuffer.frameLength > 0 else {
                        reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    readFailed = true
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }

            if readFailed || status == .error || conversionError != nil {
                return (samplePeak, .samplePeakFallback)
            }
            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let channels = outputBuffer.floatChannelData {
                noProgressPasses = 0
                for channel in 0..<Int(outputFormat.channelCount) {
                    for frame in 0..<frames {
                        let sample = Double(channels[channel][frame])
                        guard sample.isFinite else {
                            return (samplePeak, .samplePeakFallback)
                        }
                        peak = max(peak, abs(sample))
                    }
                }
            } else {
                noProgressPasses += 1
                if noProgressPasses >= maximumTruePeakNoProgressPasses {
                    return (samplePeak, .samplePeakFallback)
                }
            }

            if status == .endOfStream { break }
            if reachedEnd, frames == 0, status != .haveData {
                break
            }
        }
        return (peak, .oversampled)
    }

    private static func isCancelled(_ cancellationCheck: (() -> Bool)?) -> Bool {
        cancellationCheck?() == true || Task.isCancelled
    }
}

private struct KWeightingFilter {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        shelf = Biquad.highShelf(sampleRate: sampleRate)
        highPass = Biquad.highPass(sampleRate: sampleRate)
    }

    mutating func process(_ sample: Double) -> Double {
        highPass.process(shelf.process(sample))
    }
}

private struct Biquad {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    static func highShelf(sampleRate: Double) -> Biquad {
        let frequency = 1_681.974_450_955_533
        let gainDb = 3.999_843_853_973_347
        let q = 0.707_175_236_955_419_6
        let k = tan(.pi * frequency / sampleRate)
        let vh = pow(10, gainDb / 20)
        let vb = pow(vh, 0.499_666_774_154_541_6)
        let denominator = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / denominator,
            b1: 2 * (k * k - vh) / denominator,
            b2: (vh - vb * k / q + k * k) / denominator,
            a1: 2 * (k * k - 1) / denominator,
            a2: (1 - k / q + k * k) / denominator
        )
    }

    static func highPass(sampleRate: Double) -> Biquad {
        let frequency = 38.135_470_876_024_44
        let q = 0.500_327_037_323_877_3
        let k = tan(.pi * frequency / sampleRate)
        let denominator = 1 + k / q + k * k
        return Biquad(
            // The BS.1770 48 kHz reference numerator is exactly [1, -2, 1].
            // Keeping the numerator unscaled also preserves that calibration at
            // the reference sample rate while the poles follow the sample rate.
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2 * (k * k - 1) / denominator,
            a2: (1 - k / q + k * k) / denominator
        )
    }
}
