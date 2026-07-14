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
        store.createPlaylist(name: "artist")
        let playlistID = try XCTUnwrap(store.playlists.first?.id)
        let trackURLs = [
            directory.appendingPathComponent("one.mp3"),
            directory.appendingPathComponent("two.mp3"),
        ]
        store.addTracks(trackURLs, to: playlistID)

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
