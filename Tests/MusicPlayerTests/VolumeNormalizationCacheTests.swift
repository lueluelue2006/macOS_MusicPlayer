import AVFoundation
import XCTest
@testable import MusicPlayer

@MainActor
final class VolumeNormalizationCacheTests: XCTestCase {
    func testReplacingFileAtSamePathInvalidatesCachedLoudness() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("fixture.wav")
        try writeWAV(to: audioURL, amplitude: 0.08)

        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json")
        )
        let quietGain = player.calculateNormalizedVolume(for: audioURL, persist: false)
        XCTAssertTrue(player.hasVolumeNormalizationCache(for: audioURL))

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let originalDate = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        let originalSize = try XCTUnwrap(originalAttributes[.size] as? NSNumber)
        let originalIdentifier = try XCTUnwrap(originalAttributes[.systemFileNumber] as? NSNumber)

        let replacementURL = directory.appendingPathComponent("replacement.wav")
        try writeWAV(to: replacementURL, amplitude: 0.50)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: replacementURL.path
        )
        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.moveItem(at: replacementURL, to: audioURL)

        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        XCTAssertEqual(replacementAttributes[.size] as? NSNumber, originalSize)
        let replacementDate = try XCTUnwrap(replacementAttributes[.modificationDate] as? Date)
        XCTAssertEqual(replacementDate.timeIntervalSince1970, originalDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotEqual(replacementAttributes[.systemFileNumber] as? NSNumber, originalIdentifier)

        XCTAssertFalse(player.hasVolumeNormalizationCache(for: audioURL))
        let loudGain = player.calculateNormalizedVolume(for: audioURL, persist: false)
        XCTAssertLessThan(loudGain, quietGain)
    }

    func testV2MigrationPreservesNonnegativeLoudnessValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-cache-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("zero-db.wav")
        let cacheURL = directory.appendingPathComponent("volume-cache.json")
        let legacyPayload: [String: Any] = [
            "version": 2,
            "loudnessDbByPath": [audioURL.path: 0.0]
        ]
        try JSONSerialization.data(withJSONObject: legacyPayload).write(to: cacheURL)

        let player = AudioPlayer(volumeCacheFileURLOverride: cacheURL)
        player.flushVolumeCachePersistence()

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        XCTAssertEqual(payload["version"] as? Int, 3)
        let entries = try XCTUnwrap(payload["entriesByPath"] as? [String: Any])
        let entry = try XCTUnwrap(entries[PathKey.canonical(for: audioURL)] as? [String: Any])
        let loudnessDb = try XCTUnwrap(entry["loudnessDb"] as? Double)
        XCTAssertEqual(loudnessDb, 0.0, accuracy: 0.000_1)
    }

    func testV3SignedCacheReloadsAcrossAudioPlayerInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-cache-cold-start-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("fixture.wav")
        let cacheURL = directory.appendingPathComponent("volume-cache.json")
        try writeWAV(to: audioURL, amplitude: 0.12)

        let analyzedGain: Float
        do {
            let analyzingPlayer = AudioPlayer(volumeCacheFileURLOverride: cacheURL)
            analyzedGain = analyzingPlayer.calculateNormalizedVolume(for: audioURL, persist: true)
            XCTAssertTrue(analyzingPlayer.hasVolumeNormalizationCache(for: audioURL))
            analyzingPlayer.flushVolumeCachePersistence()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let reloadedPlayer = AudioPlayer(volumeCacheFileURLOverride: cacheURL)
        XCTAssertTrue(reloadedPlayer.hasVolumeNormalizationCache(for: audioURL))
        let reloadedGain = reloadedPlayer.calculateNormalizedVolume(for: audioURL, persist: false)
        XCTAssertEqual(reloadedGain, analyzedGain, accuracy: 0.000_1)
    }

    func testAutoIdlePreanalysisProcessesAtMostTwoFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-auto-idle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let urls = (0 ..< 3).map { directory.appendingPathComponent("\($0).wav") }
        for (index, url) in urls.enumerated() {
            try writeWAV(to: url, amplitude: 0.10 + Float(index) * 0.05)
        }
        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json")
        )
        defer { player.cancelVolumeNormalizationPreanalysis() }

        player.startVolumeNormalizationPreanalysis(urls: urls, reason: .autoIdle)
        let publishedLimit = await waitUntil(timeout: 2) {
            player.volumePreanalysisTotal == 2
        }
        XCTAssertTrue(publishedLimit)
        XCTAssertEqual(player.volumePreanalysisTotal, 2)

        let completed = await waitUntil(timeout: 5) {
            !player.isVolumePreanalysisRunning && player.volumePreanalysisCompleted == 2
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(
            urls.filter { player.hasVolumeNormalizationCache(for: $0) }.count,
            2
        )
    }

    func testImmediateAutoIdleCancellationCannotStartStaleAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-auto-idle-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("fixture.wav")
        try writeWAV(to: audioURL, amplitude: 0.2, duration: 30)
        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json")
        )

        player.startVolumeNormalizationPreanalysis(urls: [audioURL], reason: .autoIdle)
        player.cancelVolumeNormalizationPreanalysisIfAutoIdle()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(player.isVolumePreanalysisRunning)
        XCTAssertFalse(player.hasVolumeNormalizationCache(for: audioURL))
    }

    func testFailedAutoIdleItemEntersCooldownInsteadOfPollingEveryMinute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-auto-idle-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let badURL = directory.appendingPathComponent("not-audio.mp3")
        try Data("plain text".utf8).write(to: badURL)
        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json")
        )

        player.startVolumeNormalizationPreanalysis(urls: [badURL], reason: .autoIdle)
        let completed = await waitUntil(timeout: 2) {
            !player.isVolumePreanalysisRunning && player.volumePreanalysisCompleted == 1
        }

        XCTAssertTrue(completed)
        XCTAssertFalse(player.hasMissingVolumeNormalizationCache(in: [badURL]))
        XCTAssertGreaterThan(
            try XCTUnwrap(player.nextVolumeNormalizationRetryDate),
            Date()
        )
    }

    func testClearCannotBeOverwrittenByOlderDebouncedSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-cache-clear-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("fixture.wav")
        let cacheURL = directory.appendingPathComponent("volume-cache.json")
        try writeWAV(to: audioURL, amplitude: 0.2)
        let player = AudioPlayer(volumeCacheFileURLOverride: cacheURL)
        _ = player.calculateNormalizedVolume(for: audioURL, persist: true)
        XCTAssertTrue(player.hasVolumeNormalizationCache(for: audioURL))

        player.clearVolumeCache()
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let reloaded = AudioPlayer(volumeCacheFileURLOverride: cacheURL)
        XCTAssertFalse(reloaded.hasVolumeNormalizationCache(for: audioURL))
        XCTAssertEqual(reloaded.volumeNormalizationCacheCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testFutureVersionPreservesOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-cache-future-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("volume-cache.json")
        let audioURL = directory.appendingPathComponent("fixture.wav")
        try writeWAV(to: audioURL, amplitude: 0.5)

        // Create future version cache file missing current required fields
        let futureCache = """
        {
            "version": 999,
            "futureField": "must-preserve"
        }
        """
        let originalBytes = Data(futureCache.utf8)
        try originalBytes.write(to: cacheURL, options: .atomic)

        let player = AudioPlayer(volumeCacheFileURLOverride: cacheURL)

        // Attempt write operation
        _ = player.calculateNormalizedVolume(for: audioURL, persist: true)
        player.flushVolumeCachePersistence()

        let afterWriteBytes = try Data(contentsOf: cacheURL)
        XCTAssertEqual(afterWriteBytes, originalBytes, "Future version file must survive write")

        // Attempt clear operation
        player.clearVolumeCache()

        let afterClearBytes = try Data(contentsOf: cacheURL)
        XCTAssertEqual(afterClearBytes, originalBytes, "Future version file must survive clear")
    }

    func testUnknownFormatPreservesOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-cache-unknown-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("volume-cache.json")
        let audioURL = directory.appendingPathComponent("fixture.wav")
        try writeWAV(to: audioURL, amplitude: 0.5)

        // Create corrupted/unknown format
        let corruptedCache = Data("not valid json".utf8)
        try corruptedCache.write(to: cacheURL, options: .atomic)

        let player = AudioPlayer(volumeCacheFileURLOverride: cacheURL)

        _ = player.calculateNormalizedVolume(for: audioURL, persist: true)
        player.flushVolumeCachePersistence()

        let afterWriteBytes = try Data(contentsOf: cacheURL)
        XCTAssertEqual(afterWriteBytes, corruptedCache, "Unknown format file must survive write")

        player.clearVolumeCache()

        let afterClearBytes = try Data(contentsOf: cacheURL)
        XCTAssertEqual(afterClearBytes, corruptedCache, "Unknown format file must survive clear")
    }

    private func writeWAV(
        to url: URL,
        amplitude: Float,
        duration: TimeInterval = 0.5
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let sampleRate = 8_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frameCount) {
            let time = Double(index) / sampleRate
            samples[index] = Float(sin(2 * Double.pi * 440 * time)) * amplitude
        }
        try file.write(from: buffer)
    }
}
