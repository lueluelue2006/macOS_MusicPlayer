import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistRemovalScopeTests: XCTestCase {
    func testPlaylistScopeDeletionUsesPlaylistSuccessor() throws {
        let manager = PlaylistManager(disablePersistence: true)
        let files = makeFiles(["A", "B", "C"])
        manager.audioFiles = files
        manager.currentIndex = 0
        manager.setPlaybackScopePlaylist(UUID(), trackURLsInOrder: [files[0].url, files[2].url])

        let context = try XCTUnwrap(manager.removeFile(at: 0))
        let next = try XCTUnwrap(manager.nextFileAfterRemovingQueueItem(context))

        XCTAssertEqual(next.url, files[2].url)
        XCTAssertEqual(manager.currentIndex, 1)
    }

    func testPlaylistScopeDeletionFollowsPlaylistOrderAndWraps() throws {
        let manager = PlaylistManager(disablePersistence: true)
        let files = makeFiles(["A", "B", "C", "D"])
        manager.audioFiles = files
        let playlistID = UUID()
        manager.setPlaybackScopePlaylist(
            playlistID,
            trackURLsInOrder: [files[2].url, files[0].url, files[3].url]
        )

        manager.currentIndex = 2
        let middleContext = try XCTUnwrap(manager.removeFile(at: 2))
        XCTAssertEqual(
            manager.nextFileAfterRemovingQueueItem(middleContext)?.url,
            files[0].url
        )

        manager.audioFiles = files
        manager.currentIndex = 3
        manager.setPlaybackScopePlaylist(
            playlistID,
            trackURLsInOrder: [files[2].url, files[0].url, files[3].url]
        )
        let lastContext = try XCTUnwrap(manager.removeFile(at: 3))
        XCTAssertEqual(
            manager.nextFileAfterRemovingQueueItem(lastContext)?.url,
            files[2].url
        )
    }

    func testQueueScopeDeletionUsesAdjustedInsertionIndex() throws {
        let manager = PlaylistManager(disablePersistence: true)
        let files = makeFiles(["A", "B", "C", "D"])
        manager.audioFiles = files
        manager.currentIndex = 2

        let context = try XCTUnwrap(manager.removeFile(at: 2))
        _ = manager.removeFile(at: 0)
        let next = try XCTUnwrap(
            manager.nextFileAfterRemovingQueueItem(
                context,
                queueIndexAfterBatchRemoval: 1
            )
        )

        XCTAssertEqual(next.url, files[3].url)
        XCTAssertEqual(manager.currentIndex, 1)
    }

    func testQueueScopeDeletionOfLastItemWrapsToFirst() throws {
        let manager = PlaylistManager(disablePersistence: true)
        let files = makeFiles(["A", "B", "C"])
        manager.audioFiles = files
        manager.currentIndex = 2

        let context = try XCTUnwrap(manager.removeFile(at: 2))
        let next = try XCTUnwrap(manager.nextFileAfterRemovingQueueItem(context))

        XCTAssertEqual(next.url, files[0].url)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    private func makeFiles(_ names: [String]) -> [AudioFile] {
        names.map { name in
            AudioFile(
                url: URL(fileURLWithPath: "/tmp/musicplayer-removal-\(name)-\(UUID().uuidString).mp3"),
                metadata: AudioMetadata(
                    title: name,
                    artist: "test",
                    album: "test",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
            )
        }
    }
}
