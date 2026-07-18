import XCTest
@testable import MusicPlayer

@MainActor
final class PresentationStateTests: XCTestCase {
    func testNumberedTracksKeepsPathIdentitySeparateFromDisplayOrder() {
        let tracks = [
            makeTrack("first.mp3"),
            makeTrack("second.mp3"),
            makeTrack("third.mp3")
        ]

        let initial = Array(tracks.numberedTracks)
        XCTAssertEqual(initial.map(\.number), [1, 2, 3])
        XCTAssertEqual(initial.map(\.id), tracks.map(\.id))

        let reordered = Array([tracks[2], tracks[0]].numberedTracks)
        XCTAssertEqual(reordered.map(\.number), [1, 2])
        XCTAssertEqual(reordered.map(\.id), [tracks[2].id, tracks[0].id])
    }

    func testReplacingToastCancelsOnlyTheOldDismissal() async throws {
        let state = ToastState()

        state.show("旧提示", duration: 0.01)
        state.show("新提示", duration: 5.0)

        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.title, "新提示")
        state.dismiss()
    }

    func testPlaybackScopeRevisionTracksInPlacePlaylistChanges() {
        let manager = PlaylistManager(disablePersistence: true)
        let playlistID = UUID()
        let first = makeTrack("first.mp3").url
        let second = makeTrack("second.mp3").url

        manager.setPlaybackScopePlaylist(
            playlistID,
            trackURLsInOrder: [first, second]
        )
        let initialRevision = manager.playbackScopeRevision

        manager.updatePlaybackScopePlaylistTracksIfActive(
            playlistID,
            trackURLsInOrder: [second, first]
        )
        XCTAssertGreaterThan(manager.playbackScopeRevision, initialRevision)

        let reorderedRevision = manager.playbackScopeRevision
        manager.updatePlaybackScopePlaylistTracksIfActive(
            playlistID,
            trackURLsInOrder: [second, first]
        )
        XCTAssertEqual(manager.playbackScopeRevision, reorderedRevision)
    }

    private func makeTrack(_ name: String) -> AudioFile {
        AudioFile(
            url: URL(fileURLWithPath: "/tmp/musicplayer-presentation-tests/\(name)"),
            metadata: AudioMetadata(
                title: name,
                artist: "Test Artist",
                album: "Test Album",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )
    }
}
