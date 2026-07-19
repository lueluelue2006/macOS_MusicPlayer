import XCTest
@testable import MusicPlayer

final class PathKeyDiskMigratorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathKeyMigrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func assertMigrationPreserves(
        _ payload: [String: Any],
        fileName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try assertMigrationPreserves(data, fileName: fileName, file: file, line: line)
    }

    private func assertMigrationPreserves(
        _ data: Data,
        fileName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = tempDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun, file: file, line: line)
        XCTAssertEqual(result.migrationResult.changedFiles, 0, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), data, file: file, line: line)
        try FileManager.default.removeItem(at: url)
    }

    private func validMetadataV2Entry() -> [String: Any] {
        [
            "title": "Song",
            "artist": "Artist",
            "album": "Album",
            "year": "2026",
            "genre": "Pop",
            "fileSize": 5,
            "mtimeNs": 10,
            "inode": 12,
            "lastAccessedAt": 100
        ]
    }

    private func validDurationV3Entry() -> [String: Any] {
        [
            "durationSeconds": 180.0,
            "fileSize": 5,
            "mtimeNs": 10,
            "inode": 12,
            "lastAccessedAt": 100
        ]
    }

    private func validVolumeV4Entry() -> [String: Any] {
        [
            "integratedLoudnessLUFS": -18.5,
            "estimatedTruePeakDbTP": -2.0,
            "samplePeakDbFS": -2.5,
            "estimatedTruePeakSource": EstimatedTruePeakSource.oversampled.rawValue,
            "analyzedFrameCount": 48_000,
            "sampleRate": 48_000.0,
            "algorithmIdentifier": LoudnessAlgorithm.identifier,
            "algorithmVersion": LoudnessAlgorithm.version,
            "fileSize": 5,
            "modificationTimeNanoseconds": 10,
            "fileIdentifier": 12,
            "updatedAt": 100.0,
            "lastUsedAt": 101.0
        ]
    }

    // MARK: - Future Schema Protection

    func testFutureQueueVersionPreventsMigration() throws {
        let queueURL = tempDir.appendingPathComponent("playlist.json")

        // Create real case-preserved file that would be migrated if not protected
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        let lowercasedPath = songFile.path.lowercased()

        let futureRoot: [String: Any] = [
            "version": 99,
            "tracks": [["path": lowercasedPath]],
            "paths": [lowercasedPath],
            "currentIndex": 0,
            "futureField": "must-preserve"
        ]
        let originalBytes = try JSONSerialization.data(withJSONObject: futureRoot, options: [])
        try originalBytes.write(to: queueURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun, "migration should attempt to run")
        let afterBytes = try Data(contentsOf: queueURL)
        XCTAssertEqual(afterBytes, originalBytes, "future queue must not be modified")
    }

    func testFutureUserPlaylistsVersionPreventsMigration() throws {
        let playlistsURL = tempDir.appendingPathComponent("user-playlists.json")

        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        let lowercasedPath = songFile.path.lowercased()

        let futureRoot: [String: Any] = [
            "version": 99,
            "playlists": [
                [
                    "id": "12345678-1234-1234-1234-123456789012",
                    "name": "Future",
                    "tracks": [["path": lowercasedPath]],
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                ]
            ],
            "futureStoreField": 123
        ]
        let originalBytes = try JSONSerialization.data(withJSONObject: futureRoot, options: [])
        try originalBytes.write(to: playlistsURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun)
        let afterBytes = try Data(contentsOf: playlistsURL)
        XCTAssertEqual(afterBytes, originalBytes, "future user-playlists must not be modified")
    }

    // MARK: - V1 Queue Migration with Tracks and Signatures

    func testV1QueueMigratesSynchronizesTracksPathsAndSignatures() throws {
        let queueURL = tempDir.appendingPathComponent("playlist.json")

        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        let lowercasedPath = songFile.path.lowercased()

        let legacyRoot: [String: Any] = [
            "version": 1,
            "tracks": [
                [
                    "path": lowercasedPath,
                    "signature": [
                        "pathKey": lowercasedPath,
                        "size": 5000000,
                        "modificationTimeNanoseconds": NSNumber(value: 1700000000000000000),
                        "inode": NSNumber(value: 12345),
                        "fileResourceIdentifier": "resource-abc",
                        "volumeIdentifier": "volume-xyz"
                    ]
                ]
            ],
            "paths": [lowercasedPath],
            "currentIndex": 0
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyRoot, options: [])
        try legacyData.write(to: queueURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun)
        XCTAssertTrue(result.migrationResult.changedEntries > 0, "should migrate legacy paths")

        let migratedData = try Data(contentsOf: queueURL)
        guard let json = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any] else {
            XCTFail("Failed to parse migrated JSON")
            return
        }

        XCTAssertEqual(json["version"] as? Int, 1, "version should remain 1")

        guard let tracks = json["tracks"] as? [[String: Any]], let track0 = tracks.first else {
            XCTFail("tracks missing")
            return
        }

        let migratedTrackPath = track0["path"] as? String
        XCTAssertEqual(migratedTrackPath, songFile.path, "track.path should be case-preserved")

        if let sig = track0["signature"] as? [String: Any] {
            XCTAssertEqual(sig["pathKey"] as? String, songFile.path, "signature.pathKey should match track.path")
        }

        guard let paths = json["paths"] as? [String] else {
            XCTFail("paths missing")
            return
        }
        XCTAssertEqual(paths.first, songFile.path, "paths should match track.path")
    }

    func testV1QueuePreservesDuplicatesAndOrder() throws {
        let queueURL = tempDir.appendingPathComponent("playlist.json")

        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let fileA = musicDir.appendingPathComponent("A.mp3")
        let fileB = musicDir.appendingPathComponent("B.mp3")
        try Data().write(to: fileA)
        try Data().write(to: fileB)

        let lowercasedA = fileA.path.lowercased()
        let lowercasedB = fileB.path.lowercased()

        let duplicateRoot: [String: Any] = [
            "version": 1,
            "tracks": [
                ["path": lowercasedA],
                ["path": lowercasedB],
                ["path": lowercasedA]
            ],
            "paths": [lowercasedA, lowercasedB, lowercasedA],
            "currentIndex": 0
        ]
        let duplicateData = try JSONSerialization.data(withJSONObject: duplicateRoot, options: [])
        try duplicateData.write(to: queueURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun)

        let migratedData = try Data(contentsOf: queueURL)
        guard let json = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]],
              let paths = json["paths"] as? [String] else {
            XCTFail("Failed to parse migrated JSON")
            return
        }

        XCTAssertEqual(tracks.count, 3, "should preserve all 3 tracks including duplicate")
        XCTAssertEqual(paths.count, 3, "should preserve all 3 paths including duplicate")

        XCTAssertEqual(tracks[0]["path"] as? String, fileA.path)
        XCTAssertEqual(tracks[1]["path"] as? String, fileB.path)
        XCTAssertEqual(tracks[2]["path"] as? String, fileA.path, "duplicate should remain")
    }

    // MARK: - User Playlists Migration with Signatures

    func testUserPlaylistsMigratesPathAndSignaturePathKey() throws {
        let playlistsURL = tempDir.appendingPathComponent("user-playlists.json")

        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        let lowercasedPath = songFile.path.lowercased()

        let legacyRoot: [String: Any] = [
            "version": 1,
            "playlists": [
                [
                    "id": "12345678-1234-1234-1234-123456789012",
                    "name": "My Playlist",
                    "tracks": [
                        [
                            "path": lowercasedPath,
                            "signature": [
                                "pathKey": lowercasedPath,
                                "size": 3000000,
                                "modificationTimeNanoseconds": NSNumber(value: 1600000000000000000),
                                "inode": NSNumber(value: 99999),
                                "fileResourceIdentifier": "res-123",
                                "volumeIdentifier": "vol-abc"
                            ]
                        ]
                    ],
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                ]
            ]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyRoot, options: [])
        try legacyData.write(to: playlistsURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun)
        XCTAssertTrue(result.migrationResult.changedEntries > 0)

        let migratedData = try Data(contentsOf: playlistsURL)
        guard let json = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any],
              let playlists = json["playlists"] as? [[String: Any]],
              let playlist0 = playlists.first,
              let tracks = playlist0["tracks"] as? [[String: Any]],
              let track0 = tracks.first else {
            XCTFail("Failed to parse migrated JSON")
            return
        }

        XCTAssertEqual(track0["path"] as? String, songFile.path, "track.path should be migrated")

        if let sig = track0["signature"] as? [String: Any] {
            XCTAssertEqual(sig["pathKey"] as? String, songFile.path, "signature.pathKey should match track.path")
        }
    }

    // MARK: - Signature-Only Sync

    func testV1QueueSynchronizesStaleSignaturePathKeyWithoutPathChange() throws {
        let queueURL = tempDir.appendingPathComponent("playlist.json")

        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        // track.path is already correct, but signature.pathKey is stale
        let correctPath = songFile.path
        let stalePathKey = "/old/legacy/path.mp3"

        let staleRoot: [String: Any] = [
            "version": 1,
            "tracks": [
                [
                    "path": correctPath,
                    "signature": [
                        "pathKey": stalePathKey,
                        "size": 5000000,
                        "modificationTimeNanoseconds": NSNumber(value: 1700000000000000000),
                        "inode": NSNumber(value: 12345),
                        "fileResourceIdentifier": "resource-abc",
                        "volumeIdentifier": "volume-xyz"
                    ]
                ]
            ],
            "paths": [correctPath],
            "currentIndex": 0
        ]
        let staleData = try JSONSerialization.data(withJSONObject: staleRoot, options: [])
        try staleData.write(to: queueURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun)
        XCTAssertTrue(result.migrationResult.changedEntries > 0, "should count signature.pathKey sync")

        let migratedData = try Data(contentsOf: queueURL)
        guard let json = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]],
              let track0 = tracks.first else {
            XCTFail("Failed to parse migrated JSON")
            return
        }

        XCTAssertEqual(track0["path"] as? String, correctPath, "track.path should remain unchanged")

        guard let sig = track0["signature"] as? [String: Any] else {
            XCTFail("signature missing")
            return
        }

        XCTAssertEqual(sig["pathKey"] as? String, correctPath, "signature.pathKey should sync to track.path")
    }

    func testUserPlaylistsSynchronizesStaleSignaturePathKeyWithoutPathChange() throws {
        let playlistsURL = tempDir.appendingPathComponent("user-playlists.json")

        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        let correctPath = songFile.path
        let stalePathKey = "/old/stale/key.mp3"

        let staleRoot: [String: Any] = [
            "version": 1,
            "playlists": [
                [
                    "id": "12345678-1234-1234-1234-123456789012",
                    "name": "My Playlist",
                    "tracks": [
                        [
                            "path": correctPath,
                            "signature": [
                                "pathKey": stalePathKey,
                                "size": 3000000,
                                "modificationTimeNanoseconds": NSNumber(value: 1600000000000000000),
                                "inode": NSNumber(value: 99999),
                                "fileResourceIdentifier": "res-123",
                                "volumeIdentifier": "vol-abc"
                            ]
                        ]
                    ],
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                ]
            ]
        ]
        let staleData = try JSONSerialization.data(withJSONObject: staleRoot, options: [])
        try staleData.write(to: playlistsURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertTrue(result.didRun)
        XCTAssertTrue(result.migrationResult.changedEntries > 0, "should count signature.pathKey sync")

        let migratedData = try Data(contentsOf: playlistsURL)
        guard let json = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any],
              let playlists = json["playlists"] as? [[String: Any]],
              let playlist0 = playlists.first,
              let tracks = playlist0["tracks"] as? [[String: Any]],
              let track0 = tracks.first else {
            XCTFail("Failed to parse migrated JSON")
            return
        }

        XCTAssertEqual(track0["path"] as? String, correctPath, "track.path should remain unchanged")

        guard let sig = track0["signature"] as? [String: Any] else {
            XCTFail("signature missing")
            return
        }

        XCTAssertEqual(sig["pathKey"] as? String, correctPath, "signature.pathKey should sync to track.path")
    }

    func testFutureCacheVersionsPreventMigration() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)

        let lowercasedPath = songFile.path.lowercased()

        let testCases: [(fileName: String, futureVersion: Int, mapKey: String)] = [
            ("metadata-cache.json", 999, "entries"),
            ("duration-cache.json", 999, "entries"),
            ("volume-cache.json", 999, "entriesByPath"),
            ("playback-weights.json", 999, "queueLevels")
        ]

        for testCase in testCases {
            let fileURL = tempDir.appendingPathComponent(testCase.fileName)
            let futureRoot: [String: Any] = [
                "version": testCase.futureVersion,
                testCase.mapKey: [lowercasedPath: 42],
                "futureField": "must-preserve"
            ]
            let originalBytes = try JSONSerialization.data(withJSONObject: futureRoot, options: [])
            try originalBytes.write(to: fileURL)

            let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
                baseDirectory: tempDir,
                previousStateData: nil
            )

            XCTAssertTrue(result.didRun, "\(testCase.fileName): migration should run")

            let afterBytes = try Data(contentsOf: fileURL)
            XCTAssertEqual(afterBytes, originalBytes, "\(testCase.fileName): future version must not be modified")

            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func testVolumeV4MigratesEntriesByPathButLeavesV3RMSBytesUntouched() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)
        let lowercasedPath = songFile.path.lowercased()
        let volumeURL = tempDir.appendingPathComponent("volume-cache.json")

        let v4: [String: Any] = [
            "version": 4,
            "entriesByPath": [lowercasedPath: validVolumeV4Entry()]
        ]
        try JSONSerialization.data(withJSONObject: v4).write(to: volumeURL)
        let migrated = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )
        XCTAssertGreaterThan(migrated.migrationResult.changedEntries, 0)
        let migratedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: volumeURL)) as? [String: Any]
        )
        let entries = try XCTUnwrap(migratedRoot["entriesByPath"] as? [String: Any])
        XCTAssertNotNil(entries[songFile.path])

        let v3 = Data(
            "{\"version\":3,\"entriesByPath\":{\"\(lowercasedPath)\":{\"loudnessDb\":-12}}}".utf8
        )
        try v3.write(to: volumeURL, options: .atomic)
        _ = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )
        XCTAssertEqual(try Data(contentsOf: volumeURL), v3)
    }

    func testValidCurrentCacheAndWeightSchemasStillMigrate() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)
        let legacyPath = songFile.path.lowercased()

        let pathMapCases: [(String, String, [String: Any])] = [
            (
                "metadata-cache.json",
                "entries",
                ["version": 2, "entries": [legacyPath: validMetadataV2Entry()]]
            ),
            (
                "duration-cache.json",
                "entries",
                ["version": 3, "entries": [legacyPath: validDurationV3Entry()]]
            )
        ]

        for (fileName, mapKey, payload) in pathMapCases {
            let fileURL = tempDir.appendingPathComponent(fileName)
            try JSONSerialization.data(withJSONObject: payload).write(to: fileURL)
            let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
                baseDirectory: tempDir,
                previousStateData: nil
            )
            XCTAssertGreaterThan(result.migrationResult.changedEntries, 0, fileName)
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
            )
            let entries = try XCTUnwrap(root[mapKey] as? [String: Any])
            XCTAssertNotNil(entries[songFile.path], fileName)
            try FileManager.default.removeItem(at: fileURL)
        }

        let weightsURL = tempDir.appendingPathComponent("playback-weights.json")
        let playlistID = UUID().uuidString
        let weights: [String: Any] = [
            "version": 3,
            "queueLevels": [legacyPath: 2],
            "playlistLevels": [playlistID: [legacyPath: 3]]
        ]
        try JSONSerialization.data(withJSONObject: weights).write(to: weightsURL)
        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )
        XCTAssertGreaterThanOrEqual(result.migrationResult.changedEntries, 2)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: weightsURL)) as? [String: Any]
        )
        let queueLevels = try XCTUnwrap(root["queueLevels"] as? [String: Any])
        let playlistLevels = try XCTUnwrap(root["playlistLevels"] as? [String: Any])
        let playlistMap = try XCTUnwrap(playlistLevels[playlistID] as? [String: Any])
        XCTAssertNotNil(queueLevels[songFile.path])
        XCTAssertNotNil(playlistMap[songFile.path])
    }

    func testV2UserPlaylistsPreservesSamePathTracksWithDistinctIDs() throws {
        let playlistsURL = tempDir.appendingPathComponent("user-playlists.json")
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)
        let legacyPath = songFile.path.lowercased()
        let firstID = UUID()
        let secondID = UUID()
        let root: [String: Any] = [
            "version": 2,
            "storeRevision": 4,
            "pendingCleanup": [],
            "playlists": [[
                "id": UUID().uuidString,
                "name": "Duplicates",
                "tracks": [
                    ["id": firstID.uuidString, "path": legacyPath],
                    ["id": secondID.uuidString, "path": legacyPath]
                ],
                "createdAt": 1_700_000_000.0,
                "updatedAt": 1_700_000_000.0
            ]]
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: playlistsURL)

        let result = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )

        XCTAssertEqual(result.migrationResult.failedFiles, [])
        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: playlistsURL)) as? [String: Any]
        )
        let playlists = try XCTUnwrap(migrated["playlists"] as? [[String: Any]])
        let tracks = try XCTUnwrap(playlists.first?["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.compactMap { $0["id"] as? String }, [firstID.uuidString, secondID.uuidString])
        XCTAssertEqual(tracks.compactMap { $0["path"] as? String }, [songFile.path, songFile.path])
    }

    func testMalformedKnownSchemasRemainByteForByteUnchanged() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)
        let legacyPath = songFile.path.lowercased()
        let playlistID = UUID().uuidString
        let duplicateTrackID = UUID().uuidString

        try assertMigrationPreserves(
            Data("{\"version\":2,\"tracks\":[".utf8),
            fileName: "playlist.json"
        )

        let cases: [(String, [String: Any])] = [
            (
                "metadata-cache.json",
                ["version": 2, "entries": [legacyPath: ["title": "incomplete"]]]
            ),
            (
                "duration-cache.json",
                ["version": 3, "entries": [legacyPath: ["durationSeconds": 180.0]]]
            ),
            (
                "volume-cache.json",
                ["version": 4, "entriesByPath": [legacyPath: ["algorithmVersion": 2]]]
            ),
            (
                "playback-weights.json",
                [
                    "version": 3,
                    "queueLevels": [legacyPath: 1],
                    "playlistLevels": [playlistID: [legacyPath: "invalid"]]
                ]
            ),
            (
                "playlist.json",
                [
                    "version": 2,
                    "tracks": [["path": legacyPath]],
                    "paths": [legacyPath + ".different"],
                    "currentIndex": 0
                ]
            ),
            (
                "user-playlists.json",
                [
                    "version": 2,
                    "storeRevision": 1,
                    "playlists": [[
                        "id": playlistID,
                        "name": "Duplicate IDs",
                        "tracks": [
                            ["id": duplicateTrackID, "path": legacyPath],
                            ["id": duplicateTrackID, "path": legacyPath]
                        ],
                        "createdAt": 100.0,
                        "updatedAt": 101.0
                    ]],
                    "pendingCleanup": []
                ]
            )
        ]

        for (fileName, payload) in cases {
            try assertMigrationPreserves(payload, fileName: fileName)
        }
    }

    func testMissingZeroAndNegativeVersionsRemainByteForByteUnchanged() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)
        let legacyPath = songFile.path.lowercased()
        let playlistID = UUID().uuidString

        let basePayloads: [(String, [String: Any])] = [
            ("metadata-cache.json", ["entries": [legacyPath: validMetadataV2Entry()]]),
            ("duration-cache.json", ["entries": [legacyPath: validDurationV3Entry()]]),
            ("volume-cache.json", ["entriesByPath": [legacyPath: validVolumeV4Entry()]]),
            (
                "playback-weights.json",
                ["queueLevels": [legacyPath: 1], "playlistLevels": [playlistID: [legacyPath: 2]]]
            ),
            (
                "playlist.json",
                ["tracks": [["path": legacyPath]], "paths": [], "currentIndex": 0]
            ),
            (
                "user-playlists.json",
                [
                    "storeRevision": 1,
                    "playlists": [[
                        "id": playlistID,
                        "name": "Version check",
                        "tracks": [["id": UUID().uuidString, "path": legacyPath]],
                        "createdAt": 100.0,
                        "updatedAt": 101.0
                    ]],
                    "pendingCleanup": []
                ]
            )
        ]

        for (fileName, basePayload) in basePayloads {
            try assertMigrationPreserves(basePayload, fileName: fileName)
            for invalidVersion in [0, -1] {
                var payload = basePayload
                payload["version"] = invalidVersion
                try assertMigrationPreserves(payload, fileName: fileName)
            }
        }
    }

    func testCapacityViolationsRemainByteForByteUnchanged() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        let songFile = musicDir.appendingPathComponent("Song.mp3")
        try Data("audio".utf8).write(to: songFile)
        let legacyPath = songFile.path.lowercased()

        var metadataEntries: [String: Any] = [legacyPath: validMetadataV2Entry()]
        for index in 0 ..< 8_192 {
            metadataEntries["/over-limit/track-\(index).mp3"] = validMetadataV2Entry()
        }
        try assertMigrationPreserves(
            ["version": 2, "entries": metadataEntries],
            fileName: "metadata-cache.json"
        )

        var playlistLevels: [String: Any] = [:]
        for _ in 0 ..< 2_001 {
            playlistLevels[UUID().uuidString] = [:]
        }
        try assertMigrationPreserves(
            [
                "version": 3,
                "queueLevels": [legacyPath: 1],
                "playlistLevels": playlistLevels
            ],
            fileName: "playback-weights.json"
        )

        let rekeys: [[String: Any]] = (0 ..< 4_097).map { _ in
            ["oldPath": legacyPath, "newPath": legacyPath]
        }
        try assertMigrationPreserves(
            [
                "version": 2,
                "tracks": [["path": legacyPath]],
                "paths": [],
                "currentIndex": 0,
                "pendingWeightRekeys": rekeys
            ],
            fileName: "playlist.json"
        )

        let playlists: [[String: Any]] = (0 ..< 2_001).map { index in
            [
                "id": UUID().uuidString,
                "name": "Playlist \(index)",
                "tracks": index == 0 ? [["id": UUID().uuidString, "path": legacyPath]] : [],
                "createdAt": 100.0,
                "updatedAt": 101.0
            ]
        }
        try assertMigrationPreserves(
            [
                "version": 2,
                "storeRevision": 1,
                "playlists": playlists,
                "pendingCleanup": []
            ],
            fileName: "user-playlists.json"
        )
    }

    func testRelativeAndNULPathsRemainByteForByteUnchanged() throws {
        let invalidRelativePath = "relative/song.mp3"
        let invalidNULPath = "/music/bad\u{0}song.mp3"
        let playlistID = UUID().uuidString

        let cases: [(String, [String: Any])] = [
            (
                "metadata-cache.json",
                ["version": 2, "entries": [invalidRelativePath: validMetadataV2Entry()]]
            ),
            (
                "duration-cache.json",
                ["version": 3, "entries": [invalidNULPath: validDurationV3Entry()]]
            ),
            (
                "volume-cache.json",
                ["version": 4, "entriesByPath": [invalidRelativePath: validVolumeV4Entry()]]
            ),
            (
                "playback-weights.json",
                [
                    "version": 3,
                    "queueLevels": [invalidNULPath: 1],
                    "playlistLevels": [playlistID: [:]]
                ]
            ),
            (
                "playlist.json",
                [
                    "version": 2,
                    "tracks": [["path": invalidRelativePath]],
                    "paths": [],
                    "currentIndex": 0
                ]
            ),
            (
                "user-playlists.json",
                [
                    "version": 2,
                    "storeRevision": 1,
                    "playlists": [[
                        "id": playlistID,
                        "name": "Bad path",
                        "tracks": [["id": UUID().uuidString, "path": invalidNULPath]],
                        "createdAt": 100.0,
                        "updatedAt": 101.0
                    ]],
                    "pendingCleanup": []
                ]
            )
        ]

        for (fileName, payload) in cases {
            try assertMigrationPreserves(payload, fileName: fileName)
        }
    }

    func testSymlinkedTrackedFileIsSkippedAndCheckpointConverges() throws {
        let target = tempDir.appendingPathComponent("outside.json")
        let link = tempDir.appendingPathComponent("metadata-cache.json")
        let original = Data("{\"version\":2,\"entries\":{}}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let first = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: nil
        )
        XCTAssertTrue(first.didRun)
        XCTAssertEqual(first.migrationResult.failedFiles, [])
        XCTAssertEqual(try Data(contentsOf: target), original)

        let second = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
            baseDirectory: tempDir,
            previousStateData: first.savedStateData
        )
        XCTAssertFalse(second.didRun)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
