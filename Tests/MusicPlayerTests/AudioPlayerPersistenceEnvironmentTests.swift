import XCTest
@testable import MusicPlayer

final class AudioPlayerPersistenceEnvironmentTests: XCTestCase {
    func testEnvironmentInitializerKeepsLoudnessDatabaseInCachesAndMigratesLegacyJSON() throws {
        try withFixture { fixture in
            try fixture.environment.prepareApplicationSupportDirectory()
            let legacyURL = fixture.environment.applicationSupportURL
                .appendingPathComponent("volume-cache.json")
            try Data(#"{"version":3,"entriesByPath":{}}"#.utf8).write(to: legacyURL)

            let player = AudioPlayer(
                environment: fixture.environment,
                appPreferencesStore: fixture.preferencesStore
            )
            defer {
                _ = player.flushUserPreferencesPersistence()
                _ = player.flushPlaybackStatePersistence()
            }

            let databaseURL = fixture.environment.cachesURL
                .appendingPathComponent("volume-analysis.sqlite3")
            XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.environment.applicationSupportURL
                    .appendingPathComponent("volume-analysis.sqlite3")
                    .path
            ))
            XCTAssertTrue(waitUntil {
                !FileManager.default.fileExists(atPath: legacyURL.path)
            }, "The Application Support legacy JSON should be consumed by the Caches database")
        }
    }

    func testEnvironmentInitializerLoadsAndPersistsAllPlayerPreferencesThroughInjectedStore() throws {
        try withFixture { fixture in
            fixture.preferencesStore.update {
                $0.volume = 0.31
                $0.playbackRate = 1.25
                $0.playbackMode = .shuffle
                $0.normalizationEnabled = false
                $0.immersiveEnabled = true
                $0.analyzeDuringPlayback = true
                $0.autoPreanalyze = false
                $0.targetLUFS = -21
                $0.immersiveFadeDuration = 1.2
                $0.requireAnalysisBeforeTransition = true
                $0.notifyOnDeviceSwitch = false
                $0.notifyDeviceSwitchSilent = false
            }
            assertSuccess(fixture.preferencesStore.persist())

            let player = AudioPlayer(
                environment: fixture.environment,
                appPreferencesStore: fixture.preferencesStore
            )

            XCTAssertEqual(player.volume, 0.31, accuracy: 0.000_1)
            XCTAssertEqual(player.playbackRate, 1.25, accuracy: 0.000_1)
            XCTAssertEqual(player.playbackMode, .shuffle)
            XCTAssertFalse(player.isNormalizationEnabled)
            XCTAssertTrue(player.isImmersivePlaybackEnabled)
            XCTAssertTrue(player.analyzeVolumesDuringPlayback)
            XCTAssertFalse(player.autoPreanalyzeVolumesWhenIdle)
            XCTAssertEqual(player.normalizationTargetLUFS, -21, accuracy: 0.000_1)
            XCTAssertEqual(player.normalizationFadeDuration, 1.2, accuracy: 0.000_1)
            XCTAssertTrue(player.requireVolumeAnalysisBeforePlayback)
            XCTAssertFalse(player.notifyOnDeviceSwitch)
            XCTAssertFalse(player.notifyDeviceSwitchSilent)

            player.setVolume(0.66)
            player.setPlaybackRate(1.5)
            player.setPlaybackMode(.repeatOne)
            player.setNormalizationEnabled(true)
            player.setImmersivePlaybackEnabled(false)
            player.analyzeVolumesDuringPlayback = false
            player.saveAnalyzeVolumesDuringPlaybackPreference()
            player.autoPreanalyzeVolumesWhenIdle = true
            player.saveAutoPreanalyzeVolumesWhenIdlePreference()
            player.normalizationTargetLUFS = -18
            player.saveNormalizationTargetLevelPreference()
            player.normalizationFadeDuration = 0.25
            player.saveNormalizationFadeDurationPreference()
            player.requireVolumeAnalysisBeforePlayback = false
            player.saveRequireVolumeAnalysisBeforePlaybackPreference()
            player.notifyOnDeviceSwitch = true
            player.saveNotifyOnDeviceSwitchPreference()
            player.notifyDeviceSwitchSilent = true
            player.saveNotifyDeviceSwitchSilentPreference()
            assertSuccess(player.flushUserPreferencesPersistence())

            let persisted = AppPreferencesStore(userDefaults: fixture.defaults).load()
            XCTAssertEqual(persisted.volume, 0.66, accuracy: 0.000_1)
            XCTAssertEqual(persisted.playbackRate, 1.5, accuracy: 0.000_1)
            XCTAssertEqual(persisted.playbackMode, .repeatOne)
            XCTAssertTrue(persisted.normalizationEnabled)
            XCTAssertFalse(persisted.immersiveEnabled)
            XCTAssertFalse(persisted.analyzeDuringPlayback)
            XCTAssertTrue(persisted.autoPreanalyze)
            XCTAssertEqual(persisted.targetLUFS, -18, accuracy: 0.000_1)
            XCTAssertEqual(persisted.immersiveFadeDuration, 0.25, accuracy: 0.000_1)
            XCTAssertFalse(persisted.requireAnalysisBeforeTransition)
            XCTAssertTrue(persisted.notifyOnDeviceSwitch)
            XCTAssertTrue(persisted.notifyDeviceSwitchSilent)
            for key in AppPreferencesStore.LegacyKey.all {
                XCTAssertNil(fixture.defaults.object(forKey: key))
            }
        }
    }

    func testEnvironmentInitializerReadsPlaybackStateFromInjectedDefaultsDomain() throws {
        try withFixture { fixture in
            let audioURL = try fixture.environment.prepareApplicationSupportDirectory()
                .appendingPathComponent("remembered-track.mp3")
            try Data().write(to: audioURL)
            let playbackStore = PlaybackStateStore(userDefaults: fixture.defaults)
            playbackStore.saveState(fileURL: audioURL, time: 42)
            XCTAssertTrue(playbackStore.flush())

            let player = AudioPlayer(
                environment: fixture.environment,
                appPreferencesStore: fixture.preferencesStore
            )
            let capturedURL = LockedURL()
            let token = NotificationCenter.default.addObserver(
                forName: .loadLastPlayedFile,
                object: nil,
                queue: nil
            ) { notification in
                capturedURL.set(notification.userInfo?["url"] as? URL)
            }
            defer { NotificationCenter.default.removeObserver(token) }

            player.loadLastPlayedFile()

            XCTAssertEqual(capturedURL.get(), audioURL)
        }
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let environment: PersistenceEnvironment
        let preferencesStore: AppPreferencesStore
    }

    private final class LockedURL: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL?

        func set(_ value: URL?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audio-player-persistence-environment-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "AudioPlayerPersistenceEnvironmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let environment = PersistenceEnvironment(
            applicationSupportURL: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesURL: root.appendingPathComponent("Caches", isDirectory: true),
            userDefaults: defaults,
            isTesting: true
        )
        let fixture = Fixture(
            root: root,
            defaults: defaults,
            environment: environment,
            preferencesStore: AppPreferencesStore(userDefaults: defaults)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try body(fixture)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func assertSuccess(
        _ result: Result<Void, AppPreferencesStore.PersistenceError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .success = result else {
            return XCTFail("Expected preference persistence success, got \(result)", file: file, line: line)
        }
    }
}
