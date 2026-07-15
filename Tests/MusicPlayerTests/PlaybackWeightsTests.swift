import XCTest
@testable import MusicPlayer

@MainActor
final class PlaybackWeightsTests: XCTestCase {
    private struct CacheEnvelope: Codable, Equatable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    func testSixLevelTableAndGreenDefault() throws {
        let expected: [(PlaybackWeights.Level, Int, Double)] = [
            (.white, 0, 0.5),
            (.green, 1, 1.0),
            (.blue, 2, 1.6),
            (.purple, 3, 3.2),
            (.gold, 4, 4.8),
            (.red, 5, 6.4),
        ]

        XCTAssertEqual(PlaybackWeights.Level.allCases.map(\.rawValue), expected.map(\.1))
        XCTAssertEqual(PlaybackWeights.Level.defaultLevel, .green)
        for (level, rawValue, multiplier) in expected {
            XCTAssertEqual(level.rawValue, rawValue)
            XCTAssertEqual(level.multiplier, multiplier, accuracy: 0.000_1)
        }

        try withTemporaryCache { cacheURL, directory in
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            let trackURL = directory.appendingPathComponent("default.mp3")
            let playlistID = UUID()

            XCTAssertEqual(weights.level(for: trackURL, scope: .queue), .green)
            XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlistID)), .green)
            XCTAssertEqual(weights.multiplier(for: trackURL, scope: .queue), 1.0, accuracy: 0.000_1)
        }
    }

    func testIPCParserAcceptsOnlySixNumericLevels() {
        for level in PlaybackWeights.Level.allCases {
            XCTAssertEqual(IPCServer.parseWeightLevel("\(level.rawValue)"), level)
        }

        XCTAssertNil(IPCServer.parseWeightLevel("-1"))
        XCTAssertNil(IPCServer.parseWeightLevel("6"))
        XCTAssertNil(IPCServer.parseWeightLevel("999"))
        XCTAssertNil(IPCServer.parseWeightLevel("not-a-level"))
        XCTAssertEqual(IPCServer.parseWeightLevel(" 0.5x "), .white)
        XCTAssertEqual(IPCServer.parseWeightLevel("BLUE"), .blue)
    }

    func testAllSixLevelsRoundTripAcrossQueueAndPlaylistScopes() throws {
        try withTemporaryCache { cacheURL, directory in
            let playlistID = UUID()
            let queueURLs = PlaybackWeights.Level.allCases.map {
                directory.appendingPathComponent("queue-\($0.rawValue).mp3")
            }
            let playlistURLs = PlaybackWeights.Level.allCases.map {
                directory.appendingPathComponent("playlist-\($0.rawValue).mp3")
            }

            do {
                let writer = PlaybackWeights(cacheFileURLOverride: cacheURL)
                for (index, level) in PlaybackWeights.Level.allCases.enumerated() {
                    _ = writer.setLevel(level, for: queueURLs[index], scope: .queue)
                    _ = writer.setLevel(level, for: playlistURLs[index], scope: .playlist(playlistID))
                }
                writer.flushPersistence()
            }

            let reader = PlaybackWeights(cacheFileURLOverride: cacheURL)
            for (index, level) in PlaybackWeights.Level.allCases.enumerated() {
                XCTAssertEqual(reader.level(for: queueURLs[index], scope: .queue), level)
                XCTAssertEqual(
                    reader.level(for: playlistURLs[index], scope: .playlist(playlistID)),
                    level
                )
            }

            let envelope = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(envelope.version, 3)
            XCTAssertNil(envelope.queueLevels[PlaybackWeights.key(for: queueURLs[1])])
            XCTAssertNil(
                envelope.playlistLevels[playlistID.uuidString]?[PlaybackWeights.key(for: playlistURLs[1])]
            )
        }
    }

    func testSameTrackKeepsQueueAndPlaylistWeightsIndependentAfterReload() throws {
        try withTemporaryCache { cacheURL, directory in
            let trackURL = directory.appendingPathComponent("shared-track.mp3")
            let playlistID = UUID()

            do {
                let writer = PlaybackWeights(cacheFileURLOverride: cacheURL)
                _ = writer.setLevel(.white, for: trackURL, scope: .queue)
                _ = writer.setLevel(.red, for: trackURL, scope: .playlist(playlistID))

                XCTAssertEqual(writer.level(for: trackURL, scope: .queue), .white)
                XCTAssertEqual(writer.level(for: trackURL, scope: .playlist(playlistID)), .red)
                writer.flushPersistence()
            }

            let reader = PlaybackWeights(cacheFileURLOverride: cacheURL)
            XCTAssertEqual(reader.level(for: trackURL, scope: .queue), .white)
            XCTAssertEqual(reader.level(for: trackURL, scope: .playlist(playlistID)), .red)
        }
    }

    func testV1QueueAndPlaylistMigrationPersistsV3WithoutMigratingTwice() throws {
        try withTemporaryCache { cacheURL, directory in
            let playlistID = UUID()
            let legacyRawValues = Array(-1 ... 4)
            let queueURLs = legacyRawValues.map {
                directory.appendingPathComponent("legacy-queue-\($0).mp3")
            }
            let playlistURLs = legacyRawValues.map {
                directory.appendingPathComponent("legacy-playlist-\($0).mp3")
            }
            let v1 = CacheEnvelope(
                version: 1,
                queueLevels: Dictionary(uniqueKeysWithValues: zip(queueURLs, legacyRawValues).map {
                    (PlaybackWeights.key(for: $0.0), $0.1)
                }),
                playlistLevels: [
                    playlistID.uuidString: Dictionary(
                        uniqueKeysWithValues: zip(playlistURLs, legacyRawValues).map {
                            (PlaybackWeights.key(for: $0.0), $0.1)
                        }
                    )
                ]
            )
            try JSONEncoder().encode(v1).write(to: cacheURL, options: .atomic)

            let migrated = PlaybackWeights(cacheFileURLOverride: cacheURL)
            for (index, legacyRaw) in legacyRawValues.enumerated() {
                let expected = try XCTUnwrap(PlaybackWeights.Level(rawValue: legacyRaw + 1))
                XCTAssertEqual(migrated.level(for: queueURLs[index], scope: .queue), expected)
                XCTAssertEqual(
                    migrated.level(for: playlistURLs[index], scope: .playlist(playlistID)),
                    expected
                )
            }

            let persistedV3 = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(persistedV3.version, 3)
            for (index, legacyRaw) in legacyRawValues.enumerated() {
                let expectedRaw = legacyRaw + 1
                let queueKey = PlaybackWeights.key(for: queueURLs[index])
                let playlistKey = PlaybackWeights.key(for: playlistURLs[index])
                if expectedRaw == PlaybackWeights.Level.defaultLevel.rawValue {
                    XCTAssertNil(persistedV3.queueLevels[queueKey])
                    XCTAssertNil(persistedV3.playlistLevels[playlistID.uuidString]?[playlistKey])
                } else {
                    XCTAssertEqual(persistedV3.queueLevels[queueKey], expectedRaw)
                    XCTAssertEqual(
                        persistedV3.playlistLevels[playlistID.uuidString]?[playlistKey],
                        expectedRaw
                    )
                }
            }

            let reloadedV3 = PlaybackWeights(cacheFileURLOverride: cacheURL)
            for (index, legacyRaw) in legacyRawValues.enumerated() {
                let expected = try XCTUnwrap(PlaybackWeights.Level(rawValue: legacyRaw + 1))
                XCTAssertEqual(reloadedV3.level(for: queueURLs[index], scope: .queue), expected)
                XCTAssertEqual(
                    reloadedV3.level(for: playlistURLs[index], scope: .playlist(playlistID)),
                    expected
                )
            }
            XCTAssertEqual(try decodeEnvelope(at: cacheURL), persistedV3)
        }
    }

    func testV2MigrationMakesGreenSparseDefaultAndPreservesOverrides() throws {
        try withTemporaryCache { cacheURL, directory in
            let playlistID = UUID()
            let queueURLs = PlaybackWeights.Level.allCases.map {
                directory.appendingPathComponent("v2-queue-\($0.rawValue).mp3")
            }
            let playlistURLs = PlaybackWeights.Level.allCases.map {
                directory.appendingPathComponent("v2-playlist-\($0.rawValue).mp3")
            }
            let missingQueueURL = directory.appendingPathComponent("v2-queue-missing.mp3")
            let missingPlaylistURL = directory.appendingPathComponent("v2-playlist-missing.mp3")
            let v2 = CacheEnvelope(
                version: 2,
                queueLevels: Dictionary(uniqueKeysWithValues: zip(
                    queueURLs.map(PlaybackWeights.key(for:)),
                    PlaybackWeights.Level.allCases.map(\.rawValue)
                )),
                playlistLevels: [
                    playlistID.uuidString: Dictionary(uniqueKeysWithValues: zip(
                        playlistURLs.map(PlaybackWeights.key(for:)),
                        PlaybackWeights.Level.allCases.map(\.rawValue)
                    ))
                ]
            )
            try JSONEncoder().encode(v2).write(to: cacheURL, options: .atomic)

            let migrated = PlaybackWeights(cacheFileURLOverride: cacheURL)
            XCTAssertEqual(migrated.level(for: missingQueueURL, scope: .queue), .green)
            XCTAssertEqual(
                migrated.level(for: missingPlaylistURL, scope: .playlist(playlistID)),
                .green
            )
            for (index, expected) in PlaybackWeights.Level.allCases.enumerated() {
                XCTAssertEqual(migrated.level(for: queueURLs[index], scope: .queue), expected)
                XCTAssertEqual(
                    migrated.level(for: playlistURLs[index], scope: .playlist(playlistID)),
                    expected
                )
            }

            let persistedV3 = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(persistedV3.version, 3)
            for (index, level) in PlaybackWeights.Level.allCases.enumerated() {
                let queueKey = PlaybackWeights.key(for: queueURLs[index])
                let playlistKey = PlaybackWeights.key(for: playlistURLs[index])
                if level == .defaultLevel {
                    XCTAssertNil(persistedV3.queueLevels[queueKey])
                    XCTAssertNil(persistedV3.playlistLevels[playlistID.uuidString]?[playlistKey])
                } else {
                    XCTAssertEqual(persistedV3.queueLevels[queueKey], level.rawValue)
                    XCTAssertEqual(
                        persistedV3.playlistLevels[playlistID.uuidString]?[playlistKey],
                        level.rawValue
                    )
                }
            }

            let reloadedV3 = PlaybackWeights(cacheFileURLOverride: cacheURL)
            for (index, expected) in PlaybackWeights.Level.allCases.enumerated() {
                XCTAssertEqual(reloadedV3.level(for: queueURLs[index], scope: .queue), expected)
                XCTAssertEqual(
                    reloadedV3.level(for: playlistURLs[index], scope: .playlist(playlistID)),
                    expected
                )
            }
        }
    }

    func testDefaultLevelRemainsSparseOnDisk() throws {
        try withTemporaryCache { cacheURL, directory in
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            let playlistID = UUID()
            let queueURL = directory.appendingPathComponent("sparse-queue.mp3")
            let playlistURL = directory.appendingPathComponent("sparse-playlist.mp3")

            XCTAssertEqual(weights.level(for: queueURL, scope: .queue), .green)
            XCTAssertEqual(weights.level(for: playlistURL, scope: .playlist(playlistID)), .green)
            _ = weights.setLevel(.red, for: queueURL, scope: .queue)
            _ = weights.setLevel(.gold, for: playlistURL, scope: .playlist(playlistID))
            _ = weights.setLevel(.green, for: queueURL, scope: .queue)
            _ = weights.setLevel(.green, for: playlistURL, scope: .playlist(playlistID))
            weights.flushPersistence()

            let envelope = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(envelope.version, 3)
            XCTAssertTrue(envelope.queueLevels.isEmpty)
            XCTAssertTrue(envelope.playlistLevels.isEmpty)
        }
    }

    func testUnknownCacheVersionIsIgnoredWithoutOverwritingIt() throws {
        try withTemporaryCache { cacheURL, directory in
            let trackURL = directory.appendingPathComponent("future.mp3")
            let futureEnvelope = CacheEnvelope(
                version: 99,
                queueLevels: [PlaybackWeights.key(for: trackURL): PlaybackWeights.Level.red.rawValue],
                playlistLevels: [:]
            )
            let originalData = try JSONEncoder().encode(futureEnvelope)
            try originalData.write(to: cacheURL, options: .atomic)

            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            XCTAssertEqual(weights.level(for: trackURL, scope: .queue), .green)
            weights.flushPersistence()

            XCTAssertEqual(try Data(contentsOf: cacheURL), originalData)
        }
    }

    func testMalformedCacheIsQuarantinedAndReplacedOnMutation() throws {
        let corruptFixtures = [
            Data(#"{"version":2,"queueLevels":"changed-shape"}"#.utf8),
            Data("not-json".utf8),
        ]

        for originalData in corruptFixtures {
            try withTemporaryCache { cacheURL, directory in
                try originalData.write(to: cacheURL, options: .atomic)
                let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
                let trackURL = directory.appendingPathComponent("track.mp3")

                if case .quarantinedCorrupt(let backupURL) = weights.persistenceState {
                    XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
                } else {
                    XCTFail("Expected quarantinedCorrupt for corrupt data")
                }

                _ = weights.setLevel(.purple, for: trackURL, scope: .queue)
                weights.flushPersistence()

                let envelope = try decodeEnvelope(at: cacheURL)
                XCTAssertEqual(envelope.version, 3)
                XCTAssertEqual(envelope.queueLevels[PlaybackWeights.key(for: trackURL)], PlaybackWeights.Level.purple.rawValue)
            }
        }
    }

    func testFutureSchemaRemainsUnchangedThroughAllMutationsAndFlushes() throws {
        let futureData = Data(#"{"version":99,"futureLevels":["opaque"],"checksum":"must-keep"}"#.utf8)

        try withTemporaryCache { cacheURL, directory in
            try futureData.write(to: cacheURL, options: .atomic)
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            let trackURL = directory.appendingPathComponent("track.mp3")
            let playlistID = UUID()

            XCTAssertEqual(weights.persistenceState, .readOnlyPreserved(.unsupportedVersion(99)))

            let setResult = weights.setLevel(.red, for: trackURL, scope: .queue)
            if case .rejectedReadOnly(let reason) = setResult {
                XCTAssertEqual(reason, .unsupportedVersion(99))
            } else {
                XCTFail("Expected rejectedReadOnly, got \(setResult)")
            }

            let clearResult = weights.clear(scope: .queue)
            if case .rejectedReadOnly(let reason) = clearResult {
                XCTAssertEqual(reason, .unsupportedVersion(99))
            } else {
                XCTFail("Expected rejectedReadOnly, got \(clearResult)")
            }

            let clearAllResult = weights.clearAll()
            if case .rejectedReadOnly(let reason) = clearAllResult {
                XCTAssertEqual(reason, .unsupportedVersion(99))
            } else {
                XCTFail("Expected rejectedReadOnly, got \(clearAllResult)")
            }

            let syncResult = weights.syncPlaylistOverridesToQueue(from: playlistID)
            if case .rejectedReadOnly(let reason) = syncResult.mutationResult {
                XCTAssertEqual(reason, .unsupportedVersion(99))
            } else {
                XCTFail("Expected rejectedReadOnly, got \(syncResult.mutationResult)")
            }

            weights.flushPersistence()
            XCTAssertEqual(try Data(contentsOf: cacheURL), futureData)
        }
    }

    func testQuarantineSuccessPreservesOriginalAndAllowsSubsequentWrites() throws {
        let corruptData = Data("not-json-at-all".utf8)

        try withTemporaryCache { cacheURL, directory in
            try corruptData.write(to: cacheURL, options: .atomic)
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            let trackURL = directory.appendingPathComponent("track.mp3")

            if case .quarantinedCorrupt(let backupURL) = weights.persistenceState {
                XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
                XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
                XCTAssertTrue(backupURL.lastPathComponent.hasPrefix("playback-weights.quarantined-"))
            } else {
                XCTFail("Expected quarantinedCorrupt state, got \(weights.persistenceState)")
            }

            let setResult = weights.setLevel(.blue, for: trackURL, scope: .queue)
            XCTAssertEqual(setResult, .applied)

            weights.flushPersistence()

            let envelope = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(envelope.version, 3)
            XCTAssertEqual(envelope.queueLevels[PlaybackWeights.key(for: trackURL)], PlaybackWeights.Level.blue.rawValue)

            let reloaded = PlaybackWeights(cacheFileURLOverride: cacheURL)
            XCTAssertEqual(reloaded.persistenceState, .ready)
            XCTAssertEqual(reloaded.level(for: trackURL, scope: .queue), .blue)
        }
    }

    func testQuarantineFailureKeepsFileAndEntersReadOnly() throws {
        let corruptData = Data("corrupt-content".utf8)

        try withTemporaryCache { cacheURL, directory in
            try corruptData.write(to: cacheURL, options: .atomic)

            let failingMover: (URL, URL) throws -> Void = { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
            }

            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL, fileMover: failingMover)
            let trackURL = directory.appendingPathComponent("track.mp3")

            XCTAssertEqual(weights.persistenceState, .readOnlyPreserved(.quarantineFailed))

            let setResult = weights.setLevel(.gold, for: trackURL, scope: .queue)
            if case .rejectedReadOnly(let reason) = setResult {
                XCTAssertEqual(reason, .quarantineFailed)
            } else {
                XCTFail("Expected rejectedReadOnly, got \(setResult)")
            }

            weights.flushPersistence()
            XCTAssertEqual(try Data(contentsOf: cacheURL), corruptData)
        }
    }

    func testFlushPreventsCancelledDebounceFromWritingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playback-weights-flush-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("playback-weights.json")
        let trackURL = directory.appendingPathComponent("flush.mp3")
        let trackKey = PlaybackWeights.key(for: trackURL)
        let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
        _ = weights.setLevel(.red, for: trackURL, scope: .queue)
        weights.flushPersistence()

        let marker = CacheEnvelope(
            version: 2,
            queueLevels: [trackKey: PlaybackWeights.Level.green.rawValue],
            playlistLevels: [:]
        )
        try JSONEncoder().encode(marker).write(to: cacheURL, options: .atomic)
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(try decodeEnvelope(at: cacheURL), marker)
    }

    private func withTemporaryCache(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playback-weights-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("playback-weights.json"), directory)
    }

    private func decodeEnvelope(at url: URL) throws -> CacheEnvelope {
        try JSONDecoder().decode(CacheEnvelope.self, from: Data(contentsOf: url))
    }
}
