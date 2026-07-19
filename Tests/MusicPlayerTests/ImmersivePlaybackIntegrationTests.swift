import AVFoundation
import XCTest
@testable import MusicPlayer

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class ImmersivePlaybackIntegrationTests: XCTestCase {
    func testLateColdAnalysisUpdatesCurrentTrackWithoutReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-immersive-late-current-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("late.wav")
        try writeWAV(to: audioURL, duration: 4, audibleRange: 0.5 ..< 3.1)
        let analyzer = ImmersivePlaybackAnalyzer(
            cacheFileURL: nil,
            configuration: ImmersivePlaybackAnalyzer.Configuration(analysisTimeout: 0.02),
            analysisOperation: { _, _ in
                Thread.sleep(forTimeInterval: 0.25)
                return ImmersivePlaybackAnalyzer.AnalysisOutcome(
                    bounds: PlaybackBounds(
                        audibleStart: 0.5,
                        audibleEnd: 3.1,
                        physicalDuration: 4
                    ),
                    isCacheable: true
                )
            }
        )
        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json"),
            initialImmersivePlaybackEnabled: true,
            immersivePlaybackAnalyzerOverride: analyzer
        )
        player.isNormalizationEnabled = false
        defer { player.stopAndClearCurrent(clearLastPlayed: false) }

        player.play(
            makeAudioFile(audioURL, title: "late"),
            autostart: false,
            persist: false,
            bypassConfirm: true
        )
        let loadedWithFallback = await waitUntil(timeout: 1) {
            player.currentFile?.url == audioURL
                && player.pendingPlaybackURL == nil
                && player.activePlaybackBounds?.hasTrimmedEnd == false
        }
        XCTAssertTrue(loadedWithFallback)

        let adoptedLateBounds = await waitUntil(timeout: 1) {
            player.currentFile?.url == audioURL
                && player.activePlaybackBounds?.audibleStart == 0.5
                && player.activePlaybackBounds?.audibleEnd == 3.1
        }
        XCTAssertTrue(adoptedLateBounds)
        XCTAssertFalse(player.isPlaying)
    }

    func testLogicalBoundaryAdvancesToNextTrackExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-immersive-integration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.wav")
        let secondURL = directory.appendingPathComponent("second.wav")
        try writeWAV(to: firstURL, duration: 4, audibleRange: 0.5 ..< 3.2)
        try writeWAV(to: secondURL, duration: 4, audibleRange: 0 ..< 4)
        let first = makeAudioFile(firstURL, title: "first")
        let second = makeAudioFile(secondURL, title: "second")

        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json"),
            initialImmersivePlaybackEnabled: true
        )
        player.isNormalizationEnabled = false
        player.setPlaybackMode(.shuffle)
        let manager = PlaylistManager(disablePersistence: true)
        manager.audioFiles = [first, second]
        manager.currentIndex = 0
        let coordinator = PlaybackCoordinator(audioPlayer: player, playlistManager: manager)
        defer {
            player.stopAndClearCurrent(clearLastPlayed: false)
            withExtendedLifetime(coordinator) {}
        }

        let completions = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .audioPlayerDidFinish,
            object: nil,
            queue: .main
        ) { notification in
            guard notification.userInfo?["url"] as? URL == firstURL else { return }
            completions.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        player.play(first, autostart: false, persist: true, bypassConfirm: true)
        let firstLoaded = await waitUntil(timeout: 3) {
            player.currentFile?.url == firstURL
                && player.pendingPlaybackURL == nil
                && player.activePlaybackBounds?.hasTrimmedEnd == true
        }
        XCTAssertTrue(firstLoaded)
        XCTAssertLessThan(player.effectivePlaybackEndTime, player.playbackClock.duration)

        player.resume(bypassConfirm: true)
        let started = await waitUntil(timeout: 1) { player.isPlaying }
        XCTAssertTrue(started)
        XCTAssertEqual(player.testActualPlayerVolume, 0.0, "Test mode should silence actual audio output")

        // Move into the coordinator's preload window, then prove that the next
        // AVAudioPlayer is actually prepared before crossing the logical end.
        player.seek(to: max(0, player.effectivePlaybackEndTime - 1))
        let prepared = await waitUntil(timeout: 3) {
            player.preparedNextTrackURL == secondURL
        }
        XCTAssertTrue(prepared)
        player.seek(to: player.effectivePlaybackEndTime - 0.02)

        let advanced = await waitUntil(timeout: 3) {
            player.currentFile?.url == secondURL
                && player.pendingPlaybackURL == nil
                && player.isPlaybackRequested
                && player.isPlaying
        }
        XCTAssertTrue(advanced)
        XCTAssertEqual(
            player.testActualPlayerVolume,
            0.0,
            "The preloaded handoff must remain hardware-silent under XCTest"
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(completions.read(), 1)
        XCTAssertEqual(manager.currentIndex, 1)
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

    private func makeAudioFile(_ url: URL, title: String) -> AudioFile {
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

    private func writeWAV(
        to url: URL,
        duration: TimeInterval,
        audibleRange: Range<TimeInterval>
    ) throws {
        let sampleRate = 8_000.0
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frameCount) {
            let time = Double(index) / sampleRate
            samples[index] = audibleRange.contains(time)
                ? Float(sin(2 * Double.pi * 440 * time) * 0.2)
                : 0
        }
        try file.write(from: buffer)
    }
}
