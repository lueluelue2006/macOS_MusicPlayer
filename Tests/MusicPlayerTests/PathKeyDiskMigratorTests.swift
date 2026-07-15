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
            ("volume-cache.json", 999, "loudnessDbByPath"),
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
}
