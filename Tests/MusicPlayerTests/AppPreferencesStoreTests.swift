import XCTest
@testable import MusicPlayer

final class AppPreferencesStoreTests: XCTestCase {
    func testDefaultsDoNotWriteUntilAValueChanges() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(userDefaults: defaults)

        let preferences = store.load()
        XCTAssertEqual(preferences, .default)
        XCTAssertTrue(preferences.normalizationEnabled)
        XCTAssertFalse(preferences.immersiveEnabled)
        XCTAssertFalse(preferences.analyzeDuringPlayback)
        XCTAssertTrue(preferences.autoPreanalyze)
        XCTAssertEqual(preferences.targetLUFS, -16)
        XCTAssertEqual(preferences.immersiveFadeDuration, 0.6)
        XCTAssertFalse(preferences.requireAnalysisBeforeTransition)
        XCTAssertTrue(preferences.scanSubfolders)
        XCTAssertTrue(preferences.notifyOnDeviceSwitch)
        XCTAssertTrue(preferences.notifyDeviceSwitchSilent)
        XCTAssertEqual(preferences.colorSchemeOverride, 0)
        XCTAssertEqual(preferences.playlistPanelMode, 0)
        XCTAssertEqual(preferences.compactRootPane, 0)
        XCTAssertFalse(preferences.ipcDebugEnabled)
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
            $0.targetLUFS = 100
            $0.immersiveFadeDuration = -3
            $0.colorSchemeOverride = 99
            $0.playlistPanelMode = -1
            $0.compactRootPane = 5
            $0.ipcDebugEnabled = true
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
        XCTAssertEqual(reloaded.playbackScope, .queue)
        XCTAssertEqual(reloaded.targetLUFS, -8)
        XCTAssertEqual(reloaded.immersiveFadeDuration, 0)
        XCTAssertEqual(reloaded.colorSchemeOverride, 2)
        XCTAssertEqual(reloaded.playlistPanelMode, 0)
        XCTAssertEqual(reloaded.compactRootPane, 1)
        XCTAssertTrue(reloaded.ipcDebugEnabled)
        XCTAssertFalse(store.hasUnpersistedChanges)

