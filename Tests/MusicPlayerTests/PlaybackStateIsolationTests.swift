import AVFoundation
import XCTest
@testable import MusicPlayer

@MainActor
final class PlaybackStateIsolationTests: XCTestCase {
    func testRestoreSeekCannotLeakIntoDifferentSelection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = AudioPlayer(volumeCacheFileURLOverride: fixture.cacheURL)
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        let unrelatedURL = fixture.directory.appendingPathComponent("old-selection.wav")
        player.prepareInitialSeekForRestore(to: 0.4, for: unrelatedURL)
        player.play(fixture.file, autostart: false, persist: false, bypassConfirm: true)
        await waitForLoad(of: fixture.file.url, in: player)

        XCTAssertEqual(player.currentFile?.url, fixture.file.url)
        XCTAssertEqual(player.playbackClock.currentTime, 0, accuracy: 0.02)
    }

    func testStopClearsPendingRestoreSeek() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = AudioPlayer(volumeCacheFileURLOverride: fixture.cacheURL)
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.prepareInitialSeekForRestore(to: 0.4, for: fixture.file.url)
        player.stop()
        player.play(fixture.file, autostart: false, persist: false, bypassConfirm: true)
        await waitForLoad(of: fixture.file.url, in: player)

        XCTAssertEqual(player.playbackClock.currentTime, 0, accuracy: 0.02)
    }

    func testSeekDuringReplacementLoadTargetsTheReplacement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = AudioPlayer(volumeCacheFileURLOverride: fixture.cacheURL)
        player.isNormalizationEnabled = false
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(fixture.file, autostart: false, persist: false, bypassConfirm: true)
        await waitForLoad(of: fixture.file.url, in: player)

        let replacementURL = fixture.directory.appendingPathComponent("replacement.wav")
        try writeWAV(to: replacementURL)
        let replacement = makeAudioFile(url: replacementURL, title: "replacement")
        player.play(replacement, autostart: false, persist: false, bypassConfirm: true)
        player.seek(to: 0.4)
        await waitForLoad(of: replacementURL, in: player)

        XCTAssertEqual(player.currentFile?.url, replacementURL)
        XCTAssertEqual(player.playbackClock.currentTime, 0.4, accuracy: 0.03)
    }

    func testFailedReplacementKeepsInstalledTrackResumable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = AudioPlayer(volumeCacheFileURLOverride: fixture.cacheURL)
        player.isNormalizationEnabled = false
        player.setPlaybackMode(.shuffle)
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(fixture.file, autostart: false, persist: false, bypassConfirm: true)
        await waitForLoad(of: fixture.file.url, in: player)

        let badURL = fixture.directory.appendingPathComponent("not-audio.mp3")
        try Data("plain text".utf8).write(to: badURL)
        player.play(
            makeAudioFile(url: badURL, title: "bad"),
            persist: false,
            bypassConfirm: true
        )

        let didFail = await waitUntil(timeout: 2) {
            player.pendingPlaybackURL == nil && !player.isPlaybackRequested
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(player.currentFile?.url, fixture.file.url)
        XCTAssertEqual(player.playbackTargetURL, fixture.file.url)
        XCTAssertTrue(player.canTogglePlayback)

        player.resume(bypassConfirm: true)
        let didResume = await waitUntil(timeout: 1) {
            player.isPlaybackRequested && player.isPlaying
        }
        XCTAssertTrue(didResume)
        XCTAssertEqual(player.testActualPlayerVolume, 0.0, "Test mode should silence actual audio output")
    }

    func testRemovingPendingOnlyTrackContinuesSequentially() async throws {
        let fixture = try makeQueueFixture(["A", "B"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = makeTestPlayer(cacheURL: fixture.cacheURL)
        let manager = PlaylistManager(disablePersistence: true)
        manager.audioFiles = fixture.files
        manager.currentIndex = 0
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(fixture.files[0], persist: false, bypassConfirm: true)
        XCTAssertNil(player.currentFile)
        XCTAssertEqual(player.pendingPlaybackURL, fixture.files[0].url)

        let removal = try XCTUnwrap(manager.removeFile(at: 0))
        player.handleRemovedTrack(
            removal.removedFile.url,
            remainingFiles: manager.audioFiles,
            playNext: { manager.nextFileAfterRemovingQueueItem(removal) }
        )

        let didContinue = await waitUntil(timeout: 2) {
            player.currentFile?.url == fixture.files[1].url
                && player.pendingPlaybackURL == nil
                && player.isPlaybackRequested
                && player.isPlaying
        }
        XCTAssertTrue(didContinue)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testRemovingPausedPendingOnlyTrackStaysStopped() async throws {
        let fixture = try makeQueueFixture(["A", "B"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = makeTestPlayer(cacheURL: fixture.cacheURL)
        let manager = PlaylistManager(disablePersistence: true)
        manager.audioFiles = fixture.files
        manager.currentIndex = 0
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(
            fixture.files[0],
            autostart: false,
            persist: false,
            bypassConfirm: true
        )
        XCTAssertNil(player.currentFile)
        XCTAssertEqual(player.pendingPlaybackURL, fixture.files[0].url)
        XCTAssertFalse(player.isPlaybackRequested)

        var didRequestSuccessor = false
        let removal = try XCTUnwrap(manager.removeFile(at: 0))
        player.handleRemovedTrack(
            removal.removedFile.url,
            remainingFiles: manager.audioFiles,
            playNext: {
                didRequestSuccessor = true
                return manager.nextFileAfterRemovingQueueItem(removal)
            }
        )

        let didRestart = await waitUntil(timeout: 0.3) {
            player.currentFile != nil
                || player.pendingPlaybackURL != nil
                || player.isPlaybackRequested
                || player.isPlaying
        }
        XCTAssertFalse(didRestart)
        XCTAssertFalse(didRequestSuccessor)
        XCTAssertNil(player.currentFile)
        XCTAssertNil(player.pendingPlaybackURL)
        XCTAssertFalse(player.isPlaybackRequested)
        XCTAssertFalse(player.isPlaying)
    }

    func testRemovingPendingReplacementRestoresInstalledSelection() async throws {
        let fixture = try makeQueueFixture(["A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = makeTestPlayer(cacheURL: fixture.cacheURL)
        let manager = PlaylistManager(disablePersistence: true)
        manager.audioFiles = fixture.files
        manager.currentIndex = 0
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(
            fixture.files[0],
            autostart: false,
            persist: false,
            bypassConfirm: true
        )
        await waitForLoad(of: fixture.files[0].url, in: player)

        _ = manager.selectFile(at: 2)
        player.play(fixture.files[2], persist: false, bypassConfirm: true)
        XCTAssertEqual(player.currentFile?.url, fixture.files[0].url)
        XCTAssertEqual(player.pendingPlaybackURL, fixture.files[2].url)

        let removal = try XCTUnwrap(manager.removeFile(at: 2))
        player.handleRemovedTrack(
            removal.removedFile.url,
            remainingFiles: manager.audioFiles,
            playNext: { manager.nextFileAfterRemovingQueueItem(removal) },
            restoreInstalledSelection: {
                guard let installedURL = player.currentFile?.url,
                      let installedIndex = manager.audioFiles.firstIndex(
                        where: { $0.url == installedURL }
                      )
                else { return }
                _ = manager.selectFile(at: installedIndex)
            }
        )

        let didRestore = await waitUntil(timeout: 2) {
            player.currentFile?.url == fixture.files[0].url
                && player.pendingPlaybackURL == nil
                && player.isPlaybackRequested
                && player.isPlaying
        }
        XCTAssertTrue(didRestore)
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.audioFiles[manager.currentIndex].url, fixture.files[0].url)
    }

    func testRemovingInstalledTrackDoesNotCancelPendingReplacement() async throws {
        let fixture = try makeQueueFixture(["A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = makeTestPlayer(cacheURL: fixture.cacheURL)
        let manager = PlaylistManager(disablePersistence: true)
        manager.audioFiles = fixture.files
        manager.currentIndex = 0
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(
            fixture.files[0],
            autostart: false,
            persist: false,
            bypassConfirm: true
        )
        await waitForLoad(of: fixture.files[0].url, in: player)

        _ = manager.selectFile(at: 2)
        player.play(fixture.files[2], persist: false, bypassConfirm: true)
        XCTAssertEqual(player.currentFile?.url, fixture.files[0].url)
        XCTAssertEqual(player.pendingPlaybackURL, fixture.files[2].url)

        let removal = try XCTUnwrap(manager.removeFile(at: 0))
        player.handleRemovedTrack(
            removal.removedFile.url,
            remainingFiles: manager.audioFiles,
            playNext: { manager.nextFileAfterRemovingQueueItem(removal) }
        )

        let didInstallReplacement = await waitUntil(timeout: 2) {
            player.currentFile?.url == fixture.files[2].url
                && player.pendingPlaybackURL == nil
                && player.isPlaybackRequested
                && player.isPlaying
        }
        XCTAssertTrue(didInstallReplacement)
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertEqual(manager.audioFiles[manager.currentIndex].url, fixture.files[2].url)
    }

    func testRemovingInstalledCurrentTrackContinuesToSequentialSuccessor() async throws {
        let fixture = try makeQueueFixture(["A", "B"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let player = makeTestPlayer(cacheURL: fixture.cacheURL)
        let manager = PlaylistManager(disablePersistence: true)
        manager.audioFiles = fixture.files
        manager.currentIndex = 0
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(
            fixture.files[0],
            autostart: false,
            persist: false,
            bypassConfirm: true
        )
        await waitForLoad(of: fixture.files[0].url, in: player)

        let removal = try XCTUnwrap(manager.removeFile(at: 0))
        player.handleRemovedTrack(
            removal.removedFile.url,
            remainingFiles: manager.audioFiles,
            playNext: { manager.nextFileAfterRemovingQueueItem(removal) }
        )

        let didContinue = await waitUntil(timeout: 2) {
            player.currentFile?.url == fixture.files[1].url
                && player.pendingPlaybackURL == nil
                && player.isPlaybackRequested
                && player.isPlaying
        }
        XCTAssertTrue(didContinue)
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.audioFiles[manager.currentIndex].url, fixture.files[1].url)
    }

    private func waitForLoad(of url: URL, in player: AudioPlayer) async {
        for _ in 0 ..< 100 {
            if player.currentFile?.url == url, player.pendingPlaybackURL == nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for paused audio load")
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

    private func makeFixture() throws -> (directory: URL, cacheURL: URL, file: AudioFile) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playback-state-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("fixture.wav")
        try writeWAV(to: audioURL)
        let file = makeAudioFile(url: audioURL, title: "fixture")
        return (directory, directory.appendingPathComponent("volume-cache.json"), file)
    }

    private func makeQueueFixture(
        _ names: [String]
    ) throws -> (directory: URL, cacheURL: URL, files: [AudioFile]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-playback-state-queue-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try names.map { name in
            let url = directory.appendingPathComponent("\(name).wav")
            try writeWAV(to: url)
            return makeAudioFile(url: url, title: name)
        }
        return (
            directory,
            directory.appendingPathComponent("volume-cache.json"),
            files
        )
    }

    private func makeTestPlayer(cacheURL: URL) -> AudioPlayer {
        let player = AudioPlayer(
            volumeCacheFileURLOverride: cacheURL,
            initialImmersivePlaybackEnabled: false
        )
        player.isNormalizationEnabled = false
        player.setPlaybackMode(.shuffle)
        return player
    }

    private func makeAudioFile(url: URL, title: String) -> AudioFile {
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

    private func writeWAV(to url: URL) throws {
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount: AVAudioFrameCount = 8_000
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frameCount) {
            let time = Double(index) / sampleRate
            samples[index] = Float(sin(2 * Double.pi * 440 * time) * 0.2)
        }
        try file.write(from: buffer)
    }
}
