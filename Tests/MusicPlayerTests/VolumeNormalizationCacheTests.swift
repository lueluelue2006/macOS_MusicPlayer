import AVFoundation
import XCTest
@testable import MusicPlayer

@MainActor
final class VolumeNormalizationCacheTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var value: TimeInterval

        init(_ value: TimeInterval) {
            self.value = value
        }
    }

    func testSQLiteStoreReloadsCurrentMeasurementAndRejectsReplacedFile() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("volume.sqlite3")
            let audioURL = directory.appendingPathComponent("fixture.bin")
            try Data(repeating: 1, count: 32).write(to: audioURL)
            let snapshot = FileValidationSnapshot.load(for: audioURL)

            do {
                let store = try VolumeAnalysisStore(databaseURL: databaseURL)
                XCTAssertSuccess(store.save(
                    measurement: measurement(lufs: -20),
                    for: audioURL,
                    snapshot: snapshot
                ))
                XCTAssertEqual(store.measurement(for: audioURL)?.integratedLoudnessLUFS, -20)
            }

            let reloaded = try VolumeAnalysisStore(databaseURL: databaseURL)
            XCTAssertEqual(reloaded.measurement(for: audioURL)?.integratedLoudnessLUFS, -20)

            try Data(repeating: 2, count: 64).write(to: audioURL, options: .atomic)
            XCTAssertNil(reloaded.measurement(for: audioURL))
            XCTAssertEqual(reloaded.analysisCount, 0)
        }
    }

    func testSQLiteCapacityUsesPersistentLRUAndKeepsHotCacheBounded() throws {
        try withTemporaryDirectory { directory in
            let clock = Clock(1_000)
            let store = try VolumeAnalysisStore(
                databaseURL: directory.appendingPathComponent("volume.sqlite3"),
                analysisCapacity: 2,
                hotCacheCapacity: 1,
                now: { clock.value }
            )
            let urls = try (0..<3).map { index -> URL in
                let url = directory.appendingPathComponent("\(index).bin")
                try Data(repeating: UInt8(index), count: index + 8).write(to: url)
                return url
            }

            XCTAssertSuccess(store.save(
                measurement: measurement(lufs: -21),
                for: urls[0],
                snapshot: FileValidationSnapshot.load(for: urls[0])
            ))
            clock.value += 1
            XCTAssertSuccess(store.save(
                measurement: measurement(lufs: -20),
                for: urls[1],
                snapshot: FileValidationSnapshot.load(for: urls[1])
            ))

            clock.value += 25 * 60 * 60
            XCTAssertNotNil(store.measurement(for: urls[0]))
            clock.value += 1
            XCTAssertSuccess(store.save(
                measurement: measurement(lufs: -19),
                for: urls[2],
                snapshot: FileValidationSnapshot.load(for: urls[2])
            ))

            XCTAssertNotNil(store.measurement(for: urls[0]))
            XCTAssertNil(store.measurement(for: urls[1]))
            XCTAssertNotNil(store.measurement(for: urls[2]))
            XCTAssertEqual(store.analysisCount, 2)
        }
    }

    func testFailureBackoffPersistsAndExpires() throws {
        try withTemporaryDirectory { directory in
            let clock = Clock(10_000)
            let databaseURL = directory.appendingPathComponent("volume.sqlite3")
            let url = directory.appendingPathComponent("bad.bin")
            try Data("not audio".utf8).write(to: url)
            let snapshot = FileValidationSnapshot.load(for: url)

            do {
                let store = try VolumeAnalysisStore(
                    databaseURL: databaseURL,
                    now: { clock.value }
                )
                store.recordFailure(.decodeFailed, for: url, snapshot: snapshot)
                XCTAssertFalse(store.shouldRetryAnalysis(for: url))
                XCTAssertEqual(store.nextRetryDate?.timeIntervalSince1970, 10_900)
            }

            let reloaded = try VolumeAnalysisStore(
                databaseURL: databaseURL,
                now: { clock.value }
            )
            XCTAssertFalse(reloaded.shouldRetryAnalysis(for: url))
            clock.value = 10_901
            XCTAssertTrue(reloaded.shouldRetryAnalysis(for: url))
        }
    }

    func testLegacyV3RMSCacheIsInvalidatedInsteadOfRelabeledAsLUFS() throws {
        try withTemporaryDirectory { directory in
            let legacyURL = directory.appendingPathComponent("volume-cache.json")
            try Data(#"{"version":3,"entriesByPath":{}}"#.utf8).write(to: legacyURL)

            let store = try VolumeAnalysisStore(
                databaseURL: directory.appendingPathComponent("volume.sqlite3"),
                legacyJSONURL: legacyURL
            )

            XCTAssertEqual(store.analysisCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
            XCTAssertNil(store.protectedCacheReason)
        }
    }

    func testCompatibleV4EntryImportsOnceIntoSQLite() throws {
        try withTemporaryDirectory { directory in
            let audioURL = directory.appendingPathComponent("fixture.bin")
            try Data(repeating: 4, count: 48).write(to: audioURL)
            let snapshot = FileValidationSnapshot.load(for: audioURL)
            let legacyURL = directory.appendingPathComponent("volume-cache.json")
            let payload: [String: Any] = [
                "version": 4,
                "entriesByPath": [
                    audioURL.path: [
                        "integratedLoudnessLUFS": -18.5,
                        "estimatedTruePeakDbTP": -2.0,
                        "samplePeakDbFS": -2.5,
                        "estimatedTruePeakSource": 1,
                        "analyzedFrameCount": 48_000,
                        "sampleRate": 48_000,
                        "algorithmIdentifier": LoudnessAlgorithm.identifier,
                        "algorithmVersion": LoudnessAlgorithm.version,
                        "fileSize": snapshot.fileSize,
                        "modificationTimeNanoseconds": snapshot.mtimeNs,
                        "fileIdentifier": snapshot.inode.map { $0 as Any } ?? NSNull(),
                        "updatedAt": 100,
                        "lastUsedAt": 101
                    ]
                ]
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: legacyURL)

            let store = try VolumeAnalysisStore(
                databaseURL: directory.appendingPathComponent("volume.sqlite3"),
                legacyJSONURL: legacyURL
            )

            XCTAssertEqual(store.measurement(for: audioURL)?.integratedLoudnessLUFS, -18.5)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
            XCTAssertEqual(store.analysisCount, 1)
        }
    }

    func testEmptyV4CacheIsCompatibleAndDoesNotCreateReadOnlyTrap() throws {
        try withTemporaryDirectory { directory in
            let legacyURL = directory.appendingPathComponent("volume-cache.json")
            try Data(#"{"version":4,"entriesByPath":{}}"#.utf8).write(to: legacyURL)
            let store = try VolumeAnalysisStore(
                databaseURL: directory.appendingPathComponent("volume.sqlite3"),
                legacyJSONURL: legacyURL
            )

            XCTAssertNil(store.protectedCacheReason)
            XCTAssertEqual(
                store.clear(),
                .cleared(analysisCount: 0, failureCount: 0, removedProtectedLegacy: false)
            )
        }
    }

    func testFutureLegacyCacheIsPreservedUntilExplicitForcedClear() throws {
        try withTemporaryDirectory { directory in
            let legacyURL = directory.appendingPathComponent("volume-cache.json")
            let original = Data(#"{"version":999,"future":"preserve"}"#.utf8)
            try original.write(to: legacyURL)
            let store = try VolumeAnalysisStore(
                databaseURL: directory.appendingPathComponent("volume.sqlite3"),
                legacyJSONURL: legacyURL
            )

            XCTAssertEqual(store.protectedCacheReason, .futureLegacyJSON(version: 999))
            XCTAssertEqual(store.clear(), .requiresConfirmation(.futureLegacyJSON(version: 999)))
            XCTAssertEqual(try Data(contentsOf: legacyURL), original)

            XCTAssertEqual(
                store.clear(forceProtectedData: true),
                .cleared(analysisCount: 0, failureCount: 0, removedProtectedLegacy: true)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        }
    }

    func testAudioPlayerUsesSQLiteCacheWithoutPlayingAudio() throws {
        try withTemporaryDirectory { directory in
            let audioURL = directory.appendingPathComponent("fixture.wav")
            let legacyURL = directory.appendingPathComponent("volume-cache.json")
            try writeWAV(to: audioURL, amplitude: 0.12)

            let analyzed: Float
            do {
                let player = AudioPlayer(volumeCacheFileURLOverride: legacyURL)
                analyzed = player.calculateNormalizedVolume(for: audioURL)
                XCTAssertTrue(player.hasVolumeNormalizationCache(for: audioURL))
                XCTAssertEqual(player.flushVolumeCachePersistence(), .flushed)
            }

            let reloaded = AudioPlayer(volumeCacheFileURLOverride: legacyURL)
            XCTAssertTrue(reloaded.hasVolumeNormalizationCache(for: audioURL))
            XCTAssertEqual(reloaded.calculateNormalizedVolume(for: audioURL), analyzed, accuracy: 0.000_1)
        }
    }

    func testSessionMeasurementRemainsUsableWhenSQLiteCannotInitialize() throws {
        try withTemporaryDirectory { directory in
            let audioURL = directory.appendingPathComponent("session-only.wav")
            try writeWAV(to: audioURL, amplitude: 0.12)
            let blockedParent = directory.appendingPathComponent("not-a-directory")
            try Data("blocker".utf8).write(to: blockedParent)
            let player = AudioPlayer(
                volumeCacheFileURLOverride: blockedParent.appendingPathComponent("volume-cache.json")
            )

            let first = player.calculateNormalizedVolume(for: audioURL)
            let second = player.calculateNormalizedVolume(for: audioURL)

            XCTAssertTrue(player.hasVolumeNormalizationCache(for: audioURL))
            XCTAssertEqual(second, first, accuracy: 0.000_1)
            guard case .failed = player.flushVolumeCachePersistence() else {
                return XCTFail("Unavailable SQLite persistence must be reported explicitly")
            }
            guard case .failed = player.clearVolumeCache() else {
                return XCTFail("Unavailable SQLite clear must be reported explicitly")
            }
            XCTAssertTrue(
                player.hasVolumeNormalizationCache(for: audioURL),
                "A failed disk clear must preserve the valid session measurement"
            )
            XCTAssertEqual(
                player.calculateNormalizedVolume(for: audioURL),
                first,
                accuracy: 0.000_1
            )
        }
    }

    func testFutureDatabasePreservesSessionMeasurementAndReportsFlushFailure() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("future.sqlite3")
            let seed = try SQLiteDatabase(fileURL: databaseURL)
            try seed.execute("PRAGMA application_id = 1297110604")
            try seed.execute("PRAGMA user_version = 99")
            try seed.checkpoint()
            seed.close()
            let original = try Data(contentsOf: databaseURL)

            let audioURL = directory.appendingPathComponent("future-session.wav")
            try writeWAV(to: audioURL, amplitude: 0.12)
            let player = AudioPlayer(volumeCacheFileURLOverride: databaseURL)
            let normalized = player.calculateNormalizedVolume(for: audioURL)

            XCTAssertTrue(normalized.isFinite)
            XCTAssertTrue(player.hasVolumeNormalizationCache(for: audioURL))
            XCTAssertEqual(
                player.clearVolumeCache(),
                .requiresConfirmation(.futureDatabase(version: 99))
            )
            XCTAssertTrue(player.hasVolumeNormalizationCache(for: audioURL))
            guard case .failed = player.flushVolumeCachePersistence() else {
                return XCTFail("A protected future database must not report a durable flush")
            }
            XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        }
    }

    private func measurement(lufs: Float) -> LoudnessMeasurement {
        LoudnessMeasurement(
            integratedLoudnessLUFS: lufs,
            estimatedTruePeakDbTP: -2,
            samplePeakDbFS: -3,
            analyzedFrameCount: 48_000,
            sampleRate: 48_000
        )
    }

    private func XCTAssertSuccess(
        _ result: Result<Int, VolumeAnalysisStoreError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .success = result else {
            XCTFail("Expected successful cache write", file: file, line: line)
            return
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-volume-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeWAV(to url: URL, amplitude: Float) throws {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        )
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount: AVAudioFrameCount = 24_000
        let chunkFrames: AVAudioFrameCount = 4_096
        var written: AVAudioFrameCount = 0
        while written < frameCount {
            let count = min(chunkFrames, frameCount - written)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
            )
            buffer.frameLength = count
            for channel in 0..<2 {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for index in 0..<Int(count) {
                    let frame = Double(written) + Double(index)
                    samples[index] = amplitude * Float(sin(2 * .pi * 997 * frame / sampleRate))
                }
            }
            try file.write(from: buffer)
            written += count
        }
    }
}
