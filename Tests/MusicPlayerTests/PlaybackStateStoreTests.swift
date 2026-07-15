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
}
