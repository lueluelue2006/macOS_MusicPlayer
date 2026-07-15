import XCTest
@testable import MusicPlayer

@MainActor
final class VersionedPersistenceCodecTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionedPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Legacy Queue Compatibility

    func testLoadLegacyQueueWithoutVersionAndRecords() async throws {
        let queueURL = tempDir.appendingPathComponent("queue.json")
        let file1 = tempDir.appendingPathComponent("one.mp3")
        let file2 = tempDir.appendingPathComponent("two.mp3")
        try Data("audio1".utf8).write(to: file1)
        try Data("audio2".utf8).write(to: file2)

        let legacyJSON = """
        {
            "paths": ["\(file1.path)", "\(file2.path)"],
            "currentIndex": 1
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: queueURL)

        let manager = PlaylistManager(playlistFileURLOverride: queueURL, disablePersistence: false)
        await manager.loadSavedPlaylist()
        await manager.waitForBackgroundRestoreWorkForTesting()

        XCTAssertEqual(manager.audioFiles.count, 2, "legacy queue should load both files")
        XCTAssertEqual(manager.audioFiles[0].url.path, file1.path)
        XCTAssertEqual(manager.audioFiles[1].url.path, file2.path)
        XCTAssertEqual(manager.currentIndex, 1)
    }

    // MARK: - Legacy UserPlaylists Compatibility

    func testLoadLegacyUserPlaylistsWithoutSignature() async throws {
        let storeURL = tempDir.appendingPathComponent("playlists.json")
        let legacyJSON = """
        {
            "version": 1,
            "playlists": [
                {
                    "id": "12345678-1234-1234-1234-123456789012",
                    "name": "Legacy",
                    "tracks": [{"path": "/music/song.mp3"}],
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                }
            ]
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: storeURL)

        let store = PlaylistsStore(playlistsFileURLOverride: storeURL)
        await store.ensureLoaded()

        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.playlists[0].name, "Legacy")
        XCTAssertEqual(store.playlists[0].tracks.count, 1)
        XCTAssertEqual(store.playlists[0].tracks[0].path, "/music/song.mp3")
    }

    // MARK: - Queue with Signatures

    func testSaveQueueWithSignatureWritesVersionRecordsAndLegacyPaths() async throws {
        let queueURL = tempDir.appendingPathComponent("queue.json")
        let file1 = tempDir.appendingPathComponent("one.mp3")
        try Data("audio1".utf8).write(to: file1)

        let currentJSON = """
        {
            "version": 1,
            "tracks": [
                {
                    "path": "\(file1.path)",
                    "signature": {
                        "pathKey": "/canonical/one.mp3",
                        "size": 5000000,
                        "modificationTimeNanoseconds": 1700000000000000000,
                        "inode": 12345,
                        "fileResourceIdentifier": "resource-abc",
                        "volumeIdentifier": "volume-xyz"
                    }
                }
            ],
            "paths": ["\(file1.path)"],
            "currentIndex": 0
        }
        """
        try currentJSON.data(using: .utf8)!.write(to: queueURL)

        let manager = PlaylistManager(playlistFileURLOverride: queueURL, disablePersistence: false)
        await manager.loadSavedPlaylist()
        await manager.waitForBackgroundRestoreWorkForTesting()
        manager.flushPlaylistPersistence()

        let savedData = try Data(contentsOf: queueURL)
        guard let json = try JSONSerialization.jsonObject(with: savedData) as? [String: Any] else {
            XCTFail("Failed to decode saved JSON as dictionary")
            return
        }

        XCTAssertEqual(json["version"] as? Int, 1, "should write version field")

        guard let tracks = json["tracks"] as? [[String: Any]] else {
            XCTFail("tracks field missing or wrong type")
            return
        }
        XCTAssertEqual(tracks.count, 1)

        guard let track0 = tracks.first else {
            XCTFail("tracks array is empty")
            return
        }

        guard let sig = track0["signature"] as? [String: Any] else {
            XCTFail("signature missing in track 0")
            return
        }

        XCTAssertEqual(sig["pathKey"] as? String, "/canonical/one.mp3")
        XCTAssertEqual((sig["size"] as? NSNumber)?.int64Value, 5000000)
        XCTAssertEqual((sig["modificationTimeNanoseconds"] as? NSNumber)?.int64Value, 1700000000000000000)
        XCTAssertEqual((sig["inode"] as? NSNumber)?.uint64Value, 12345)
        XCTAssertEqual(sig["fileResourceIdentifier"] as? String, "resource-abc")
        XCTAssertEqual(sig["volumeIdentifier"] as? String, "volume-xyz")

        XCTAssertNotNil(json["paths"], "should write legacy paths for backward compat")
    }

    // MARK: - Future Schema Write Protection

    func testFutureQueueVersionPreventsSaveOverwrite() async throws {
        let queueURL = tempDir.appendingPathComponent("future-queue.json")
        let futureJSON = """
        {
            "version": 99,
            "tracks": [{"path": "/future/song.mp3"}],
            "paths": ["/future/song.mp3"],
            "currentIndex": 0,
            "futureField": "must-preserve"
        }
        """
        let originalBytes = futureJSON.data(using: .utf8)!
        try originalBytes.write(to: queueURL)

        let toastExpectation = expectation(forNotification: .showAppToast, object: nil) { notification in
            guard let userInfo = notification.userInfo,
                  let title = userInfo["title"] as? String else { return false }
            return title.contains("版本过新")
        }

        let manager = PlaylistManager(playlistFileURLOverride: queueURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        await fulfillment(of: [toastExpectation], timeout: 1.0)

        manager.currentIndex = 999
        manager.flushPlaylistPersistence()

        let afterFlush = try Data(contentsOf: queueURL)
        XCTAssertEqual(afterFlush, originalBytes, "future schema file must not be overwritten")
    }

    func testFutureUserPlaylistsVersionPreventsCreateAndFlush() async throws {
        let storeURL = tempDir.appendingPathComponent("future-playlists.json")
        let futureJSON = """
        {
            "version": 99,
            "playlists": [
                {
                    "id": "12345678-1234-1234-1234-123456789012",
                    "name": "Future",
                    "tracks": [{"path": "/future/song.mp3"}],
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                }
            ],
            "futureStoreField": 123
        }
        """
        let originalBytes = futureJSON.data(using: .utf8)!
        try originalBytes.write(to: storeURL)

        let toastExpectation = expectation(forNotification: .showAppToast, object: nil) { notification in
            guard let userInfo = notification.userInfo,
                  let title = userInfo["title"] as? String else { return false }
            return title.contains("版本过新")
        }

        let store = PlaylistsStore(playlistsFileURLOverride: storeURL)
        await store.ensureLoaded()

        await fulfillment(of: [toastExpectation], timeout: 1.0)

        let testFile = tempDir.appendingPathComponent("test.mp3")
        try Data().write(to: testFile)
        _ = await store.createPlaylist(name: "New", trackURLs: [testFile])
        store.flushPersistence()

        let afterFlush = try Data(contentsOf: storeURL)
        XCTAssertEqual(afterFlush, originalBytes, "future schema store must not be overwritten")
    }

    // MARK: - Missing Record Preservation

    func testMissingRecordSurvivesLoadSaveRoundTrip() async throws {
        let queueURL = tempDir.appendingPathComponent("queue-missing.json")
        let existingFile = tempDir.appendingPathComponent("exists.mp3")
        try Data("audio".utf8).write(to: existingFile)

        let currentJSON = """
        {
            "version": 1,
            "tracks": [
                {"path": "\(existingFile.path)"},
                {
                    "path": "/nonexistent/missing.mp3",
                    "signature": {
                        "pathKey": "/canonical/missing.mp3",
                        "size": 3000000,
                        "modificationTimeNanoseconds": 1600000000000000000,
                        "inode": 99999,
                        "fileResourceIdentifier": "missing-resource",
                        "volumeIdentifier": "volume-abc"
                    }
                }
            ],
            "paths": ["\(existingFile.path)", "/nonexistent/missing.mp3"],
            "currentIndex": 0
        }
        """
        try currentJSON.data(using: .utf8)!.write(to: queueURL)

        let manager = PlaylistManager(playlistFileURLOverride: queueURL, disablePersistence: false)
        await manager.loadSavedPlaylist()
        await manager.waitForBackgroundRestoreWorkForTesting()
        manager.flushPlaylistPersistence()

        let finalData = try Data(contentsOf: queueURL)
        guard let finalJSON = try JSONSerialization.jsonObject(with: finalData) as? [String: Any] else {
            XCTFail("Failed to decode final JSON")
            return
        }

        guard let finalTracks = finalJSON["tracks"] as? [[String: Any]] else {
            XCTFail("tracks field missing or wrong type")
            return
        }

        guard let missingRecord = finalTracks.first(where: { ($0["path"] as? String) == "/nonexistent/missing.mp3" }) else {
            XCTFail("missing record must survive load→save→load cycle")
            return
        }

        guard let missingSig = missingRecord["signature"] as? [String: Any] else {
            XCTFail("missing record signature must be preserved")
            return
        }

        XCTAssertEqual(missingSig["fileResourceIdentifier"] as? String, "missing-resource")
        XCTAssertEqual(missingSig["volumeIdentifier"] as? String, "volume-abc")
    }

    // MARK: - Corrupted File Preservation

    func testCorruptedQueuePreservesOriginalBytes() async throws {
        let queueURL = tempDir.appendingPathComponent("corrupted.json")
        let corruptedJSON = """
        {
            "paths": "not-an-array",
            "currentIndex": 0
        }
        """
        let originalBytes = corruptedJSON.data(using: .utf8)!
        try originalBytes.write(to: queueURL)

        let manager = PlaylistManager(playlistFileURLOverride: queueURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        if FileManager.default.fileExists(atPath: queueURL.path) {
            // Original file preserved in place
            let preservedData = try Data(contentsOf: queueURL)
            XCTAssertEqual(preservedData, originalBytes, "original file must be unchanged")
        } else {
            // File moved to quarantine; enumerate siblings with .corrupted prefix
            let parentDir = queueURL.deletingLastPathComponent()
            let baseName = queueURL.deletingPathExtension().lastPathComponent
            let contents = try FileManager.default.contentsOfDirectory(atPath: parentDir.path)
            let quarantineCandidates = contents.filter { $0.hasPrefix("\(baseName).corrupted") }

            guard !quarantineCandidates.isEmpty else {
                XCTFail("neither original nor quarantine file exists")
                return
            }

            var foundMatch = false
            for candidate in quarantineCandidates {
                let candidateURL = parentDir.appendingPathComponent(candidate)
                if let data = try? Data(contentsOf: candidateURL), data == originalBytes {
                    foundMatch = true
                    break
                }
            }

            XCTAssertTrue(foundMatch, "at least one quarantine candidate must contain original bytes")
        }
    }
}
