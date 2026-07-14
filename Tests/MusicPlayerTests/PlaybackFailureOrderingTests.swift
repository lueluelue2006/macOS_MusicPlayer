import XCTest
@testable import MusicPlayer

private final class SendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class PlaybackFailureOrderingTests: XCTestCase {
    func testUnplayableMarkExistsBeforeFinishIsPublished() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-failure-ordering-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let badURL = directory.appendingPathComponent("not-audio.mp3")
        try Data("this is text, not audio".utf8).write(to: badURL)
        let badFile = AudioFile(
            url: badURL,
            metadata: AudioMetadata(
                title: "bad",
                artist: "test",
                album: "test",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )

        let player = AudioPlayer()
        player.isLooping = false
        player.isShuffling = false
        let playlistManager = PlaylistManager(disablePersistence: true)
        playlistManager.audioFiles = [badFile]
        playlistManager.currentIndex = 0
        let coordinator = PlaybackCoordinator(
            audioPlayer: player,
            playlistManager: playlistManager
        )

        let finished = expectation(description: "failed request publishes completion")
        let playlistManagerBox = SendableBox(playlistManager)
        let wasMarkedWhenFinishWasPublished = LockedFlag()
        player.play(badFile, bypassConfirm: true)
        let expectedGeneration = player.playbackRequestGeneration
        let observer = NotificationCenter.default.addObserver(
            forName: .audioPlayerDidFinish,
            object: nil,
            queue: .main
        ) { notification in
            guard let notificationURL = notification.userInfo?["url"] as? URL,
                  notificationURL.standardizedFileURL == badURL.standardizedFileURL,
                  let generation = notification.userInfo?["playbackGeneration"] as? UInt64,
                  generation == expectedGeneration,
                  notification.userInfo?["completionEventID"] as? UInt64 != nil else {
                return
            }
            wasMarkedWhenFinishWasPublished.set(
                playlistManagerBox.value.unplayableReason(for: badURL) != nil
            )
            finished.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            player.stopAndClearCurrent(clearLastPlayed: false)
            withExtendedLifetime(coordinator) {}
        }

        await fulfillment(of: [finished], timeout: 2)

        XCTAssertTrue(wasMarkedWhenFinishWasPublished.get())
    }
}
