import Foundation
import XCTest
@testable import MusicPlayer

private final class TestAudioPlaybackAccessLease: AudioPlaybackAccessLease, @unchecked Sendable {
    let locationID = UUID()
    let url: URL

    private let lock = NSLock()
    private var storedReleaseCount = 0

    init(url: URL) {
        self.url = url
    }

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReleaseCount
    }

    func releasePlaybackAccess() {
        lock.lock()
        storedReleaseCount += 1
        lock.unlock()
    }
}

@MainActor
final class AudioPlayerAccessLeaseTests: XCTestCase {
    func testVolumeContainmentUsesPathComponentBoundaries() {
        let volumeURL = URL(fileURLWithPath: "/Volumes/USB", isDirectory: true)
        XCTAssertTrue(AudioPlayer.isPlaybackResourceURL(
            URL(fileURLWithPath: "/Volumes/USB/Music/song.mp3"),
            containedIn: volumeURL
        ))
        XCTAssertTrue(AudioPlayer.isPlaybackResourceURL(volumeURL, containedIn: volumeURL))
        XCTAssertFalse(AudioPlayer.isPlaybackResourceURL(
            URL(fileURLWithPath: "/Volumes/USB2/Music/song.mp3"),
            containedIn: volumeURL
        ))
    }

    func testInstalledTrackRetainsLeaseUntilCurrentTrackIsCleared() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("leased.wav")
        try TestAudioFixture.createSineWAV(at: audioURL)

        let accessLease = TestAudioPlaybackAccessLease(url: audioURL)
        let player = AudioPlayer()
        player.isNormalizationEnabled = false
        player.play(
            makeAudioFile(at: audioURL),
            autostart: false,
            persist: false,
            bypassConfirm: true,
            accessLease: accessLease
        )

        let didInstallTrack = await waitUntil {
            player.currentFile?.url == audioURL && player.pendingPlaybackURL == nil
        }
        XCTAssertTrue(didInstallTrack)
        XCTAssertEqual(accessLease.releaseCount, 0)

        player.stop()
        XCTAssertEqual(accessLease.releaseCount, 0, "stop keeps the installed track resumable")

        player.stopAndClearCurrent(clearLastPlayed: false)
        XCTAssertEqual(accessLease.releaseCount, 1)
    }

    func testFailedLoadReleasesPendingLeaseWithoutInstallingTrack() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("invalid.mp3")
        try Data("plain text is not audio".utf8).write(to: invalidURL)

        let accessLease = TestAudioPlaybackAccessLease(url: invalidURL)
        let player = AudioPlayer()
        player.play(
            makeAudioFile(at: invalidURL),
            autostart: false,
            persist: false,
            bypassConfirm: true,
            accessLease: accessLease
        )

        let didReleaseFailedLease = await waitUntil {
            player.pendingPlaybackURL == nil && accessLease.releaseCount == 1
        }
        XCTAssertTrue(didReleaseFailedLease)
        XCTAssertNil(player.currentFile)
        player.stopAndClearCurrent(clearLastPlayed: false)
        XCTAssertEqual(accessLease.releaseCount, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-audio-access-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAudioFile(at url: URL) -> AudioFile {
        AudioFile(
            url: url,
            metadata: AudioMetadata(
                title: url.deletingPathExtension().lastPathComponent,
                artist: "",
                album: "",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}
