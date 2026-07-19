import XCTest
@testable import MusicPlayer

final class PlaybackStateStoreTests: XCTestCase {
    func testLoadStateReturnsNilWhenNoStateSaved() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let state = store.loadState()
        XCTAssertNil(state)
    }

    func testSaveAndLoadFile() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: 42.5)

        let state = try? XCTUnwrap(store.loadState())
        XCTAssertEqual(state?.filePath, "/Users/test/music.mp3")
        XCTAssertEqual(state?.lastPlayedTime, 42.5)
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertTrue(store.flush())
        XCTAssertFalse(store.hasUnpersistedChanges)
    }

    func testSaveUsesOneVersionedEnvelope() throws {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let url = URL(fileURLWithPath: "/Users/test/music.mp3")

        store.saveState(fileURL: url, time: 42.5)

        let data = try XCTUnwrap(defaults.data(forKey: PlaybackStateStore.envelopeKey))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? Int, PlaybackStateStore.formatVersion)
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(state["filePath"] as? String, url.path)
        XCTAssertEqual((state["lastPlayedTime"] as? NSNumber)?.doubleValue, 42.5)
        XCTAssertNil(defaults.object(forKey: PlaybackStateStore.legacyFilePathKey))
        XCTAssertNil(defaults.object(forKey: PlaybackStateStore.legacyFileTimeKey))
    }

    func testLegacyKeysMigrateToEnvelopeAndAreRemoved() throws {
        let defaults = makeDefaults()
        defaults.set("/Users/test/legacy.mp3", forKey: PlaybackStateStore.legacyFilePathKey)
        defaults.set(18.25, forKey: PlaybackStateStore.legacyFileTimeKey)
        let store = PlaybackStateStore(userDefaults: defaults)

        let state = try XCTUnwrap(store.loadState())

        XCTAssertEqual(state.filePath, "/Users/test/legacy.mp3")
        XCTAssertEqual(state.lastPlayedTime, 18.25)
        XCTAssertNotNil(defaults.data(forKey: PlaybackStateStore.envelopeKey))
        XCTAssertNil(defaults.object(forKey: PlaybackStateStore.legacyFilePathKey))
        XCTAssertNil(defaults.object(forKey: PlaybackStateStore.legacyFileTimeKey))
        XCTAssertFalse(store.hasUnpersistedChanges)
    }

    func testLegacyPathWithoutTimeMigratesAtZero() throws {
        let defaults = makeDefaults()
        defaults.set("/Users/test/legacy.mp3", forKey: PlaybackStateStore.legacyFilePathKey)
        let store = PlaybackStateStore(userDefaults: defaults)

        XCTAssertEqual(try XCTUnwrap(store.loadState()).lastPlayedTime, 0)
    }

    func testSaveFileWithoutInitialTimePreservesExistingProgress() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: 100.0)

        let state1 = try? XCTUnwrap(store.loadState())
        XCTAssertEqual(state1?.lastPlayedTime, 100.0)

        // Save same file without initialTime (e.g., on pause)
        store.saveFile(url, initialTime: nil)

        let state2 = try? XCTUnwrap(store.loadState())
        XCTAssertEqual(state2?.filePath, "/Users/test/music.mp3")
        XCTAssertEqual(state2?.lastPlayedTime, 100.0, "Progress should remain unchanged")
    }

    func testDifferentFileWithoutInitialTimeDoesNotInheritProgress() throws {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        store.saveFile(URL(fileURLWithPath: "/Users/test/first.mp3"), initialTime: 100)

        store.saveFile(URL(fileURLWithPath: "/Users/test/second.mp3"))

        let state = try XCTUnwrap(store.loadState())
        XCTAssertEqual(state.filePath, "/Users/test/second.mp3")
        XCTAssertEqual(state.lastPlayedTime, 0)
    }

    func testSaveProgressUpdatesTime() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: 10.0)

        store.saveProgress(25.5)

        let state = try? XCTUnwrap(store.loadState())
        XCTAssertEqual(state?.lastPlayedTime, 25.5)
    }

    func testSaveFileWithNegativeTimeClamps() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: -5.0)

        let state = try? XCTUnwrap(store.loadState())
        XCTAssertEqual(state?.lastPlayedTime, 0.0, "Negative time should be clamped to 0")
    }

    func testNonFiniteTimesAreSanitized() throws {
        for value in [TimeInterval.nan, .infinity, -.infinity] {
            let defaults = makeDefaults()
            let store = PlaybackStateStore(userDefaults: defaults)
            store.saveState(fileURL: URL(fileURLWithPath: "/Users/test/music.mp3"), time: value)
            XCTAssertEqual(try XCTUnwrap(store.loadState()).lastPlayedTime, 0)
        }
    }

    func testProgressWithoutAFileDoesNotCreatePartialState() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        store.saveProgress(12)

        XCTAssertNil(store.loadState())
        XCTAssertNil(defaults.data(forKey: PlaybackStateStore.envelopeKey))
    }

    func testFutureEnvelopeIsReadOnlyAndPreservedByteForByte() throws {
        let defaults = makeDefaults()
        let futureData = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "state": [
                "filePath": "/future/song.mp3",
                "lastPlayedTime": 20.0,
            ],
            "futureField": "keep",
        ])
        defaults.set(futureData, forKey: PlaybackStateStore.envelopeKey)
        defaults.set("/legacy/song.mp3", forKey: PlaybackStateStore.legacyFilePathKey)
        defaults.set(12.0, forKey: PlaybackStateStore.legacyFileTimeKey)
        let store = PlaybackStateStore(userDefaults: defaults)

        XCTAssertNil(store.loadState())
        XCTAssertEqual(store.persistenceState, .protectedFuture(version: 99))

        store.saveState(fileURL: URL(fileURLWithPath: "/new/song.mp3"), time: 1)
        XCTAssertEqual(store.rekeyIfMatching(
            from: URL(fileURLWithPath: "/future/song.mp3"),
            to: URL(fileURLWithPath: "/moved/song.mp3")
        ), .protected)
        store.clearIfMatching(URL(fileURLWithPath: "/future/song.mp3"))
        store.clearAll()

        XCTAssertEqual(defaults.data(forKey: PlaybackStateStore.envelopeKey), futureData)
        XCTAssertEqual(
            defaults.string(forKey: PlaybackStateStore.legacyFilePathKey),
            "/legacy/song.mp3"
        )
        XCTAssertEqual(defaults.double(forKey: PlaybackStateStore.legacyFileTimeKey), 12.0)
    }

    func testCorruptEnvelopeFallsBackToLegacyState() throws {
        let defaults = makeDefaults()
        let corruptData = Data(repeating: 0xFF, count: 64 * 1_024)
        defaults.set(corruptData, forKey: PlaybackStateStore.envelopeKey)
        defaults.set("/Users/test/legacy.mp3", forKey: PlaybackStateStore.legacyFilePathKey)
        defaults.set(7.5, forKey: PlaybackStateStore.legacyFileTimeKey)
        let store = PlaybackStateStore(userDefaults: defaults)

        let state = try XCTUnwrap(store.loadState())

        XCTAssertEqual(state.filePath, "/Users/test/legacy.mp3")
        XCTAssertEqual(state.lastPlayedTime, 7.5)
        XCTAssertEqual(store.persistenceState, .writable)
        XCTAssertEqual(
            defaults.data(forKey: PlaybackStateStore.corruptQuarantineKeys[0]),
            corruptData
        )
        XCTAssertNotEqual(defaults.data(forKey: PlaybackStateStore.envelopeKey), corruptData)
    }

    func testCorruptEnvelopeQuarantineRetainsOnlyTwoMostRecentPayloads() throws {
        let defaults = makeDefaults()
        let corruptPayloads = (0 ..< 3).map { Data("invalid-envelope-\($0)".utf8) }

        for (index, corruptData) in corruptPayloads.enumerated() {
            defaults.set(corruptData, forKey: PlaybackStateStore.envelopeKey)
            defaults.set(
                "/Users/test/legacy-\(index).mp3",
                forKey: PlaybackStateStore.legacyFilePathKey
            )
            defaults.set(Double(index), forKey: PlaybackStateStore.legacyFileTimeKey)

            let recovered = try XCTUnwrap(
                PlaybackStateStore(userDefaults: defaults).loadState()
            )
            XCTAssertEqual(recovered.filePath, "/Users/test/legacy-\(index).mp3")
            XCTAssertEqual(recovered.lastPlayedTime, Double(index))
        }

        XCTAssertEqual(
            defaults.data(forKey: PlaybackStateStore.corruptQuarantineKeys[0]),
            corruptPayloads[2]
        )
        XCTAssertEqual(
            defaults.data(forKey: PlaybackStateStore.corruptQuarantineKeys[1]),
            corruptPayloads[1]
        )
        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains {
                $0.hasPrefix("\(PlaybackStateStore.envelopeKey).quarantine.")
                    && !PlaybackStateStore.corruptQuarantineKeys.contains($0)
            }
        )
    }

    func testOversizedEnvelopeIsProtectedAndPreservedByteForByte() {
        let defaults = makeDefaults()
        let oversizedData = Data(repeating: 0xA5, count: 64 * 1_024 + 1)
        defaults.set(oversizedData, forKey: PlaybackStateStore.envelopeKey)
        defaults.set("/legacy/song.mp3", forKey: PlaybackStateStore.legacyFilePathKey)
        defaults.set(25.0, forKey: PlaybackStateStore.legacyFileTimeKey)
        let store = PlaybackStateStore(userDefaults: defaults)

        XCTAssertNil(store.loadState())
        XCTAssertEqual(store.persistenceState, .protectedCorrupt)

        store.saveState(fileURL: URL(fileURLWithPath: "/new/song.mp3"), time: 1)
        store.rekeyIfMatching(
            from: URL(fileURLWithPath: "/legacy/song.mp3"),
            to: URL(fileURLWithPath: "/moved/song.mp3")
        )
        store.clearIfMatching(URL(fileURLWithPath: "/legacy/song.mp3"))
        store.clearAll()

        XCTAssertEqual(defaults.data(forKey: PlaybackStateStore.envelopeKey), oversizedData)
        XCTAssertTrue(
            PlaybackStateStore.corruptQuarantineKeys.allSatisfy {
                defaults.object(forKey: $0) == nil
            }
        )
        XCTAssertEqual(
            defaults.string(forKey: PlaybackStateStore.legacyFilePathKey),
            "/legacy/song.mp3"
        )
        XCTAssertEqual(defaults.double(forKey: PlaybackStateStore.legacyFileTimeKey), 25.0)
    }

    func testOversizedPathSaveDoesNotOverwriteDurableState() throws {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let durableURL = URL(fileURLWithPath: "/Users/test/durable.mp3")
        store.saveState(fileURL: durableURL, time: 31.5)
        let durableEnvelope = try XCTUnwrap(
            defaults.data(forKey: PlaybackStateStore.envelopeKey)
        )

        store.saveState(fileURL: makeOversizedPathURL(), time: 99)

        XCTAssertEqual(defaults.data(forKey: PlaybackStateStore.envelopeKey), durableEnvelope)
        XCTAssertEqual(
            store.loadState(),
            PlaybackStateStore.State(filePath: durableURL.path, lastPlayedTime: 31.5)
        )
    }

    func testOversizedRekeyDestinationDoesNotOverwriteDurableState() throws {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let durableURL = URL(fileURLWithPath: "/Users/test/durable.mp3")
        store.saveState(fileURL: durableURL, time: 31.5)
        let durableEnvelope = try XCTUnwrap(
            defaults.data(forKey: PlaybackStateStore.envelopeKey)
        )

        XCTAssertEqual(
            store.rekeyIfMatching(from: durableURL, to: makeOversizedPathURL()),
            .failed
        )

        XCTAssertEqual(defaults.data(forKey: PlaybackStateStore.envelopeKey), durableEnvelope)
        XCTAssertEqual(
            store.loadState(),
            PlaybackStateStore.State(filePath: durableURL.path, lastPlayedTime: 31.5)
        )
    }

    func testRekeyIfMatchingUpdatesPathAndPreservesProgress() throws {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let oldURL = URL(fileURLWithPath: "/Users/test/old.mp3")
        let newURL = URL(fileURLWithPath: "/Users/test/new.mp3")
        store.saveState(fileURL: oldURL, time: 47.25)

        XCTAssertEqual(store.rekeyIfMatching(from: oldURL, to: newURL), .durable)

        let state = try XCTUnwrap(store.loadState())
        XCTAssertEqual(state.filePath, newURL.path)
        XCTAssertEqual(state.lastPlayedTime, 47.25)
    }

    func testRekeyIfMatchingDoesNotChangeDifferentPersistedTrack() throws {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let durableURL = URL(fileURLWithPath: "/Users/test/durable.mp3")
        store.saveState(fileURL: durableURL, time: 47.25)
        let durableEnvelope = try XCTUnwrap(
            defaults.data(forKey: PlaybackStateStore.envelopeKey)
        )

        XCTAssertEqual(store.rekeyIfMatching(
            from: URL(fileURLWithPath: "/Users/test/different.mp3"),
            to: URL(fileURLWithPath: "/Users/test/new.mp3")
        ), .unchanged)

        XCTAssertEqual(defaults.data(forKey: PlaybackStateStore.envelopeKey), durableEnvelope)
        XCTAssertEqual(
            store.loadState(),
            PlaybackStateStore.State(filePath: durableURL.path, lastPlayedTime: 47.25)
        )
    }

    func testFlushReportsUserDefaultsSynchronizationFailure() throws {
        let suiteName = "test-playback-state-flush-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            SynchronizationFailingUserDefaults(suiteName: suiteName)
        )
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PlaybackStateStore(userDefaults: defaults)
        store.saveState(
            fileURL: URL(fileURLWithPath: "/Users/test/durable.mp3"),
            time: 8
        )

        XCTAssertFalse(store.flush())
        XCTAssertEqual(store.lastFlushSucceeded, false)
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertEqual(
            store.loadState(),
            PlaybackStateStore.State(
                filePath: "/Users/test/durable.mp3",
                lastPlayedTime: 8
            )
        )
    }

    func testFailedFlushKeepsLatestGenerationRetryable() throws {
        let suiteName = "test-playback-state-flush-retry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            SequencedSynchronizationUserDefaults(suiteName: suiteName)
        )
        defaults.setSynchronizationResults([false, true])
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PlaybackStateStore(userDefaults: defaults)
        store.saveState(
            fileURL: URL(fileURLWithPath: "/Users/test/retry.mp3"),
            time: 19
        )

        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertFalse(store.flush())
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertTrue(store.flush())
        XCTAssertFalse(store.hasUnpersistedChanges)
        XCTAssertEqual(store.lastFlushSucceeded, true)
    }

    func testLegacyKeysSurviveFailedEnvelopeSyncAndCleanupRetries() throws {
        let suiteName = "test-playback-state-legacy-retry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            SequencedSynchronizationUserDefaults(suiteName: suiteName)
        )
        defaults.setSynchronizationResults([false, true, true])
        defaults.set(
            "/Users/test/legacy-retry.mp3",
            forKey: PlaybackStateStore.legacyFilePathKey
        )
        defaults.set(27.5, forKey: PlaybackStateStore.legacyFileTimeKey)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PlaybackStateStore(userDefaults: defaults)

        XCTAssertEqual(try XCTUnwrap(store.loadState()).lastPlayedTime, 27.5)
        XCTAssertNotNil(defaults.object(forKey: PlaybackStateStore.legacyFilePathKey))
        XCTAssertNotNil(defaults.object(forKey: PlaybackStateStore.legacyFileTimeKey))
        XCTAssertTrue(store.hasUnpersistedChanges)

        XCTAssertTrue(store.flush())
        XCTAssertNil(defaults.object(forKey: PlaybackStateStore.legacyFilePathKey))
        XCTAssertNil(defaults.object(forKey: PlaybackStateStore.legacyFileTimeKey))
        XCTAssertFalse(store.hasUnpersistedChanges)
    }

    func testOlderFlushCannotClearNewerConcurrentMutation() throws {
        let suiteName = "test-playback-state-concurrent-flush-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            FirstSynchronizationBlockingUserDefaults(suiteName: suiteName)
        )
        addTeardownBlock {
            defaults.releaseFirstSynchronization()
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PlaybackStateStore(userDefaults: defaults)
        store.saveState(
            fileURL: URL(fileURLWithPath: "/Users/test/older.mp3"),
            time: 1
        )
        let runner = PlaybackStateFlushRunner(store: store)

        runner.start()
        XCTAssertTrue(defaults.waitUntilFirstSynchronizationStarts(timeout: 1))
        store.saveState(
            fileURL: URL(fileURLWithPath: "/Users/test/newer.mp3"),
            time: 2
        )
        defaults.releaseFirstSynchronization()

        XCTAssertEqual(runner.waitForResult(timeout: 1), false)
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertEqual(store.loadState()?.filePath, "/Users/test/newer.mp3")
        XCTAssertTrue(store.flush())
        XCTAssertFalse(store.hasUnpersistedChanges)
    }

    func testRekeyReportsFailureWhenUserDefaultsCannotSynchronize() throws {
        let suiteName = "test-playback-state-rekey-flush-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            SynchronizationFailingUserDefaults(suiteName: suiteName)
        )
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PlaybackStateStore(userDefaults: defaults)
        let oldURL = URL(fileURLWithPath: "/Users/test/old.mp3")
        let newURL = URL(fileURLWithPath: "/Users/test/new.mp3")
        store.saveState(fileURL: oldURL, time: 12)

        XCTAssertEqual(store.rekeyIfMatching(from: oldURL, to: newURL), .failed)
        XCTAssertEqual(store.loadState()?.filePath, newURL.path)
        XCTAssertTrue(store.hasUnpersistedChanges)
    }

    func testClearIfMatchingRemovesMatchingState() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url = URL(fileURLWithPath: "/Users/Test/Music.mp3")
        store.saveFile(url, initialTime: 50.0)

        let beforeClear = store.loadState()
        XCTAssertNotNil(beforeClear)

        store.clearIfMatching(url)

        let afterClear = store.loadState()
        XCTAssertNil(afterClear)
    }

    func testClearIfMatchingUsesCanonicalPathComparison() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url1 = URL(fileURLWithPath: "/Users/Test/Music.mp3")
        store.saveFile(url1, initialTime: 50.0)

        // Different path with .. that canonicalizes to the same
        let url2 = URL(fileURLWithPath: "/Users/Test/Subfolder/../Music.mp3")
        store.clearIfMatching(url2)

        let state = store.loadState()
        XCTAssertNil(state, "Should clear using canonical path comparison")
    }

    func testClearIfMatchingDoesNotRemoveNonMatchingState() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url1 = URL(fileURLWithPath: "/Users/test/song1.mp3")
        store.saveFile(url1, initialTime: 50.0)

        let url2 = URL(fileURLWithPath: "/Users/test/song2.mp3")
        store.clearIfMatching(url2)

        let state = store.loadState()
        XCTAssertNotNil(state, "Should not clear non-matching state")
        XCTAssertEqual(state?.filePath, "/Users/test/song1.mp3")
    }

    func testClearAllRemovesAllState() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: 50.0)

        let beforeClear = store.loadState()
        XCTAssertNotNil(beforeClear)

        store.clearAll()

        let afterClear = store.loadState()
        XCTAssertNil(afterClear)
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertTrue(store.flush())
        XCTAssertFalse(store.hasUnpersistedChanges)
    }

    func testDisablesPersistencePreventsAllOperations() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults, disablesPersistence: true)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: 50.0)

        let state = store.loadState()
        XCTAssertNil(state, "Disabled persistence should prevent saving")
    }

    func testDisablesPersistencePreventsProgressUpdates() {
        let defaults = makeDefaults()
        let store = PlaybackStateStore(userDefaults: defaults, disablesPersistence: true)

        let url = URL(fileURLWithPath: "/Users/test/music.mp3")
        store.saveFile(url, initialTime: 10.0)
        store.saveProgress(50.0)

        let state = store.loadState()
        XCTAssertNil(state, "Disabled persistence should prevent all writes")
    }

    func testStateEquality() {
        let state1 = PlaybackStateStore.State(filePath: "/path/to/file.mp3", lastPlayedTime: 42.5)
        let state2 = PlaybackStateStore.State(filePath: "/path/to/file.mp3", lastPlayedTime: 42.5)
        let state3 = PlaybackStateStore.State(filePath: "/path/to/file.mp3", lastPlayedTime: 50.0)
        let state4 = PlaybackStateStore.State(filePath: "/path/to/other.mp3", lastPlayedTime: 42.5)

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
        XCTAssertNotEqual(state1, state4)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "test-playback-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeOversizedPathURL() -> URL {
        URL(fileURLWithPath: "/" + String(repeating: "x", count: 16 * 1_024 + 1))
    }
}

