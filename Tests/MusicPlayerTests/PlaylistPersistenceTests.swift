import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistPersistenceTests: XCTestCase {
    private struct SavedPlaylist: Decodable {
        let paths: [String]
        let currentIndex: Int
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
