import XCTest
@testable import MusicPlayer

/// Tests for PlaylistManager navigation invariants: next/previous/peek consistency,
/// unplayable skipping, and termination guarantees.
final class PlaylistNavigationTests: XCTestCase {

    private var manager: PlaylistManager!

    override func setUp() {
        super.setUp()
        manager = PlaylistManager(disablePersistence: true)
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Empty Queue Boundaries

    func testNextFileReturnsNilWhenQueueEmpty() {
        XCTAssertNil(manager.nextFile(isShuffling: false))
        XCTAssertNil(manager.nextFile(isShuffling: true))
    }

    func testPeekNextFileReturnsNilWhenQueueEmpty() {
        XCTAssertNil(manager.peekNextFile(isShuffling: false))
        XCTAssertNil(manager.peekNextFile(isShuffling: true))
    }

    func testPreviousFileReturnsNilWhenQueueEmpty() {
        XCTAssertNil(manager.previousFile(isShuffling: false))
        XCTAssertNil(manager.previousFile(isShuffling: true))
    }

    // MARK: - Single File Boundaries

    func testNextFileWithSingleFileWrapsAround() {
        let file = makeDummyFile(name: "track1.mp3")
        manager.audioFiles = [file]
        manager.currentIndex = 0

        let next = manager.nextFile(isShuffling: false)
        XCTAssertEqual(next?.id, file.id)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testPreviousFileWithSingleFileWrapsAround() {
        let file = makeDummyFile(name: "track1.mp3")
        manager.audioFiles = [file]
        manager.currentIndex = 0

        let prev = manager.previousFile(isShuffling: false)
        XCTAssertEqual(prev?.id, file.id)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    // MARK: - Peek Does Not Mutate State

    func testPeekNextDoesNotChangeCurrentIndex() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        let peeked = manager.peekNextFile(isShuffling: false)
        XCTAssertEqual(peeked?.id, files[1].id)
        XCTAssertEqual(manager.currentIndex, 0, "peek must not change currentIndex")
    }

    func testPeekNextConsistentWithNextFile() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        let peeked = manager.peekNextFile(isShuffling: false)
        let next = manager.nextFile(isShuffling: false)

        XCTAssertEqual(peeked?.id, next?.id, "peek and next must return the same file")
    }

    // MARK: - Sequential Navigation

    func testNextFileAdvancesSequentially() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        let next1 = manager.nextFile(isShuffling: false)
        XCTAssertEqual(next1?.id, files[1].id)
        XCTAssertEqual(manager.currentIndex, 1)

        let next2 = manager.nextFile(isShuffling: false)
        XCTAssertEqual(next2?.id, files[2].id)
        XCTAssertEqual(manager.currentIndex, 2)
    }

    func testNextFileWrapsAroundAtEnd() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 2

        let next = manager.nextFile(isShuffling: false)
        XCTAssertEqual(next?.id, files[0].id)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testPreviousFileMovesBackward() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 2

        let prev1 = manager.previousFile(isShuffling: false)
        XCTAssertEqual(prev1?.id, files[1].id)
        XCTAssertEqual(manager.currentIndex, 1)

