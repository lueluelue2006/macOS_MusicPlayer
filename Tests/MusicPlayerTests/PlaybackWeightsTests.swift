import XCTest
@testable import MusicPlayer

@MainActor
final class PlaybackWeightsTests: XCTestCase {
    private struct CacheEnvelope: Codable, Equatable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    func testSixLevelTableAndBlueDefault() throws {
        let expected: [(PlaybackWeights.Level, Int, Double)] = [
            (.white, 0, 0.5),
            (.green, 1, 1.0),
            (.blue, 2, 1.6),
            (.purple, 3, 3.2),
            (.gold, 4, 4.8),
            (.red, 5, 6.4),
        ]

        XCTAssertEqual(PlaybackWeights.Level.allCases.map(\.rawValue), expected.map(\.1))
        XCTAssertEqual(PlaybackWeights.Level.defaultLevel, .blue)
        for (level, rawValue, multiplier) in expected {
            XCTAssertEqual(level.rawValue, rawValue)
            XCTAssertEqual(level.multiplier, multiplier, accuracy: 0.000_1)
        }

        try withTemporaryCache { cacheURL, directory in
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            let trackURL = directory.appendingPathComponent("default.mp3")
            let playlistID = UUID()

            XCTAssertEqual(weights.level(for: trackURL, scope: .queue), .blue)
            XCTAssertEqual(weights.level(for: trackURL, scope: .playlist(playlistID)), .blue)
            XCTAssertEqual(weights.multiplier(for: trackURL, scope: .queue), 1.6, accuracy: 0.000_1)
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
                    writer.setLevel(level, for: queueURLs[index], scope: .queue)
                    writer.setLevel(level, for: playlistURLs[index], scope: .playlist(playlistID))
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
            XCTAssertEqual(envelope.version, 2)
            XCTAssertNil(envelope.queueLevels[PlaybackWeights.key(for: queueURLs[2])])
            XCTAssertNil(
                envelope.playlistLevels[playlistID.uuidString]?[PlaybackWeights.key(for: playlistURLs[2])]
            )
        }
    }

    func testV1QueueAndPlaylistMigrationPersistsV2WithoutMigratingTwice() throws {
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

            let persistedV2 = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(persistedV2.version, 2)
            for (index, legacyRaw) in legacyRawValues.enumerated() {
                let expectedRaw = legacyRaw + 1
                let queueKey = PlaybackWeights.key(for: queueURLs[index])
                let playlistKey = PlaybackWeights.key(for: playlistURLs[index])
                if expectedRaw == PlaybackWeights.Level.defaultLevel.rawValue {
                    XCTAssertNil(persistedV2.queueLevels[queueKey])
                    XCTAssertNil(persistedV2.playlistLevels[playlistID.uuidString]?[playlistKey])
                } else {
                    XCTAssertEqual(persistedV2.queueLevels[queueKey], expectedRaw)
                    XCTAssertEqual(
                        persistedV2.playlistLevels[playlistID.uuidString]?[playlistKey],
                        expectedRaw
                    )
                }
            }

            let reloadedV2 = PlaybackWeights(cacheFileURLOverride: cacheURL)
            for (index, legacyRaw) in legacyRawValues.enumerated() {
                let expected = try XCTUnwrap(PlaybackWeights.Level(rawValue: legacyRaw + 1))
                XCTAssertEqual(reloadedV2.level(for: queueURLs[index], scope: .queue), expected)
                XCTAssertEqual(
                    reloadedV2.level(for: playlistURLs[index], scope: .playlist(playlistID)),
                    expected
                )
            }
            XCTAssertEqual(try decodeEnvelope(at: cacheURL), persistedV2)
        }
    }

    func testDefaultLevelRemainsSparseOnDisk() throws {
        try withTemporaryCache { cacheURL, directory in
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            let playlistID = UUID()
            let queueURL = directory.appendingPathComponent("sparse-queue.mp3")
            let playlistURL = directory.appendingPathComponent("sparse-playlist.mp3")

            XCTAssertEqual(weights.level(for: queueURL, scope: .queue), .blue)
            XCTAssertEqual(weights.level(for: playlistURL, scope: .playlist(playlistID)), .blue)
            weights.setLevel(.red, for: queueURL, scope: .queue)
            weights.setLevel(.gold, for: playlistURL, scope: .playlist(playlistID))
            weights.setLevel(.blue, for: queueURL, scope: .queue)
            weights.setLevel(.blue, for: playlistURL, scope: .playlist(playlistID))
            weights.flushPersistence()

            let envelope = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(envelope.version, 2)
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
            XCTAssertEqual(weights.level(for: trackURL, scope: .queue), .blue)
            weights.flushPersistence()

            XCTAssertEqual(try Data(contentsOf: cacheURL), originalData)
        }
    }

    func testUnknownOrMalformedCacheSchemaIsPreservedOnFlush() throws {
        let fixtures = [
            Data(#"{"version":99,"futureLevels":["opaque"],"checksum":"keep"}"#.utf8),
            Data(#"{"version":2,"queueLevels":"changed-shape"}"#.utf8),
            Data("not-json".utf8),
        ]

        for originalData in fixtures {
            try withTemporaryCache { cacheURL, directory in
                try originalData.write(to: cacheURL, options: .atomic)
                let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
                let trackURL = directory.appendingPathComponent("preserved.mp3")

                XCTAssertEqual(weights.level(for: trackURL, scope: .queue), .blue)
                weights.flushPersistence()

                XCTAssertEqual(try Data(contentsOf: cacheURL), originalData)
            }
        }
    }

    func testExplicitDefaultAndClearAllReplacePreservedCache() throws {
        let futureData = Data(#"{"version":99,"futureLevels":["opaque"]}"#.utf8)

        try withTemporaryCache { cacheURL, directory in
            try futureData.write(to: cacheURL, options: .atomic)
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            weights.setLevel(.blue, for: directory.appendingPathComponent("default.mp3"), scope: .queue)
            weights.flushPersistence()

            let replaced = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(replaced.version, 2)
            XCTAssertTrue(replaced.queueLevels.isEmpty)
            XCTAssertTrue(replaced.playlistLevels.isEmpty)
        }

        try withTemporaryCache { cacheURL, _ in
            try futureData.write(to: cacheURL, options: .atomic)
            let weights = PlaybackWeights(cacheFileURLOverride: cacheURL)
            weights.clearAll()
            weights.flushPersistence()

            let replaced = try decodeEnvelope(at: cacheURL)
            XCTAssertEqual(replaced.version, 2)
            XCTAssertTrue(replaced.queueLevels.isEmpty)
            XCTAssertTrue(replaced.playlistLevels.isEmpty)
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
        weights.setLevel(.red, for: trackURL, scope: .queue)
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
