import XCTest
@testable import MusicPlayer

@MainActor
final class PlaybackModeTests: XCTestCase {
    func testLegacyCombinationsResolveToExactlyOneMode() {
        let cases: [(Bool, Bool, AudioPlayer.PlaybackMode)] = [
            (false, true, .shuffle),
            (true, false, .repeatOne),
            (false, false, .shuffle),
            (true, true, .repeatOne),
        ]

        for (legacyLooping, legacyShuffling, expected) in cases {
            let mode = AudioPlayer.resolvedPlaybackMode(
                storedRawValue: nil,
                legacyLooping: legacyLooping,
                legacyShuffling: legacyShuffling
            )
            XCTAssertEqual(mode, expected)
        }
    }

    func testStoredModeWinsAndInvalidValueFallsBackToLegacyState() {
        XCTAssertEqual(
            AudioPlayer.resolvedPlaybackMode(
                storedRawValue: "shuffle",
                legacyLooping: true,
                legacyShuffling: false
            ),
            .shuffle
        )
        XCTAssertEqual(
            AudioPlayer.resolvedPlaybackMode(
                storedRawValue: "repeatOne",
                legacyLooping: false,
                legacyShuffling: true
            ),
            .repeatOne
        )
        XCTAssertEqual(
            AudioPlayer.resolvedPlaybackMode(
                storedRawValue: "invalid",
                legacyLooping: true,
                legacyShuffling: false
            ),
            .repeatOne
        )
    }

    func testSelectingPlaybackModeIsExclusiveAndIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playback-mode-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json")
        )

        assertMode(.shuffle, player: player)
        player.setPlaybackMode(.shuffle)
        assertMode(.shuffle, player: player)
        player.setPlaybackMode(.repeatOne)
        assertMode(.repeatOne, player: player)
        player.setPlaybackMode(.repeatOne)
        assertMode(.repeatOne, player: player)
        player.setPlaybackMode(.shuffle)
        assertMode(.shuffle, player: player)
    }

    private func assertMode(
        _ expected: AudioPlayer.PlaybackMode,
        player: AudioPlayer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(player.playbackMode, expected, file: file, line: line)
        XCTAssertEqual(player.isShuffling, expected == .shuffle, file: file, line: line)
        XCTAssertEqual(player.isLooping, expected == .repeatOne, file: file, line: line)
        XCTAssertNotEqual(player.isShuffling, player.isLooping, file: file, line: line)
    }
}
