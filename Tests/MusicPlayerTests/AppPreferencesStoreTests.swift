import XCTest
@testable import MusicPlayer

final class AppPreferencesStoreTests: XCTestCase {
    func testDefaultsDoNotWriteUntilAValueChanges() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.load(), .default)
        XCTAssertFalse(store.hasUnpersistedChanges)
        XCTAssertNil(defaults.data(forKey: AppPreferencesStore.envelopeKey))
    }

    func testDeferredUpdatesMergeIntoOneEnvelopeAndClampValues() throws {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(userDefaults: defaults)
        let playlistID = UUID()

        store.update {
            $0.volume = 4
            $0.playbackRate = -.infinity
        }
        store.update {
            $0.playbackMode = .repeatOne
            $0.playbackScope = .playlist(playlistID)
        }

        XCTAssertNil(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        XCTAssertTrue(store.hasUnpersistedChanges)
        assertSuccess(store.persist())

        let reloaded = AppPreferencesStore(userDefaults: defaults).load()
        XCTAssertEqual(reloaded.volume, 1)
        XCTAssertEqual(reloaded.playbackRate, 1)
        XCTAssertEqual(reloaded.playbackMode, .repeatOne)
        XCTAssertEqual(reloaded.playbackScope, .playlist(playlistID))
        XCTAssertFalse(store.hasUnpersistedChanges)

        let data = try XCTUnwrap(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, AppPreferencesStore.formatVersion)
        XCTAssertNotNil(json["preferences"] as? [String: Any])
    }

    func testDebouncedPersistenceCoalescesLatestSnapshot() async throws {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(userDefaults: defaults)

        store.update { $0.volume = 0.2 }
        store.schedulePersistence(after: 0.15)
        store.update { $0.volume = 0.8 }
        store.schedulePersistence(after: 0.02)

        XCTAssertNil(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(AppPreferencesStore(userDefaults: defaults).load().volume, 0.8)
    }

    func testLegacyKeysMigrateTogetherAndAreRemoved() throws {
        let defaults = makeDefaults()
        let playlistID = UUID()
        defaults.set(0.75, forKey: AppPreferencesStore.LegacyKey.volume)
        defaults.set(1.5, forKey: AppPreferencesStore.LegacyKey.playbackRate)
        defaults.set("repeatOne", forKey: AppPreferencesStore.LegacyKey.playbackMode)
        defaults.set("playlist", forKey: AppPreferencesStore.LegacyKey.scopeKind)
        defaults.set(playlistID.uuidString, forKey: AppPreferencesStore.LegacyKey.scopePlaylistID)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.75)
        XCTAssertEqual(preferences.playbackRate, 1.5)
        XCTAssertEqual(preferences.playbackMode, .repeatOne)
        XCTAssertEqual(preferences.playbackScope, .playlist(playlistID))
        XCTAssertNotNil(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        for key in AppPreferencesStore.LegacyKey.all {
            XCTAssertNil(defaults.object(forKey: key), "Legacy key was not removed: \(key)")
        }
    }

    func testInvalidLegacyValuesUseSafeDefaults() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.volume)
        defaults.set(Double.nan, forKey: AppPreferencesStore.LegacyKey.playbackRate)
        defaults.set("invalid", forKey: AppPreferencesStore.LegacyKey.playbackMode)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.looping)
        defaults.set("playlist", forKey: AppPreferencesStore.LegacyKey.scopeKind)
        defaults.set("not-a-uuid", forKey: AppPreferencesStore.LegacyKey.scopePlaylistID)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.5)
        XCTAssertEqual(preferences.playbackRate, 1)
        XCTAssertEqual(preferences.playbackMode, .repeatOne)
        XCTAssertEqual(preferences.playbackScope, .queue)
    }

    func testFutureEnvelopeRemainsByteForByteAndRejectsMutations() throws {
        let defaults = makeDefaults()
        let future = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "preferences": [
                "volume": 0.2,
                "playbackRate": 1.25,
                "playbackMode": "shuffle",
                "playbackScope": ["kind": "queue"],
            ],
            "future": ["keep": true],
        ])
        defaults.set(future, forKey: AppPreferencesStore.envelopeKey)
        let store = AppPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.load(), .default)
        XCTAssertEqual(store.persistenceState, .protectedFuture(version: 99))
        XCTAssertFalse(store.update { $0.volume = 0.9 })
        assertProtectedFuture(store.persist(), version: 99)
        assertProtectedFuture(store.flush(), version: 99)
        XCTAssertEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), future)
    }

    func testCorruptEnvelopeIsQuarantinedBeforeLegacyRecovery() {
        let defaults = makeDefaults()
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: AppPreferencesStore.envelopeKey)
        defaults.set(0.6, forKey: AppPreferencesStore.LegacyKey.volume)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.6)
        XCTAssertEqual(
            defaults.data(forKey: AppPreferencesStore.corruptQuarantineKeys[0]),
            corrupt
        )
        XCTAssertNotEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), corrupt)
    }

    func testOversizedEnvelopeIsPreservedByteForByteAndProtected() {
        let defaults = makeDefaults()
        let oversized = Data(repeating: 0xA5, count: 64 * 1_024 + 1)
        defaults.set(oversized, forKey: AppPreferencesStore.envelopeKey)
        let store = AppPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.load(), .default)
        XCTAssertEqual(store.persistenceState, .protectedCorrupt)
        XCTAssertFalse(store.update { $0.volume = 0.9 })
        guard case .failure(.corruptEnvelope) = store.persist() else {
            return XCTFail("Oversized preference data must stay read-only")
        }
        XCTAssertEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), oversized)
        XCTAssertTrue(
            AppPreferencesStore.corruptQuarantineKeys.allSatisfy {
                defaults.object(forKey: $0) == nil
            }
        )
    }

    func testCorruptEnvelopeQuarantineRetainsOnlyTwoNewestPayloads() {
        let defaults = makeDefaults()
        let payloads = (0 ..< 3).map { Data("corrupt-preferences-\($0)".utf8) }

        for payload in payloads {
            defaults.set(payload, forKey: AppPreferencesStore.envelopeKey)
            _ = AppPreferencesStore(userDefaults: defaults).load()
        }

        XCTAssertEqual(
            defaults.data(forKey: AppPreferencesStore.corruptQuarantineKeys[0]),
            payloads[2]
        )
        XCTAssertEqual(
            defaults.data(forKey: AppPreferencesStore.corruptQuarantineKeys[1]),
            payloads[1]
        )
    }

    @MainActor
    func testAudioPlayerAndPlaylistManagerMergeIntoSharedEnvelope() throws {
        let defaults = makeDefaults()
        let preferences = AppPreferencesStore(userDefaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-preferences-integration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let player = AudioPlayer(
            volumeCacheFileURLOverride: directory.appendingPathComponent("volume-cache.json"),
            appPreferencesStore: preferences,
            loadUserPreferences: true
        )
        player.setVolume(0.72)
        player.setPlaybackRate(1.75)
        player.setPlaybackMode(.repeatOne)

        let playlistID = UUID()
        let manager = PlaylistManager(
            playlistFileURLOverride: directory.appendingPathComponent("playlist.json"),
            appPreferencesStore: preferences
        )
        manager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: [])
        assertSuccess(player.flushUserPreferencesPersistence())

        let reloaded = AppPreferencesStore(userDefaults: defaults).load()
        XCTAssertEqual(reloaded.volume, 0.72, accuracy: 0.0001)
        XCTAssertEqual(reloaded.playbackRate, 1.75, accuracy: 0.0001)
        XCTAssertEqual(reloaded.playbackMode, .repeatOne)
        XCTAssertEqual(reloaded.playbackScope, .playlist(playlistID))
    }

    func testFailedLifecycleSynchronizationKeepsPreferencesRetryable() throws {
        let suite = "app-preferences-sync-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            AppPreferencesSynchronizationFailingDefaults(suiteName: suite)
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(userDefaults: defaults)
        XCTAssertTrue(store.update { $0.volume = 0.83 })

        guard case .failure(.synchronizationFailed) = store.flush() else {
            return XCTFail("A failed durability receipt must be reported")
        }
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertEqual(store.load().volume, 0.83, accuracy: 0.0001)
    }

    private func assertSuccess(
        _ result: Result<Void, AppPreferencesStore.PersistenceError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertProtectedFuture(
        _ result: Result<Void, AppPreferencesStore.PersistenceError>,
        version: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(.protectedFuture(let actual)) = result else {
            XCTFail("Expected future-schema protection", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, version, file: file, line: line)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "app-preferences-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

private final class AppPreferencesSynchronizationFailingDefaults: UserDefaults {
    override func synchronize() -> Bool { false }
}
