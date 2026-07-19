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

    private actor MetadataRefreshGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
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

    func testProtectedFuturePreferencesRestorePanelAndScanUIState() throws {
        let suite = "playlist-view-model-future-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let future = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "preferences": [
                "playlistPanelMode": 1,
                "scanSubfolders": false,
            ],
        ])
        defaults.set(future, forKey: AppPreferencesStore.envelopeKey)
        let preferences = AppPreferencesStore(userDefaults: defaults)
        let manager = PlaylistManager(
            playlistFileURLOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("protected-panel-\(UUID().uuidString).json"),
            appPreferencesStore: preferences
        )
        let viewModel = PlaylistViewModel(
            audioPlayer: AudioPlayer(),
            playlistManager: manager,
            playlistsStore: PlaylistsStore()
        )

        XCTAssertTrue(manager.scanSubfolders)
        manager.scanSubfolders = false
        XCTAssertTrue(manager.scanSubfolders)

        XCTAssertTrue(viewModel.isQueueSelected)
        viewModel.switchToPlaylists()
        XCTAssertTrue(viewModel.isQueueSelected)
        XCTAssertEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), future)
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

    func testRefreshAllMetadataMergesWithoutRestoringRemovedOrDroppingAddedEntries() async {
        let gate = MetadataRefreshGate()
        let started = expectation(description: "metadata refresh started")
        started.expectedFulfillmentCount = 2
        let manager = PlaylistManager(
            disablePersistence: true,
            freshMetadataLoaderOverride: { url in
                started.fulfill()
                await gate.wait()
                return AudioMetadata(
                    title: "refreshed-\(url.deletingPathExtension().lastPathComponent)",
                    artist: "refreshed",
                    album: "refreshed",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
            }
        )
        let firstURL = URL(fileURLWithPath: "/tmp/merge-first.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/merge-second.mp3")
        let addedURL = URL(fileURLWithPath: "/tmp/merge-added.mp3")
        manager.audioFiles = [
            makeAudioFile(at: firstURL),
            makeAudioFile(at: secondURL)
        ]

        let refreshTask = Task { await manager.refreshAllMetadata() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNotNil(manager.removeFile(at: 0))
        XCTAssertNotNil(manager.ensureInQueue([makeAudioFile(at: addedURL)], focusURL: addedURL))
        await gate.open()
        await refreshTask.value

        XCTAssertEqual(manager.audioFiles.map(\.url), [secondURL, addedURL])
        XCTAssertEqual(manager.audioFiles[0].metadata.title, "refreshed-merge-second")
        XCTAssertEqual(manager.audioFiles[1].metadata.title, "fixture")
    }
}