private final class SynchronizationFailingUserDefaults: UserDefaults {
    override func synchronize() -> Bool {
        false
    }
}

private final class SequencedSynchronizationUserDefaults: UserDefaults {
    private let resultLock = NSLock()
    private var synchronizationResults: [Bool] = []

    func setSynchronizationResults(_ results: [Bool]) {
        resultLock.lock()
        synchronizationResults = results
        resultLock.unlock()
    }

    override func synchronize() -> Bool {
        resultLock.lock()
        defer { resultLock.unlock() }
        guard !synchronizationResults.isEmpty else { return true }
        return synchronizationResults.removeFirst()
    }
}

private final class FirstSynchronizationBlockingUserDefaults: UserDefaults {
    private let condition = NSCondition()
    private var shouldBlockFirstSynchronization = true
    private var firstSynchronizationStarted = false
    private var firstSynchronizationReleased = false

    override func synchronize() -> Bool {
        condition.lock()
        if shouldBlockFirstSynchronization {
            shouldBlockFirstSynchronization = false
            firstSynchronizationStarted = true
            condition.broadcast()
            while !firstSynchronizationReleased {
                condition.wait()
            }
        }
        condition.unlock()
        return true
    }

    func waitUntilFirstSynchronizationStarts(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !firstSynchronizationStarted {
            guard condition.wait(until: deadline) else { break }
        }
        return firstSynchronizationStarted
    }

    func releaseFirstSynchronization() {
        condition.lock()
        firstSynchronizationReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class PlaybackStateFlushRunner: @unchecked Sendable {
    private let store: PlaybackStateStore
    private let condition = NSCondition()
    private var result: Bool?

    init(store: PlaybackStateStore) {
        self.store = store
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let value = store.flush()
            condition.lock()
            result = value
            condition.broadcast()
            condition.unlock()
        }
    }

    func waitForResult(timeout: TimeInterval) -> Bool? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return result
    }
}
