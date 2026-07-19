import Darwin
import XCTest
@testable import MusicPlayer

final class M3U8ImportServiceTests: XCTestCase {
    func testImportAcceptsReadableRegularPlaylistOwnedByAnotherUser() throws {
        let fixture = URL(fileURLWithPath: "/etc/hosts")
        var info = stat()
        guard lstat(fixture.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid != geteuid() else {
            throw XCTSkip("This machine has no suitable readable foreign-owner fixture")
        }

        let result = try M3U8ImportService.importPlaylist(from: fixture)
        XCTAssertEqual(result.playlistName, "hosts")
    }

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M3U8ImportServiceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Basic Import Tests

    func testImportValidM3U8() throws {
        let song1 = tempDir.appendingPathComponent("song1.mp3")
        let song2 = tempDir.appendingPathComponent("song2.mp3")
        try Data().write(to: song1)
        try Data().write(to: song2)

        let m3u8Content = "#EXTM3U\nsong1.mp3\nsong2.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("playlist.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.playlistName, "playlist")
        XCTAssertEqual(result.tracks.map(\.path), [song1.path, song2.path])
        XCTAssertEqual(result.issues.count, 0)
    }

    func testImportSkipsMissingFiles() throws {
        let song1 = tempDir.appendingPathComponent("exists.mp3")
        try Data().write(to: song1)

        let m3u8Content = "#EXTM3U\nexists.mp3\nmissing.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [song1.path])

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .missingFile)
        XCTAssertEqual(issue.lineNumber, 3)
        XCTAssertTrue(issue.path.hasSuffix("missing.mp3"))
        XCTAssertFalse(issue.message.isEmpty, "issue must have displayable message")
    }

    func testImportSkipsDirectories() throws {
        let subdir = tempDir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let song = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: song)

        let m3u8Content = "#EXTM3U\nsubfolder\nsong.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [song.path])

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .directory)
        XCTAssertEqual(issue.lineNumber, 2)
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testImportAcceptsSupportedFormats() throws {
        let formats = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"]
        var m3u8Lines = ["#EXTM3U"]

        for format in formats {
            let file = tempDir.appendingPathComponent("song.\(format)")
            try Data().write(to: file)
            m3u8Lines.append("song.\(format)")
        }

        let m3u8Content = m3u8Lines.joined(separator: "\n") + "\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.count, formats.count)
        XCTAssertEqual(result.issues.count, 0)
    }

    func testImportRejectsUnsupportedExtension() throws {
        let mp3File = tempDir.appendingPathComponent("valid.mp3")
        try Data().write(to: mp3File)

        let txtFile = tempDir.appendingPathComponent("readme.txt")
        try Data().write(to: txtFile)

        let m3u8Content = "#EXTM3U\nvalid.mp3\nreadme.txt\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [mp3File.path])

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .unsupportedFormat)
        XCTAssertTrue(issue.path.hasSuffix("readme.txt"))
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testImportRejectsCaseInsensitiveUnsupportedExtension() throws {
        let mp3File = tempDir.appendingPathComponent("valid.MP3")
        try Data().write(to: mp3File)

        let txtFile = tempDir.appendingPathComponent("readme.TXT")
        try Data().write(to: txtFile)

        let m3u8Content = "#EXTM3U\nvalid.MP3\nreadme.TXT\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.count, 1, "uppercase extensions should be accepted")
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.kind, .unsupportedFormat)
    }

    func testImportRejectsObviousHTMLDisguisedAsAudio() throws {
        let htmlFile = tempDir.appendingPathComponent("fake.mp3")
        try "<!DOCTYPE html><html></html>".write(to: htmlFile, atomically: true, encoding: .utf8)

        let realFile = tempDir.appendingPathComponent("real.mp3")
        try Data().write(to: realFile)

        let m3u8Content = "#EXTM3U\nfake.mp3\nreal.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [realFile.path])

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .obviousNonAudio)
        XCTAssertTrue(issue.path.hasSuffix("fake.mp3"))
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testImportRejectsObviousJSONDisguisedAsAudio() throws {
        let jsonFile = tempDir.appendingPathComponent("fake.mp3")
        try "{\"data\":\"test\"}".write(to: jsonFile, atomically: true, encoding: .utf8)

        let m3u8Content = "#EXTM3U\nfake.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.count, 0)

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .obviousNonAudio)
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testImportPreservesDuplicatesAndReportsThem() throws {
        let song = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: song)

        let m3u8Content = "#EXTM3U\nsong.mp3\nsong.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [song.path, song.path])

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .duplicate)
        XCTAssertEqual(issue.lineNumber, 3)
        XCTAssertEqual(issue.firstOccurrenceLineNumber, 2)
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testImportCodecIssuesPassThrough() throws {
        let song = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: song)

        let m3u8Content = "#EXTM3U\nhttp://remote.com/stream.mp3\nsong.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [song.path])

        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.kind, .codec)
        XCTAssertEqual(issue.lineNumber, 2)
        XCTAssertTrue(issue.message.contains("remote") || issue.message.contains("远程"))
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testImportReturnsResultWithNoValidTracks() throws {
        let txtFile = tempDir.appendingPathComponent("file.txt")
        try Data().write(to: txtFile)

        let m3u8Content = "#EXTM3U\nfile.txt\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.count, 0)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.playlistName, "test")
    }

    func testImportDerivesPlaylistNameFromFilename() throws {
        let song = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: song)

        let m3u8Content = "#EXTM3U\nsong.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("My Favorite Songs.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.playlistName, "My Favorite Songs")
    }

    func testImportHandlesUTF8WithBOM() throws {
        let song = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: song)

        let bom = "\u{FEFF}"
        let m3u8Content = bom + "#EXTM3U\nsong.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.count, 1)
    }

    func testImportThrowsOnInvalidUTF8() {
        let m3u8File = tempDir.appendingPathComponent("invalid.m3u8")
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFF])
        try? invalidUTF8.write(to: m3u8File)

        XCTAssertThrowsError(try M3U8ImportService.importPlaylist(from: m3u8File)) { error in
            guard let serviceError = error as? M3U8ServiceError else {
                XCTFail("Expected M3U8ServiceError, got \(error)")
                return
            }
            XCTAssertEqual(serviceError.code, .invalidUTF8)
        }
    }

    func testImportThrowsOnMissingFile() {
        let nonexistent = tempDir.appendingPathComponent("does-not-exist.m3u8")

        XCTAssertThrowsError(try M3U8ImportService.importPlaylist(from: nonexistent)) { error in
            guard let serviceError = error as? M3U8ServiceError else {
                XCTFail("Expected M3U8ServiceError, got \(error)")
                return
            }
            XCTAssertEqual(serviceError.code, .readFailed)
        }
    }

    func testImportPreservesRelativePathOrder() throws {
        let subdir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let song1 = tempDir.appendingPathComponent("a.mp3")
        let song2 = subdir.appendingPathComponent("b.mp3")
        let song3 = tempDir.appendingPathComponent("c.mp3")
        try Data().write(to: song1)
        try Data().write(to: song2)
        try Data().write(to: song3)

        let m3u8Content = "#EXTM3U\na.mp3\nsub/b.mp3\nc.mp3\n"
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        XCTAssertEqual(result.tracks.map(\.path), [song1.path, song2.path, song3.path])
    }

    // MARK: - Export Tests

    func testExportCreatesValidM3U8() throws {
        let song1 = tempDir.appendingPathComponent("song1.mp3")
        let song2 = tempDir.appendingPathComponent("song2.mp3")

        let tracks = [
            UserPlaylist.Track(path: song1.path),
            UserPlaylist.Track(path: song2.path)
        ]
        let playlist = UserPlaylist(name: "Test Playlist", tracks: tracks)

        let outputFile = tempDir.appendingPathComponent("output.m3u8")
        try M3U8ExportService.exportPlaylist(playlist, to: outputFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))

        let content = try String(contentsOf: outputFile, encoding: .utf8)
        let expected = "#EXTM3U\nsong1.mp3\nsong2.mp3\n"
        XCTAssertEqual(content, expected)
    }

    func testExportUsesRelativePathsFromM3U8Location() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        let song = musicDir.appendingPathComponent("song.mp3")
        let tracks = [UserPlaylist.Track(path: song.path)]
        let playlist = UserPlaylist(name: "Test", tracks: tracks)

        let outputFile = musicDir.appendingPathComponent("playlist.m3u8")
        try M3U8ExportService.exportPlaylist(playlist, to: outputFile)

        let content = try String(contentsOf: outputFile, encoding: .utf8)
        let expected = "#EXTM3U\nsong.mp3\n"
        XCTAssertEqual(content, expected)
    }

    func testExportUsesAbsolutePathsForOutsideFiles() throws {
        let musicDir = tempDir.appendingPathComponent("Music")
        let otherDir = tempDir.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let song = otherDir.appendingPathComponent("song.mp3")
        let tracks = [UserPlaylist.Track(path: song.path)]
        let playlist = UserPlaylist(name: "Test", tracks: tracks)

        let outputFile = musicDir.appendingPathComponent("playlist.m3u8")
        try M3U8ExportService.exportPlaylist(playlist, to: outputFile)

        let content = try String(contentsOf: outputFile, encoding: .utf8)
        let expected = "#EXTM3U\n\(song.path)\n"
        XCTAssertEqual(content, expected)
    }

    func testExportAtomicallyOverwritesExistingFile() throws {
        let outputFile = tempDir.appendingPathComponent("output.m3u8")
        try "old content line 1\nold content line 2\n".write(to: outputFile, atomically: true, encoding: .utf8)

        let tracks = [UserPlaylist.Track(path: tempDir.appendingPathComponent("new.mp3").path)]
        let playlist = UserPlaylist(name: "New", tracks: tracks)

        try M3U8ExportService.exportPlaylist(playlist, to: outputFile)

        let content = try String(contentsOf: outputFile, encoding: .utf8)
        let expected = "#EXTM3U\nnew.mp3\n"
        XCTAssertEqual(content, expected, "atomic write should completely replace old content")
        XCTAssertFalse(content.contains("old content"))
    }
}
