import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistPersistenceTests: XCTestCase {
    private struct SavedPlaylist: Decodable {
        private struct Track: Decodable {
            let path: String
        }

        let paths: [String]
        let currentIndex: Int

        private enum CodingKeys: String, CodingKey {
            case tracks
            case paths
            case currentIndex
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
            let legacyPaths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
            paths = tracks.isEmpty ? legacyPaths : tracks.map(\.path)
            currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        }
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

    func testLibraryDatabaseNavigationUpdatesOnlyCursorAndPreservesOccurrences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-library-queue-cursor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try LibraryDatabase(
            fileURL: directory.appendingPathComponent("Library.sqlite")
        )
        let manager = PlaylistManager(
            libraryDatabase: database,
            persistenceDebounceInterval: 0,
            initialQueueLoadState: .ready
        )
        let firstURL = directory.appendingPathComponent("first.mp3")
        let secondURL = directory.appendingPathComponent("second.mp3")
        _ = manager.ensureInQueue([
            makeAudioFile(at: firstURL, title: "first"),
            makeAudioFile(at: secondURL, title: "second"),
        ])
        XCTAssertTrue(manager.flushPlaylistPersistence().isDurable)
        let structural = try database.loadQueue()
        XCTAssertEqual(structural.entries.count, 2)

        XCTAssertEqual(manager.selectFile(at: 1)?.url, secondURL)
        XCTAssertTrue(manager.flushPlaylistPersistence().isDurable)
        let navigated = try database.loadQueue()

        XCTAssertEqual(navigated.revision, structural.revision)
        XCTAssertEqual(navigated.entries, structural.entries)
        XCTAssertEqual(navigated.currentEntryID, structural.entries[1].id)
    }

    func testLibraryDatabaseQueueRestoresStableOccurrenceIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-library-queue-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp3")
        let secondURL = directory.appendingPathComponent("second.mp3")
        try Data().write(to: firstURL)
        try Data().write(to: secondURL)

        let database = try LibraryDatabase(
            fileURL: directory.appendingPathComponent("Library.sqlite")
        )
        let entries = [
            LibraryQueueEntry(
                id: UUID(), sortKey: 0, path: firstURL.path,
                signature: nil, locationID: nil, relativePath: nil
            ),
            LibraryQueueEntry(
                id: UUID(), sortKey: 1_024, path: secondURL.path,
                signature: nil, locationID: nil, relativePath: nil
            ),
        ]
        try database.replaceQueue(
            LibraryQueueSnapshot(
                revision: 12,
                entries: entries,
                currentEntryID: entries[1].id,
                pendingRekeys: []
            )
        )
        let manager = PlaylistManager(
            libraryDatabase: database,
            initialQueueLoadState: .ready
        )
        await manager.loadSavedPlaylist()

        XCTAssertEqual(manager.audioFiles.map(\.url), [firstURL, secondURL])
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertTrue(manager.flushPlaylistPersistence().isDurable)
        XCTAssertEqual(try database.loadQueue().entries.map(\.id), entries.map(\.id))
        await manager.waitForBackgroundRestoreWorkForTesting()
    }

    func testFlushBeforeInitialRestorePreservesExistingQueueBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-quick-quit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let original = Data(#"{"version":1,"tracks":[],"paths":["/keep/me.mp3"],"currentIndex":0}"#.utf8)
        try original.write(to: playlistURL)

        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            initialQueueLoadState: .notStarted
        )
        manager.flushPlaylistPersistence()

        XCTAssertEqual(try Data(contentsOf: playlistURL), original)
        XCTAssertEqual(manager.queueLoadState, .notStarted)
    }

    func testFutureQueueSchemaIsPreservedByteForByteAndNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-future-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let original = Data(#"{"version":99,"tracks":[],"paths":["/future.mp3"],"currentIndex":0,"future":{"keep":true}}"#.utf8)
        try original.write(to: playlistURL)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        await manager.loadSavedPlaylist()
        manager.audioFiles = [makeAudioFile(at: directory.appendingPathComponent("replacement.mp3"), title: "replacement")]
        manager.flushPlaylistPersistence()

        XCTAssertEqual(try Data(contentsOf: playlistURL), original)
    }

    func testNonPositiveExplicitQueueVersionsAreProtectedByteForByte() async throws {
        for version in [0, -1] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "musicplayer-queue-invalid-version-\(version)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let playlistURL = directory.appendingPathComponent("playlist.json")
            let original = Data(
                "{\"version\":\(version),\"tracks\":[],\"paths\":[\"/keep.mp3\"],\"currentIndex\":0}".utf8
            )
            try original.write(to: playlistURL)

            let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
            await manager.loadSavedPlaylist()
            manager.audioFiles = [
                makeAudioFile(
                    at: directory.appendingPathComponent("replacement.mp3"),
                    title: "replacement"
                )
            ]
            manager.flushPlaylistPersistence()

            XCTAssertEqual(try Data(contentsOf: playlistURL), original)
        }
    }

    func testCorruptQueueKeepsOriginalAndWritesBoundedDiagnosticCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-corrupt-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let original = Data(#"{"version":1,"tracks":["broken""#.utf8)
        try original.write(to: playlistURL)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        await manager.loadSavedPlaylist()
        manager.audioFiles = [makeAudioFile(at: directory.appendingPathComponent("replacement.mp3"), title: "replacement")]
        manager.flushPlaylistPersistence()

        XCTAssertEqual(try Data(contentsOf: playlistURL), original)
        let diagnostics = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("playlist.corrupted.") }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(try Data(contentsOf: diagnostics[0]), original)
    }

    func testCorruptQueueRequiresExplicitRecoveryAndKeepsDiagnosticCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-corrupt-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlistURL = directory.appendingPathComponent("playlist.json")
        let original = Data(#"{"version":2,"tracks":["broken""#.utf8)
        try original.write(to: playlistURL)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        await manager.loadSavedPlaylist()
        let protected = await waitUntil(timeout: 1) {
            manager.queuePersistenceProtection?.canResetQueue == true
        }
        XCTAssertTrue(protected)
        XCTAssertEqual(try Data(contentsOf: playlistURL), original)

        XCTAssertTrue(manager.recoverCorruptQueueStartingEmpty())
        let becameWritable = await waitUntil(timeout: 1) {
            manager.queuePersistenceProtection == nil
        }
        XCTAssertTrue(becameWritable)
        let recovered = try readSnapshot(at: playlistURL)
        XCTAssertTrue(recovered.paths.isEmpty)
        XCTAssertEqual(recovered.currentIndex, 0)

        let diagnostics = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("playlist.corrupted.") }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(try Data(contentsOf: diagnostics[0]), original)
    }

    func testOversizedQueueEntersProtectionWithoutReadingOrReplacingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-oversized-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: playlistURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: playlistURL)
        try handle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
        try handle.close()

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        await manager.loadSavedPlaylist()
        manager.audioFiles = [makeAudioFile(at: directory.appendingPathComponent("replacement.mp3"), title: "replacement")]
        manager.flushPlaylistPersistence()

        let attributes = try FileManager.default.attributesOfItem(atPath: playlistURL.path)
        XCTAssertEqual(attributes[.size] as? NSNumber, NSNumber(value: 16 * 1_024 * 1_024 + 1))
    }

    func testQueueSymlinkIsRejectedAndTargetRemainsUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetURL = directory.appendingPathComponent("target.json")
        let targetBytes = Data(#"{"sentinel":true}"#.utf8)
        try targetBytes.write(to: targetURL)
        let playlistURL = directory.appendingPathComponent("playlist.json")
        try FileManager.default.createSymbolicLink(at: playlistURL, withDestinationURL: targetURL)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        await manager.loadSavedPlaylist()
        manager.audioFiles = [makeAudioFile(at: directory.appendingPathComponent("replacement.mp3"), title: "replacement")]
        manager.flushPlaylistPersistence()

        XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)
        let values = try playlistURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
    }

    func testQueueSnapshotUsesPrivateFileAndDirectoryPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-permissions-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        manager.audioFiles = [makeAudioFile(at: directory.appendingPathComponent("one.mp3"), title: "one")]
        manager.flushPlaylistPersistence()

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: playlistURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testDebouncedSaveBeforeInitialRestoreCannotOverwriteQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-pre-restore-save-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let original = Data(#"{"version":1,"tracks":[],"paths":["/keep/me.mp3"],"currentIndex":0}"#.utf8)
        try original.write(to: playlistURL)

        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            persistenceDebounceInterval: 0.01,
            initialQueueLoadState: .notStarted
        )
        manager.audioFiles = []
        manager.savePlaylist()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(try Data(contentsOf: playlistURL), original)
    }

    func testCancelledRestoreGenerationCannotBecomeReadyOrOverwriteQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-cancelled-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let original = Data(#"{"version":1,"tracks":[],"paths":["/keep/me.mp3"],"currentIndex":0}"#.utf8)
        try original.write(to: playlistURL)

        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            initialQueueLoadState: .loading(generation: 7)
        )
        manager.prepareForImmediateTermination()

        XCTAssertEqual(manager.queueLoadState, .terminating(wasReady: false))
        XCTAssertFalse(manager.completeInitialQueueLoad(generation: 7))
        manager.flushPlaylistPersistence()
        XCTAssertEqual(try Data(contentsOf: playlistURL), original)
    }

    func testPendingAddWaitsUntilQueueBecomesReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-pending-add-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("pending.wav")
        try TestAudioFixture.createSineWAV(at: audioURL, frequency: 440, duration: 0.05)
        let manager = PlaylistManager(
            playlistFileURLOverride: directory.appendingPathComponent("playlist.json"),
            initialQueueLoadState: .loading(generation: 9)
        )

        manager.enqueueAddFiles([audioURL])
        XCTAssertFalse(manager.isAddingFiles)

        XCTAssertTrue(manager.completeInitialQueueLoad(generation: 9))
        XCTAssertTrue(manager.isAddingFiles)
        manager.cancelAddFiles()
        await manager.waitForAddFilesCompletionForTesting()
    }

    func testEphemeralLaunchStillRestoresPersistedQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-ephemeral-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("saved.wav")
        try TestAudioFixture.createSineWAV(at: audioURL, frequency: 440, duration: 0.05)
        let playlistURL = directory.appendingPathComponent("playlist.json")
        let payload: [String: Any] = [
            "version": 1,
            "tracks": [["path": audioURL.path, "signature": NSNull()]],
            "paths": [audioURL.path],
            "currentIndex": 0,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: playlistURL)

        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            initialQueueLoadState: .notStarted
        )
        let store = PlaylistsStore(
            playlistsFileURLOverride: directory.appendingPathComponent("user-playlists.json")
        )
        let player = AudioPlayer()
        player.markSkipRestoreThisLaunch()
        defer {
            manager.prepareForImmediateTermination()
            player.stopAndClearCurrent(clearLastPlayed: false)
        }

        manager.performInitialRestoreIfNeeded(audioPlayer: player, playlistsStore: store)
        let restored = await waitUntil(timeout: 2) {
            manager.queueLoadState == .ready
                && !manager.isInitialRestorePending
                && manager.audioFiles.count == 1
        }

        XCTAssertTrue(restored)
        XCTAssertEqual(manager.audioFiles.first?.url.path, audioURL.path)
        XCTAssertNil(player.currentFile, "ephemeral launch must suppress only playback restoration")
        await manager.waitForBackgroundRestoreWorkForTesting()
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

    func testFailedQueueFlushKeepsLatestSnapshotDirtyAndRetries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlist-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let attemptLock = NSLock()
        var attempts = 0
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            playlistFileWriter: { data, url in
                let currentAttempt = attemptLock.withLock {
                    attempts += 1
                    return attempts
                }
                if currentAttempt == 1 {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try DerivedCacheFileIO.atomicWrite(data, to: url)
            }
        )
        manager.audioFiles = [
            makeAudioFile(at: directory.appendingPathComponent("latest.mp3"), title: "latest")
        ]

        let firstFlush = manager.flushPlaylistPersistence()
        XCTAssertEqual(firstFlush.outcome, .failed)
        XCTAssertFalse(firstFlush.isDurable)

        let retried = await waitUntil(timeout: 2) {
            (try? self.readSnapshot(at: playlistURL).paths) == manager.audioFiles.map { $0.url.path }
        }
        XCTAssertTrue(retried)
        let finalAttempts = attemptLock.withLock { attempts }
        XCTAssertGreaterThanOrEqual(finalAttempts, 2)
    }

    func testQueueFlushDeadlineReturnsWithoutWaitingForSlowDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playlist-flush-deadline-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlistURL = directory.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            playlistFileWriter: { data, url in
                Thread.sleep(forTimeInterval: 0.20)
                try DerivedCacheFileIO.atomicWrite(data, to: url)
            }
        )
        manager.audioFiles = [
            makeAudioFile(at: directory.appendingPathComponent("slow.mp3"), title: "slow")
        ]

        let start = ContinuousClock.now
        let result = manager.flushPlaylistPersistence(timeout: 0.02)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(150))

        let eventuallyPersisted = await waitUntil(timeout: 1) {
            (try? self.readSnapshot(at: playlistURL).paths.count) == 1
        }
        XCTAssertTrue(eventuallyPersisted)
    }

    func testAllMissingQueuePreservesPersistedCurrentIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-all-missing-current-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let paths = (0 ..< 3).map { directory.appendingPathComponent("missing-\($0).mp3").path }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tracks": paths.map { ["path": $0, "signature": NSNull()] },
            "paths": paths,
            "currentIndex": 2,
        ])
        try data.write(to: playlistURL)

        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        await manager.loadSavedPlaylist()
        manager.flushPlaylistPersistence()

        XCTAssertEqual(try readSnapshot(at: playlistURL).currentIndex, 2)
        XCTAssertEqual(try readSnapshot(at: playlistURL).paths, paths)
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
        XCTAssertEqual(saved.version, 2)
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

        let persisted = try readSnapshot(at: playlistURL)
        XCTAssertEqual(
            persisted.paths,
            [fileA.path, fileB.path, fileC.path],
            "Should preserve original order including missing"
        )
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

        XCTAssertEqual(
            savedIndex,
            1,
            "Should preserve the missing current track identity until the user selects another item"
        )
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

    func testClearAllFilesClearsMissingEntriesAndPendingWeightRekeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-clear-queue-intents-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let weightsURL = directory.appendingPathComponent("weights.json")
        try Data(#"{"version":99,"queueLevels":{},"playlistLevels":{}}"#.utf8).write(to: weightsURL)
        let missingPath = directory.appendingPathComponent("missing.mp3").path
        let movedPath = directory.appendingPathComponent("moved.mp3").path
        let savedJSON = """
        {
          "version": 2,
          "tracks": [{"path": "\(missingPath)", "signature": null}],
          "paths": [],
          "currentIndex": 0,
          "pendingWeightRekeys": [{"oldPath": "\(missingPath)", "newPath": "\(movedPath)"}]
        }
        """
        try savedJSON.write(to: playlistURL, atomically: true, encoding: .utf8)

        let weights = PlaybackWeights(cacheFileURLOverride: weightsURL)
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            playbackWeights: weights
        )
        await manager.loadSavedPlaylist()

        let result = manager.clearAllFiles()
        XCTAssertTrue(result.didApply)
        XCTAssertTrue(result.isDurable)
        XCTAssertTrue(manager.audioFiles.isEmpty)
        XCTAssertEqual(manager.currentIndex, 0)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: playlistURL)) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual((json["tracks"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(json["pendingWeightRekeys"])

        let reloaded = PlaylistManager(
            playlistFileURLOverride: playlistURL,
            playbackWeights: weights
        )
        await reloaded.loadSavedPlaylist()
        XCTAssertTrue(reloaded.audioFiles.isEmpty)
        XCTAssertEqual(reloaded.currentIndex, 0)
    }

    func testEnsureInQueueRejectsOversizedPathBeforeMutatingMemory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-queue-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
        let playlistURL = directory.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        let originalURL = directory.appendingPathComponent("original.mp3")
        manager.audioFiles = [makeAudioFile(at: originalURL, title: "original")]

        let oversizedURL = URL(fileURLWithPath: "/" + String(repeating: "a", count: 16 * 1_024 + 1))
        let result = manager.ensureInQueue(
            [makeAudioFile(at: oversizedURL, title: "oversized")],
            focusURL: oversizedURL
        )

        XCTAssertNil(result)
        XCTAssertEqual(manager.audioFiles.map(\.url), [originalURL])
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
