import XCTest
@testable import MusicPlayer

@MainActor
final class PlaylistViewModelTests: XCTestCase {
    private actor MetadataRefreshProbe {
        private(set) var active = 0
        private(set) var peakActive = 0
        private(set) var completed = 0

        func begin() {
            active += 1
            peakActive = max(peakActive, active)
        }

        func finish() {
            active -= 1
            completed += 1
        }

        func snapshot() -> (peakActive: Int, completed: Int) {
            (peakActive, completed)
        }
    }

    private func makeAudioFile(at url: URL) -> AudioFile {
        AudioFile(
            url: url,
            metadata: AudioMetadata(
                title: "fixture",
                artist: "test",
                album: "test",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )
    }

    func testRejectedClearDoesNotStopPlaybackOrHideQueue() {
        let manager = PlaylistManager(
            disablePersistence: true,
            initialQueueLoadState: .notStarted
        )
        manager.audioFiles = [
            makeAudioFile(at: URL(fileURLWithPath: "/tmp/queue-fixture.mp3"))
        ]
        var stopCount = 0
        let viewModel = PlaylistViewModel(
            audioPlayer: AudioPlayer(),
            playlistManager: manager,
            playlistsStore: PlaylistsStore(),
            stopPlaybackForQueueClear: { stopCount += 1 }
        )

        let result = viewModel.clearQueue()

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(manager.audioFiles.count, 1)
    }

    func testAppliedClearStopsOnceAndImmediatelyEmptiesVisibleQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-view-model-clear-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlistURL = directory.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(playlistFileURLOverride: playlistURL)
        manager.audioFiles = [makeAudioFile(at: directory.appendingPathComponent("fixture.mp3"))]
        var stopCount = 0
        let viewModel = PlaylistViewModel(
            audioPlayer: AudioPlayer(),
            playlistManager: manager,
            playlistsStore: PlaylistsStore(
                playlistsFileURLOverride: directory.appendingPathComponent("playlists.json")
            ),
            stopPlaybackForQueueClear: { stopCount += 1 }
        )
        await Task.yield()

        let result = viewModel.clearQueue()

        XCTAssertTrue(result.didApply)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(manager.audioFiles.isEmpty)
        XCTAssertTrue(viewModel.displayedQueueFiles.isEmpty)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: playlistURL)) as? [String: Any]
        )
        XCTAssertEqual((json["tracks"] as? [[String: Any]])?.count, 0)
    }

    func testRefreshAllMetadataKeepsTaskConcurrencyBoundedAndPreservesOrder() async {
        let probe = MetadataRefreshProbe()
        let manager = PlaylistManager(
            disablePersistence: true,
            freshMetadataLoaderOverride: { url in
                await probe.begin()
                try? await Task.sleep(nanoseconds: 20_000_000)
                await probe.finish()
                return AudioMetadata(
                    title: url.deletingPathExtension().lastPathComponent,
                    artist: "refreshed",
                    album: "refreshed",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
            }
        )
        manager.audioFiles = (0..<40).map { index in
            makeAudioFile(
                at: URL(fileURLWithPath: "/tmp/metadata-refresh-\(index).mp3")
            )
        }

        await manager.refreshAllMetadata()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.completed, 40)
        XCTAssertLessThanOrEqual(snapshot.peakActive, 4)
        XCTAssertEqual(
            manager.audioFiles.map(\.metadata.title),
            (0..<40).map { "metadata-refresh-\($0)" }
        )
    }
}