        let prev2 = manager.previousFile(isShuffling: false)
        XCTAssertEqual(prev2?.id, files[0].id)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testPreviousFileWrapsAroundAtBeginning() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        let prev = manager.previousFile(isShuffling: false)
        XCTAssertEqual(prev?.id, files[2].id)
        XCTAssertEqual(manager.currentIndex, 2)
    }

    // MARK: - Unplayable Skipping

    @MainActor
    func testNextFileSkipsUnplayableInSequentialMode() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0
        manager.markUnplayable(files[1].url, reason: "Test error")

        let next = manager.nextFile(isShuffling: false)
        XCTAssertEqual(next?.id, files[2].id, "should skip unplayable file")
        XCTAssertEqual(manager.currentIndex, 2)
    }

    @MainActor
    func testPeekNextFileSkipsUnplayable() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0
        manager.markUnplayable(files[1].url, reason: "Test error")

        let peeked = manager.peekNextFile(isShuffling: false)
        XCTAssertEqual(peeked?.id, files[2].id, "peek should also skip unplayable")
        XCTAssertEqual(manager.currentIndex, 0, "peek must not change currentIndex")
    }

    @MainActor
    func testPreviousFileSkipsUnplayable() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 2
        manager.markUnplayable(files[1].url, reason: "Test error")

        let prev = manager.previousFile(isShuffling: false)
        XCTAssertEqual(prev?.id, files[0].id, "should skip unplayable file backward")
        XCTAssertEqual(manager.currentIndex, 0)
    }

    // MARK: - All Unplayable Termination

    @MainActor
    func testNextFileReturnsNilWhenAllUnplayable() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        for file in files {
            manager.markUnplayable(file.url, reason: "Test error")
        }

        let next = manager.nextFile(isShuffling: false)
        XCTAssertNil(next, "should return nil when all files are unplayable")
    }

    @MainActor
    func testPeekNextFileReturnsNilWhenAllUnplayable() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        for file in files {
            manager.markUnplayable(file.url, reason: "Test error")
        }

        let peeked = manager.peekNextFile(isShuffling: false)
        XCTAssertNil(peeked, "peek should return nil when all files are unplayable")
    }

    @MainActor
    func testPreviousFileReturnsNilWhenAllUnplayable() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        for file in files {
            manager.markUnplayable(file.url, reason: "Test error")
        }

        let prev = manager.previousFile(isShuffling: false)
        XCTAssertNil(prev, "should return nil when all files are unplayable")
    }

    // MARK: - Shuffle Mode

    @MainActor
    func testShuffleModeReturnsFiles() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        let next = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(next, "shuffle should return a file")
        XCTAssertTrue(files.contains(where: { $0.id == next?.id }), "should be from queue")
    }

    @MainActor
    func testPeekInShuffleModeDoesNotChangeState() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        let initialIndex = manager.currentIndex
        _ = manager.peekNextFile(isShuffling: true)
        XCTAssertEqual(manager.currentIndex, initialIndex, "peek in shuffle must not change index")
    }

    @MainActor
    func testShuffleModeSkipsUnplayable() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0
        manager.markUnplayable(files[1].url, reason: "Test error")

        // Get multiple files to verify none are the unplayable one
        var results = Set<String>()
        for _ in 0..<10 {
            if let file = manager.nextFile(isShuffling: true) {
                results.insert(file.id)
            }
        }

        XCTAssertFalse(results.contains(files[1].id), "shuffle should never return unplayable file")
    }

    // MARK: - Shuffle History Navigation

    @MainActor
    func testShuffleNextThenPreviousReturnsOriginalFile() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0
        let originalFile = files[0]

        // Shuffle next to a different track
        let nextFile = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(nextFile, "shuffle next should return a file")

        // Previous should return to the original track
        let prevFile = manager.previousFile(isShuffling: true)
        XCTAssertEqual(prevFile?.id, originalFile.id, "previous after shuffle next must return original file")
    }

    @MainActor
    func testShuffleNextPreviousNextReturnsConsistentFile() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0

        // Navigate: current -> B -> back to current -> B again
        let firstNext = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(firstNext)

        _ = manager.previousFile(isShuffling: true)

        let secondNext = manager.nextFile(isShuffling: true)
        XCTAssertEqual(secondNext?.id, firstNext?.id, "re-navigating forward must return same file")
    }

    @MainActor
    func testShufflePreviousWithNoHistoryReturnsNil() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 1

        // First previous in shuffle mode with no history should return nil
        let prevFile = manager.previousFile(isShuffling: true)
        XCTAssertNil(prevFile, "previous with no shuffle history should return nil")
    }

    @MainActor
    func testShuffleMultipleNextThenPreviousRetraceHistory() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3"),
            makeDummyFile(name: "track4.mp3")
        ]
        manager.audioFiles = files
        manager.currentIndex = 0
        let startFile = files[0]

        // Navigate forward: A -> B -> C
        let fileB = manager.nextFile(isShuffling: true)
        let fileC = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(fileB)
        XCTAssertNotNil(fileC)

        // Navigate backward: C -> B -> A
        let backToB = manager.previousFile(isShuffling: true)
        XCTAssertEqual(backToB?.id, fileB?.id, "first previous should retrace to B")

        let backToA = manager.previousFile(isShuffling: true)
        XCTAssertEqual(backToA?.id, startFile.id, "second previous should retrace to A")
    }

    // MARK: - Playlist Scope Shuffle History

    @MainActor
    func testPlaylistScopeShuffleNextThenPreviousReturnsOriginalFile() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        let playlistID = UUID()
        let trackURLs = files.map { $0.url }
        manager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: trackURLs)
        manager.currentIndex = 0
        let originalFile = files[0]

        // Shuffle next to a different track in playlist scope
        let nextFile = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(nextFile, "playlist shuffle next should return a file")

        // Previous should return to the original track
        let prevFile = manager.previousFile(isShuffling: true)
        XCTAssertEqual(prevFile?.id, originalFile.id, "playlist previous after shuffle next must return original file")
    }

    @MainActor
    func testPlaylistScopeShuffleNextPreviousNextReturnsConsistentFile() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        let playlistID = UUID()
        let trackURLs = files.map { $0.url }
        manager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: trackURLs)
        manager.currentIndex = 0

        // Navigate: current -> B -> back to current -> B again
        let firstNext = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(firstNext)

        _ = manager.previousFile(isShuffling: true)

        let secondNext = manager.nextFile(isShuffling: true)
        XCTAssertEqual(secondNext?.id, firstNext?.id, "playlist re-navigating forward must return same file")
    }

    @MainActor
    func testPlaylistScopeShufflePreviousWithNoHistoryReturnsNil() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3")
        ]
        manager.audioFiles = files
        let playlistID = UUID()
        let trackURLs = files.map { $0.url }
        manager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: trackURLs)
        manager.currentIndex = 1

        // First previous in playlist shuffle mode with no history should return nil
        let prevFile = manager.previousFile(isShuffling: true)
        XCTAssertNil(prevFile, "playlist previous with no shuffle history should return nil")
    }

    @MainActor
    func testPlaylistScopeShuffleMultipleNextThenPreviousRetraceHistory() {
        let files = [
            makeDummyFile(name: "track1.mp3"),
            makeDummyFile(name: "track2.mp3"),
            makeDummyFile(name: "track3.mp3"),
            makeDummyFile(name: "track4.mp3")
        ]
        manager.audioFiles = files
        let playlistID = UUID()
        let trackURLs = files.map { $0.url }
        manager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: trackURLs)
        manager.currentIndex = 0
        let startFile = files[0]

        // Navigate forward: A -> B -> C
        let fileB = manager.nextFile(isShuffling: true)
        let fileC = manager.nextFile(isShuffling: true)
        XCTAssertNotNil(fileB)
        XCTAssertNotNil(fileC)

        // Navigate backward: C -> B -> A
        let backToB = manager.previousFile(isShuffling: true)
        XCTAssertEqual(backToB?.id, fileB?.id, "playlist first previous should retrace to B")

        let backToA = manager.previousFile(isShuffling: true)
        XCTAssertEqual(backToA?.id, startFile.id, "playlist second previous should retrace to A")
    }

    // MARK: - Helper Methods

    private func makeDummyFile(name: String) -> AudioFile {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        let metadata = AudioMetadata(
            title: name,
            artist: "Test Artist",
            album: "Test Album",
            year: nil,
            genre: nil,
            artwork: nil
        )
        return AudioFile(url: url, metadata: metadata)
    }
}