        let data = try XCTUnwrap(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, AppPreferencesStore.formatVersion)
        let encodedPreferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        XCTAssertEqual(Set(encodedPreferences.keys), Set([
            "volume",
            "playbackRate",
            "playbackMode",
            "normalizationEnabled",
            "immersiveEnabled",
            "analyzeDuringPlayback",
            "autoPreanalyze",
            "targetLUFS",
            "immersiveFadeDuration",
            "requireAnalysisBeforeTransition",
            "scanSubfolders",
            "notifyOnDeviceSwitch",
            "notifyDeviceSwitchSilent",
            "colorSchemeOverride",
            "playlistPanelMode",
            "compactRootPane",
            "ipcDebugEnabled",
        ]))
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
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.normalizationEnabled)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.immersiveEnabled)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.analyzeDuringPlayback)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.autoPreanalyze)
        defaults.set(-21.5, forKey: AppPreferencesStore.LegacyKey.targetLUFS)
        defaults.set(1.2, forKey: AppPreferencesStore.LegacyKey.immersiveFadeDuration)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.requireAnalysisBeforeTransition)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.scanSubfolders)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.notifyOnDeviceSwitch)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.notifyDeviceSwitchSilent)
        defaults.set(2, forKey: AppPreferencesStore.LegacyKey.colorSchemeOverride)
        defaults.set(1, forKey: AppPreferencesStore.LegacyKey.playlistPanelMode)
        defaults.set(1, forKey: AppPreferencesStore.LegacyKey.compactRootPane)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.ipcDebugEnabled)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.75)
        XCTAssertEqual(preferences.playbackRate, 1.5)
        XCTAssertEqual(preferences.playbackMode, .repeatOne)
        XCTAssertEqual(preferences.playbackScope, .playlist(playlistID))
        XCTAssertFalse(preferences.normalizationEnabled)
        XCTAssertTrue(preferences.immersiveEnabled)
        XCTAssertTrue(preferences.analyzeDuringPlayback)
        XCTAssertFalse(preferences.autoPreanalyze)
        XCTAssertEqual(preferences.targetLUFS, -21.5)
        XCTAssertEqual(preferences.immersiveFadeDuration, 1.2)
        XCTAssertTrue(preferences.requireAnalysisBeforeTransition)
        XCTAssertFalse(preferences.scanSubfolders)
        XCTAssertFalse(preferences.notifyOnDeviceSwitch)
        XCTAssertFalse(preferences.notifyDeviceSwitchSilent)
        XCTAssertEqual(preferences.colorSchemeOverride, 2)
        XCTAssertEqual(preferences.playlistPanelMode, 1)
        XCTAssertEqual(preferences.compactRootPane, 1)
        XCTAssertTrue(preferences.ipcDebugEnabled)
        XCTAssertNotNil(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        for key in AppPreferencesStore.LegacyKey.all {
            XCTAssertNil(defaults.object(forKey: key), "Legacy key was not removed: \(key)")
        }
    }

    func testV1EnvelopeMergesAddedLegacyKeysAndMigratesToV2() throws {
        let defaults = makeDefaults()
        let playlistID = UUID()
        let v1 = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "preferences": [
                "volume": 0.24,
                "playbackRate": 1.25,
                "playbackMode": "repeatOne",
                "playbackScope": [
                    "kind": "playlist",
                    "playlistID": playlistID.uuidString,
                ],
            ],
        ])
        defaults.set(v1, forKey: AppPreferencesStore.envelopeKey)
        // The coherent v1 envelope wins for fields it already owned.
        defaults.set(0.99, forKey: AppPreferencesStore.LegacyKey.volume)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.normalizationEnabled)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.immersiveEnabled)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.analyzeDuringPlayback)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.autoPreanalyze)
        defaults.set(-19.5, forKey: AppPreferencesStore.LegacyKey.targetLUFS)
        defaults.set(0.9, forKey: AppPreferencesStore.LegacyKey.immersiveFadeDuration)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.requireAnalysisBeforeTransition)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.scanSubfolders)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.notifyOnDeviceSwitch)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.notifyDeviceSwitchSilent)
        defaults.set(2, forKey: AppPreferencesStore.LegacyKey.colorSchemeOverride)
        defaults.set(1, forKey: AppPreferencesStore.LegacyKey.playlistPanelMode)
        defaults.set(1, forKey: AppPreferencesStore.LegacyKey.compactRootPane)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.ipcDebugEnabled)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.24)
        XCTAssertEqual(preferences.playbackRate, 1.25)
        XCTAssertEqual(preferences.playbackMode, .repeatOne)
        XCTAssertEqual(preferences.playbackScope, .playlist(playlistID))
        XCTAssertFalse(preferences.normalizationEnabled)
        XCTAssertTrue(preferences.immersiveEnabled)
        XCTAssertTrue(preferences.analyzeDuringPlayback)
        XCTAssertFalse(preferences.autoPreanalyze)
        XCTAssertEqual(preferences.targetLUFS, -19.5)
        XCTAssertEqual(preferences.immersiveFadeDuration, 0.9)
        XCTAssertTrue(preferences.requireAnalysisBeforeTransition)
        XCTAssertFalse(preferences.scanSubfolders)
        XCTAssertFalse(preferences.notifyOnDeviceSwitch)
        XCTAssertFalse(preferences.notifyDeviceSwitchSilent)
        XCTAssertEqual(preferences.colorSchemeOverride, 2)
        XCTAssertEqual(preferences.playlistPanelMode, 1)
        XCTAssertEqual(preferences.compactRootPane, 1)
        XCTAssertTrue(preferences.ipcDebugEnabled)

        let migrated = try XCTUnwrap(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        let encodedPreferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        XCTAssertNil(encodedPreferences["playbackScope"])
        for key in AppPreferencesStore.LegacyKey.all {
            XCTAssertNil(defaults.object(forKey: key), "Legacy key was not removed: \(key)")
        }
    }

    func testPartialV2EnvelopeUsesDefaultsForNewFields() throws {
        let defaults = makeDefaults()
        let partial = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "preferences": [
                "volume": 0.7,
                "playbackRate": 1.5,
                "playbackMode": "shuffle",
            ],
        ])
        defaults.set(partial, forKey: AppPreferencesStore.envelopeKey)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.7)
        XCTAssertTrue(preferences.normalizationEnabled)
        XCTAssertFalse(preferences.immersiveEnabled)
        XCTAssertFalse(preferences.analyzeDuringPlayback)
        XCTAssertTrue(preferences.autoPreanalyze)
        XCTAssertEqual(preferences.targetLUFS, -16)
        XCTAssertEqual(preferences.immersiveFadeDuration, 0.6)
        XCTAssertFalse(preferences.requireAnalysisBeforeTransition)
        XCTAssertTrue(preferences.scanSubfolders)
        XCTAssertTrue(preferences.notifyOnDeviceSwitch)
        XCTAssertTrue(preferences.notifyDeviceSwitchSilent)
        XCTAssertEqual(preferences.colorSchemeOverride, 0)
        XCTAssertEqual(preferences.playlistPanelMode, 0)
        XCTAssertEqual(preferences.compactRootPane, 0)
        XCTAssertFalse(preferences.ipcDebugEnabled)
        let rewritten = try XCTUnwrap(defaults.data(forKey: AppPreferencesStore.envelopeKey))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        let encodedPreferences = try XCTUnwrap(root["preferences"] as? [String: Any])
        XCTAssertNil(encodedPreferences["playbackScope"])
        XCTAssertEqual(encodedPreferences.keys.count, 17)
        XCTAssertNotNil(encodedPreferences["ipcDebugEnabled"])
    }

    func testV2EnvelopeWinsOverStaleLegacyKeysBeforeRemovingThem() {
        let defaults = makeDefaults()
        let writer = AppPreferencesStore(userDefaults: defaults)
        XCTAssertTrue(writer.update {
            $0.normalizationEnabled = false
            $0.immersiveEnabled = true
        })
        assertSuccess(writer.persist())
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.normalizationEnabled)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.immersiveEnabled)

        let reloaded = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertFalse(reloaded.normalizationEnabled)
        XCTAssertTrue(reloaded.immersiveEnabled)
        XCTAssertNil(defaults.object(forKey: AppPreferencesStore.LegacyKey.normalizationEnabled))
        XCTAssertNil(defaults.object(forKey: AppPreferencesStore.LegacyKey.immersiveEnabled))
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
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.normalizationEnabled)
        let store = AppPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.load(), .default)
        XCTAssertEqual(store.persistenceState, .protectedFuture(version: 99))
        XCTAssertFalse(store.update { $0.volume = 0.9 })
        assertProtectedFuture(store.persist(), version: 99)
        assertProtectedFuture(store.flush(), version: 99)
        XCTAssertEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), future)
        XCTAssertEqual(
            defaults.object(forKey: AppPreferencesStore.LegacyKey.normalizationEnabled) as? Bool,
            false
        )
    }

    func testCorruptEnvelopeIsQuarantinedBeforeLegacyRecovery() {
        let defaults = makeDefaults()
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: AppPreferencesStore.envelopeKey)
        defaults.set(0.6, forKey: AppPreferencesStore.LegacyKey.volume)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.immersiveEnabled)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertEqual(preferences.volume, 0.6)
        XCTAssertTrue(preferences.immersiveEnabled)
        XCTAssertEqual(
            defaults.data(forKey: AppPreferencesStore.corruptQuarantineKeys[0]),
            corrupt
        )
        XCTAssertNotEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), corrupt)
    }

    func testWrongTypeInV2FieldIsQuarantinedInsteadOfSilentlyDefaulted() throws {
        let defaults = makeDefaults()
        let corrupt = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "preferences": [
                "volume": 0.4,
                "playbackRate": 1.0,
                "playbackMode": "shuffle",
                "playbackScope": ["kind": "queue"],
                "normalizationEnabled": "yes",
            ],
        ])
        defaults.set(corrupt, forKey: AppPreferencesStore.envelopeKey)
        defaults.set(false, forKey: AppPreferencesStore.LegacyKey.normalizationEnabled)

        let preferences = AppPreferencesStore(userDefaults: defaults).load()

        XCTAssertFalse(preferences.normalizationEnabled)
        XCTAssertEqual(
            defaults.data(forKey: AppPreferencesStore.corruptQuarantineKeys[0]),
            corrupt
        )
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
        XCTAssertEqual(reloaded.playbackScope, .queue)
    }

    @MainActor
    func testPlaylistManagerWithoutSessionStoreDoesNotPersistScopeInPreferences() {
        let defaults = makeDefaults()
        let preferences = AppPreferencesStore(userDefaults: defaults)
        let manager = PlaylistManager(
            playlistFileURLOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("scope-without-session-\(UUID().uuidString).json"),
            appPreferencesStore: preferences
        )

        manager.setPlaybackScopePlaylist(UUID(), trackURLsInOrder: [])

        XCTAssertEqual(preferences.load().playbackScope, .queue)
        XCTAssertNil(defaults.data(forKey: AppPreferencesStore.envelopeKey))
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

    func testFailedV1MigrationKeepsOriginalEnvelopeAndLegacyKeysRetryable() throws {
        let suite = "app-preferences-v1-sync-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            AppPreferencesSynchronizationFailingDefaults(suiteName: suite)
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let v1 = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "preferences": [
                "volume": 0.4,
                "playbackRate": 1.0,
                "playbackMode": "shuffle",
                "playbackScope": ["kind": "queue"],
            ],
        ])
        defaults.set(v1, forKey: AppPreferencesStore.envelopeKey)
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.immersiveEnabled)
        let store = AppPreferencesStore(userDefaults: defaults)

        XCTAssertTrue(store.load().immersiveEnabled)
        XCTAssertEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), v1)
        XCTAssertEqual(
            defaults.object(forKey: AppPreferencesStore.LegacyKey.immersiveEnabled) as? Bool,
            true
        )
        XCTAssertTrue(store.hasUnpersistedChanges)
    }

    func testFailedLegacyCleanupRestoresKeysUntilAFlushCanRetry() throws {
        let suite = "app-preferences-cleanup-sync-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            AppPreferencesScriptedSynchronizationDefaults(suiteName: suite)
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        // Migration write succeeds, cleanup fails, restoring the key succeeds;
        // the following flush and cleanup then both succeed.
        defaults.synchronizationResults = [true, false, true, true, true]
        defaults.set(true, forKey: AppPreferencesStore.LegacyKey.immersiveEnabled)
        let store = AppPreferencesStore(userDefaults: defaults)

        XCTAssertTrue(store.load().immersiveEnabled)
        XCTAssertEqual(
            defaults.object(forKey: AppPreferencesStore.LegacyKey.immersiveEnabled) as? Bool,
            true
        )
        XCTAssertTrue(store.hasUnpersistedChanges)

        assertSuccess(store.flush())
        XCTAssertNil(defaults.object(forKey: AppPreferencesStore.LegacyKey.immersiveEnabled))
        XCTAssertFalse(store.hasUnpersistedChanges)
    }

    func testIPCDebugRuntimeChangesOnlyAfterPreferencePersistenceSucceeds() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(userDefaults: defaults)
        IPCDebugSettings.setEnabled(false)
        defer { IPCDebugSettings.setEnabled(false) }

        let result = IPCDebugSettings.persistEnabled(true, preferencesStore: store)

        guard case .success(let storedValue) = result else {
            return XCTFail("Expected IPC debug preference to persist")
        }
        XCTAssertTrue(storedValue)
        XCTAssertTrue(store.load().ipcDebugEnabled)
        XCTAssertTrue(IPCDebugSettings.isEnabled())
    }

    func testProtectedFuturePreferencesRejectIPCDebugRuntimeChange() throws {
        let defaults = makeDefaults()
        let future = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "preferences": ["ipcDebugEnabled": true],
        ])
        defaults.set(future, forKey: AppPreferencesStore.envelopeKey)
        let store = AppPreferencesStore(userDefaults: defaults)
        IPCDebugSettings.setEnabled(false)
        defer { IPCDebugSettings.setEnabled(false) }

        let result = IPCDebugSettings.persistEnabled(true, preferencesStore: store)

        assertProtectedFuture(result.map { _ in () }, version: 99)
        XCTAssertFalse(IPCDebugSettings.isEnabled())
        XCTAssertEqual(defaults.data(forKey: AppPreferencesStore.envelopeKey), future)
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

private final class AppPreferencesScriptedSynchronizationDefaults: UserDefaults {
    var synchronizationResults: [Bool] = []

    override func synchronize() -> Bool {
        guard !synchronizationResults.isEmpty else { return true }
        return synchronizationResults.removeFirst()
    }
}
