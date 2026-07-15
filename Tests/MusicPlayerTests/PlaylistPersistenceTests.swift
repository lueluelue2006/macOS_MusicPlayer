import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistPersistenceTests: XCTestCase {
    private struct SavedPlaylist: Decodable {
        let paths: [String]
        let currentIndex: Int
    }

    private struct SavedUserPlaylists: Codable {
        let version: Int
        let playlists: [UserPlaylist]
    }

    private func makeAudioFile(at url: URL, title: String) -> AudioFile {
        AudioFile(
            url: url,
            metadata: AudioMetadata(
                title: title,
                artist: "test",
                album: "test",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )
    }

    private func readSnapshot(at url: URL) throws -> SavedPlaylist {
        try JSONDecoder().decode(SavedPlaylist.self, from: Data(contentsOf: url))
    }

    func testSequentialNavigationPersistsCurrentIndexAfterDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlist-persistence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            persistenceDebounceInterval: 0.05
        )
        manager.audioFiles = [
            makeAudioFile(at: directory.appendingPathComponent("one.mp3"), title: "one"),
            makeAudioFile(at: directory.appendingPathComponent("two.mp3"), title: "two")
        ]
        manager.currentIndex = 0

        XCTAssertEqual(manager.nextFile(isShuffling: false)?.metadata.title, "two")
        let didPersist = await waitUntil(timeout: 1) {
            (try? self.readSnapshot(at: playlistURL))?.currentIndex == 1
        }
        XCTAssertTrue(didPersist)

        let snapshot = try readSnapshot(at: playlistURL)
        XCTAssertEqual(snapshot.currentIndex, 1)
        XCTAssertEqual(snapshot.paths, manager.audioFiles.map { $0.url.path })
    }

    func testFlushWinsOverAlreadyScheduledOlderSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlist-flush-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            persistenceDebounceInterval: 0.05
        )
        manager.audioFiles = [
            makeAudioFile(at: directory.appendingPathComponent("one.mp3"), title: "one"),
            makeAudioFile(at: directory.appendingPathComponent("two.mp3"), title: "two"),
            makeAudioFile(at: directory.appendingPathComponent("three.mp3"), title: "three")
        ]

        manager.currentIndex = 0
        manager.savePlaylist()
        manager.currentIndex = 1
        manager.savePlaylist()
        manager.currentIndex = 2
        manager.flushPlaylistPersistence()

        // Let both delayed closures become eligible. Neither may overwrite flush.
        try await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try readSnapshot(at: playlistURL)
        XCTAssertEqual(snapshot.currentIndex, 2)
        XCTAssertEqual(snapshot.paths, manager.audioFiles.map { $0.url.path })
    }

    func testUserPlaylistFlushPersistsLatestQueuedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-user-playlists-flush-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("user-playlists.json")
        let store = PlaylistsStore(playlistsFileURLOverride: storeURL)
        await store.ensureLoaded()
        _ = store.createEmptyPlaylist(name: "artist")
        let playlistID = try XCTUnwrap(store.playlists.first?.id)
        let trackURLs = [
            directory.appendingPathComponent("one.mp3"),
            directory.appendingPathComponent("two.mp3"),
        ]
        _ = await store.addTracks(trackURLs, to: playlistID)

        store.flushPersistence()

        let saved = try JSONDecoder().decode(
            SavedUserPlaylists.self,
            from: Data(contentsOf: storeURL)
        )
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.playlists.count, 1)
        XCTAssertEqual(saved.playlists[0].id, playlistID)
        XCTAssertEqual(saved.playlists[0].tracks.map(\.path), trackURLs.map(\.path))
    }

    func testUserPlaylistFlushDoesNotOverwritePendingInitialLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-user-playlists-pending-load-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("user-playlists.json")
        let existing = UserPlaylist(
            name: "existing",
            tracks: [.init(path: directory.appendingPathComponent("kept.mp3").path)]
        )
        let originalData = try JSONEncoder().encode(
            SavedUserPlaylists(version: 1, playlists: [existing])
        )
        try originalData.write(to: storeURL, options: .atomic)

        let store = PlaylistsStore(playlistsFileURLOverride: storeURL)
        store.loadIfNeeded()
        XCTAssertFalse(store.isReady)
        store.flushPersistence()
        XCTAssertEqual(try Data(contentsOf: storeURL), originalData)

        await store.ensureLoaded()
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.playlists, [existing])
    }

    func testMissingRecordsPreserveRelativeOrderWithExisting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-missing-order-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileA = directory.appendingPathComponent("a.mp3")
        let fileB = directory.appendingPathComponent("b.mp3")
        let fileC = directory.appendingPathComponent("c.mp3")
        try Data("a".utf8).write(to: fileA)
        try Data("c".utf8).write(to: fileC)

        let playlistURL = directory.appendingPathComponent("queue.json")
        let savedJSON = """
        {
            "version": 1,
            "tracks": [
                {"path": "\(fileA.path)", "signature": null},
                {"path": "\(fileB.path)", "signature": null},
                {"path": "\(fileC.path)", "signature": null}
            ],
            "paths": ["\(fileA.path)", "\(fileB.path)", "\(fileC.path)"],
            "currentIndex": 0
        }
        """
        try savedJSON.write(to: playlistURL, atomically: true, encoding: .utf8)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        XCTAssertEqual(manager.audioFiles.count, 2, "Should load only existing files")
        XCTAssertEqual(manager.audioFiles[0].url.path, fileA.path)
        XCTAssertEqual(manager.audioFiles[1].url.path, fileC.path)

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = json["paths"] as? [String] else {
            XCTFail("Failed to read persisted playlist")
            return
        }

        XCTAssertEqual(paths, [fileA.path, fileB.path, fileC.path], "Should preserve original order including missing")
    }

    func testCurrentIndexMapsCorrectlyWhenMissingItemsBeforeCurrent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-index-map-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileA = directory.appendingPathComponent("a.mp3")
        let fileB = directory.appendingPathComponent("b.mp3")
        let fileC = directory.appendingPathComponent("c.mp3")
        let fileD = directory.appendingPathComponent("d.mp3")
        try Data("a".utf8).write(to: fileA)
        try Data("c".utf8).write(to: fileC)
        try Data("d".utf8).write(to: fileD)

        let playlistURL = directory.appendingPathComponent("queue-index.json")
        let savedJSON = """
        {
            "version": 1,
            "tracks": [
                {"path": "\(fileA.path)", "signature": null},
                {"path": "\(fileB.path)", "signature": null},
                {"path": "\(fileC.path)", "signature": null},
                {"path": "\(fileD.path)", "signature": null}
            ],
            "paths": ["\(fileA.path)", "\(fileB.path)", "\(fileC.path)", "\(fileD.path)"],
            "currentIndex": 2
        }
        """
        try savedJSON.write(to: playlistURL, atomically: true, encoding: .utf8)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        XCTAssertEqual(manager.audioFiles.count, 3)
        XCTAssertEqual(manager.currentIndex, 1, "currentIndex 2 in full list (fileC) should map to index 1 in available files")
        XCTAssertEqual(manager.audioFiles[manager.currentIndex].url.path, fileC.path)

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedIndex = json["currentIndex"] as? Int else {
            XCTFail("Failed to read persisted currentIndex")
            return
        }

        XCTAssertEqual(savedIndex, 2, "Persisted currentIndex should remain in full list coordinates")
    }

    func testDuplicatePathPreservesSecondOccurrenceAsCurrentIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-duplicate-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileA = directory.appendingPathComponent("a.mp3")
        let fileB = directory.appendingPathComponent("b.mp3")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)

        let playlistURL = directory.appendingPathComponent("queue-dup.json")
        let savedJSON = """
        {
            "version": 1,
            "tracks": [
                {"path": "\(fileA.path)", "signature": null},
                {"path": "\(fileB.path)", "signature": null},
                {"path": "\(fileA.path)", "signature": null}
            ],
            "paths": ["\(fileA.path)", "\(fileB.path)", "\(fileA.path)"],
            "currentIndex": 2
        }
        """
        try savedJSON.write(to: playlistURL, atomically: true, encoding: .utf8)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        XCTAssertEqual(manager.audioFiles.count, 3)
        XCTAssertEqual(manager.currentIndex, 2, "Should point to second occurrence of fileA")
        XCTAssertEqual(manager.audioFiles[2].url.path, fileA.path)

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedIndex = json["currentIndex"] as? Int else {
            XCTFail("Failed to read persisted currentIndex")
            return
        }

        XCTAssertEqual(savedIndex, 2, "Should still point to second occurrence slot after flush")
    }

    func testMissingCurrentItemSelectsNextAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-missing-current-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileA = directory.appendingPathComponent("a.mp3")
        let fileB = directory.appendingPathComponent("b.mp3")
        let fileC = directory.appendingPathComponent("c.mp3")
        let fileD = directory.appendingPathComponent("d.mp3")
        try Data("a".utf8).write(to: fileA)
        try Data("c".utf8).write(to: fileC)
        try Data("d".utf8).write(to: fileD)

        let playlistURL = directory.appendingPathComponent("queue-missing-current.json")
        let savedJSON = """
        {
            "version": 1,
            "tracks": [
                {"path": "\(fileA.path)", "signature": null},
                {"path": "\(fileB.path)", "signature": null},
                {"path": "\(fileC.path)", "signature": null},
                {"path": "\(fileD.path)", "signature": null}
            ],
            "paths": ["\(fileA.path)", "\(fileB.path)", "\(fileC.path)", "\(fileD.path)"],
            "currentIndex": 1
        }
        """
        try savedJSON.write(to: playlistURL, atomically: true, encoding: .utf8)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        XCTAssertEqual(manager.audioFiles.count, 3)
        XCTAssertEqual(manager.currentIndex, 1, "Should select fileC (first available after missing fileB)")
        XCTAssertEqual(manager.audioFiles[1].url.path, fileC.path)

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedIndex = json["currentIndex"] as? Int else {
            XCTFail("Failed to read persisted currentIndex")
            return
        }

        XCTAssertEqual(savedIndex, 2, "Should persist full-order index of fileC")
    }

    func testRemoveFileAlsoClearsLoadedSignature() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-remove-sig-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileA = directory.appendingPathComponent("a.mp3")
        try Data("original".utf8).write(to: fileA)

        let playlistURL = directory.appendingPathComponent("queue-sig.json")
        let savedJSON = """
        {
            "version": 1,
            "tracks": [
                {
                    "path": "\(fileA.path)",
                    "signature": {
                        "pathKey": "\(fileA.path)",
                        "size": 100,
                        "modificationTimeNanoseconds": 1000000000,
                        "inode": 12345,
                        "fileResourceIdentifier": "old-resource",
                        "volumeIdentifier": "old-volume"
                    }
                }
            ],
            "paths": ["\(fileA.path)"],
            "currentIndex": 0
        }
        """
        try savedJSON.write(to: playlistURL, atomically: true, encoding: .utf8)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL, disablePersistence: false)
        await manager.loadSavedPlaylist()

        XCTAssertEqual(manager.audioFiles.count, 1)

        manager.removeFile(at: 0)

        manager.flushPlaylistPersistence()

        let noSigFile = makeAudioFile(at: fileA, title: "new")
        _ = manager.ensureInQueue([noSigFile], focusURL: nil, signatures: [:])

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]],
              let track = tracks.first else {
            XCTFail("Failed to read persisted playlist")
            return
        }

        XCTAssertNil(track["signature"], "Signature should not be persisted after remove+re-add without signature")
    }

    func testCorruptedUserPlaylistsQuarantinedAndOriginalPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-corrupt-playlists-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("user-playlists.json")
        let corruptedJSON = """
        {
            "version": 1,
            "playlists": [
                {
                    "id": "not-a-uuid",
                    "name": "Broken"
                }
            ]
        }
        """
        let originalBytes = Data(corruptedJSON.utf8)
        try originalBytes.write(to: storeURL)

        let toastExpectation = expectation(forNotification: .showAppToast, object: nil) { notification in
            guard let userInfo = notification.userInfo,
                  let title = userInfo["title"] as? String else { return false }
            return title.contains("损坏")
        }

        let store = PlaylistsStore(playlistsFileURLOverride: storeURL)
        await store.ensureLoaded()

        await fulfillment(of: [toastExpectation], timeout: 1.0)

        XCTAssertTrue(store.isPersistenceReadOnly, "Corrupted store should enter read-only mode")
        XCTAssertTrue(store.playlists.isEmpty, "Corrupted store should not load playlists")

        let dirContents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let quarantineCandidates = dirContents.filter { $0.lastPathComponent.hasPrefix("user-playlists.corrupted.") }
        XCTAssertFalse(quarantineCandidates.isEmpty, "At least one quarantine file should exist")

        let matchingQuarantine = quarantineCandidates.first { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return data == originalBytes
        }
        XCTAssertNotNil(matchingQuarantine, "Quarantine file should preserve original corrupted bytes")

        let preservedBytes = try Data(contentsOf: storeURL)
        XCTAssertEqual(preservedBytes, originalBytes, "Original file should remain unchanged after load")

        _ = store.createEmptyPlaylist(name: "Test")
        store.flushPersistence()

        let afterFlushBytes = try Data(contentsOf: storeURL)
        XCTAssertEqual(afterFlushBytes, originalBytes, "Original file must not be overwritten in read-only mode")
    }

    func testIPCReadOnlyRejectionHelper() {
        let reply = IPCServer.makeReadOnlyRejection(requestID: "test-123")
        XCTAssertEqual(reply.id, "test-123")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.message, "playlists store is read-only")
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
}
