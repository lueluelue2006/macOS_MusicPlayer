import AppKit
import Darwin
import XCTest
@testable import MusicPlayer

final class AppDelegateExternalFileTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testReadableRegularFileIsSafeRegardlessOfOwner() {
        let regularMode = mode_t(S_IFREG | S_IRUSR)
        let currentUID = geteuid()
        let differentUID = currentUID == uid_t.max ? 0 : currentUID + 1

        XCTAssertTrue(
            AppDelegate.isSafeExternalFile(
                mode: regularMode,
                ownerUID: currentUID,
                isReadable: true
            )
        )
        XCTAssertTrue(
            AppDelegate.isSafeExternalFile(
                mode: regularMode,
                ownerUID: differentUID,
                isReadable: true
            )
        )
    }

    func testUnsafeFileKindsAndUnreadableRegularFileAreRejected() {
        for fileType in [S_IFLNK, S_IFDIR, S_IFIFO, S_IFSOCK] {
            XCTAssertFalse(
                AppDelegate.isSafeExternalFile(
                    mode: mode_t(fileType | S_IRUSR),
                    ownerUID: geteuid(),
                    isReadable: true
                )
            )
        }
        XCTAssertFalse(
            AppDelegate.isSafeExternalFile(
                mode: mode_t(S_IFREG | S_IRUSR),
                ownerUID: geteuid(),
                isReadable: false
            )
        )
    }

    func testExternalPathRejectsNULAndPathCapacityBoundary() {
        let maximumBytes = Int(PATH_MAX)
        let largestAcceptedPath = "/" + String(repeating: "a", count: maximumBytes - 2)
        let pathAtCapacity = "/" + String(repeating: "a", count: maximumBytes - 1)

        XCTAssertTrue(AppDelegate.isSafeExternalPath(largestAcceptedPath))
        XCTAssertFalse(AppDelegate.isSafeExternalPath(pathAtCapacity))
        XCTAssertFalse(
            AppDelegate.isSafeExternalPath(
                "/" + String(repeating: "音", count: maximumBytes / 2)
            )
        )
        XCTAssertFalse(AppDelegate.isSafeExternalPath("/music/bad\0song.mp3"))
        XCTAssertFalse(AppDelegate.isSafeExternalPath("relative/song.mp3"))
    }

    func testExternalURLAcceptsRegularAudioAndRejectsSymlinkDirectoryAndUnsupportedType() throws {
        let audioFile = temporaryDirectory.appendingPathComponent("song.mp3")
        try Data().write(to: audioFile)

        let symbolicLink = temporaryDirectory.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: audioFile
        )

        let directory = temporaryDirectory.appendingPathComponent("folder.mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let unsupportedFile = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data().write(to: unsupportedFile)

        XCTAssertEqual(
            AppDelegate.validExternalAudioURL(audioFile),
            audioFile.standardizedFileURL
        )
        XCTAssertNil(AppDelegate.validExternalAudioURL(symbolicLink))
        XCTAssertNil(AppDelegate.validExternalAudioURL(directory))
        XCTAssertNil(AppDelegate.validExternalAudioURL(unsupportedFile))
        XCTAssertNil(AppDelegate.validExternalAudioURL(URL(string: "https://example.invalid/song.mp3")!))
    }

    func testExternalURLRejectsEmbeddedNULBeforeFileSystemCalls() {
        let path = temporaryDirectory.path + "/bad\0song.mp3"

        XCTAssertNil(
            AppDelegate.validExternalAudioURL(URL(fileURLWithPath: path))
        )
    }

    func testExternalOpenSelectionIsBoundedAndStopsAtFirstValidFile() throws {
        let audioFile = temporaryDirectory.appendingPathComponent("SONG.MP3")
        try Data().write(to: audioFile)
        let invalid = (0 ..< AppDelegate.maximumExternalOpenPaths).map {
            temporaryDirectory.appendingPathComponent("invalid-\($0).txt")
        }

        XCTAssertEqual(
            AppDelegate.firstValidExternalAudioURL(in: invalid.prefix(3) + [audioFile]),
            audioFile.standardizedFileURL
        )
        XCTAssertNil(
            AppDelegate.firstValidExternalAudioURL(in: invalid + [audioFile])
        )
    }

    @MainActor
    func testOpenFileAndOpenFilesReportRejectedRequestsConsistently() throws {
        let unsupportedFile = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data().write(to: unsupportedFile)
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.application(NSApplication.shared, openFile: unsupportedFile.path)
        )
        XCTAssertEqual(
            AppDelegate.openFilesReply(didAcceptRequest: false),
            .failure
        )
        XCTAssertEqual(
            AppDelegate.openFilesReply(didAcceptRequest: true),
            .success
        )
    }
}
