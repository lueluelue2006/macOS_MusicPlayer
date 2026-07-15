import XCTest
@testable import MusicPlayer

final class M3U8CodecTests: XCTestCase {

    // MARK: - Export Tests

    func testExportEmptyPlaylist() throws {
        let playlist = UserPlaylist(name: "Empty", tracks: [])
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertEqual(lines.count, 1)
    }

    func testExportSingleTrack() throws {
        let tracks = [UserPlaylist.Track(path: "/Music/song.mp3")]
        let playlist = UserPlaylist(name: "Single", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines[0], "#EXTM3U")
        XCTAssertEqual(lines[1], "/Music/song.mp3")
    }

    func testExportPreservesTrackOrder() throws {
        let tracks = [
            UserPlaylist.Track(path: "/Music/z.mp3"),
            UserPlaylist.Track(path: "/Music/a.mp3"),
            UserPlaylist.Track(path: "/Music/m.mp3")
        ]
        let playlist = UserPlaylist(name: "Order", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines[1], "/Music/z.mp3")
        XCTAssertEqual(lines[2], "/Music/a.mp3")
        XCTAssertEqual(lines[3], "/Music/m.mp3")
    }

    func testExportPreservesDuplicates() throws {
        let tracks = [
            UserPlaylist.Track(path: "/Music/song.mp3"),
            UserPlaylist.Track(path: "/Music/other.mp3"),
            UserPlaylist.Track(path: "/Music/song.mp3")
        ]
        let playlist = UserPlaylist(name: "Duplicates", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "duplicates must be preserved")
        XCTAssertEqual(lines[1], "/Music/song.mp3")
        XCTAssertEqual(lines[2], "/Music/other.mp3")
        XCTAssertEqual(lines[3], "/Music/song.mp3")
    }

    func testExportWithRelativePaths() throws {
        let baseURL = URL(fileURLWithPath: "/Music")
        let tracks = [
            UserPlaylist.Track(path: "/Music/song1.mp3"),
            UserPlaylist.Track(path: "/Music/subfolder/song2.mp3")
        ]
        let playlist = UserPlaylist(name: "Relative", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: baseURL))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines[1], "song1.mp3")
        XCTAssertEqual(lines[2], "subfolder/song2.mp3")
    }

    func testExportWithPathsOutsideBase() throws {
        let baseURL = URL(fileURLWithPath: "/Music")
        let tracks = [
            UserPlaylist.Track(path: "/Music/inside.mp3"),
            UserPlaylist.Track(path: "/Other/outside.mp3")
        ]
        let playlist = UserPlaylist(name: "Mixed", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: baseURL))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines[1], "inside.mp3")
        XCTAssertEqual(lines[2], "/Other/outside.mp3")
    }

    func testExportEndsWithNewline() throws {
        let tracks = [UserPlaylist.Track(path: "/Music/song.mp3")]
        let playlist = UserPlaylist(name: "Test", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))

        XCTAssertTrue(m3u8.hasSuffix("\n"))
    }

    func testExportNormalizesNonstandardPaths() throws {
        let baseURL = URL(fileURLWithPath: "/Music")
        let tracks = [
            UserPlaylist.Track(path: "/Music/./song1.mp3"),
            UserPlaylist.Track(path: "/Music/subfolder/../song2.mp3")
        ]
        let playlist = UserPlaylist(name: "Normalized", tracks: tracks)
        let m3u8 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: baseURL))

        let lines = m3u8.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines[1], "song1.mp3", "path normalization should resolve .")
        XCTAssertEqual(lines[2], "song2.mp3", "path normalization should resolve ..")
    }

    func testExportIsDeterministic() throws {
        let tracks = [
            UserPlaylist.Track(path: "/Music/a.mp3"),
            UserPlaylist.Track(path: "/Music/b.mp3")
        ]
        let playlist = UserPlaylist(name: "Test", tracks: tracks)

        let export1 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))
        let export2 = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))

        XCTAssertEqual(export1, export2, "export must be deterministic")
    }

    // MARK: - Import Tests

    func testImportEmptyContent() {
        let result = M3U8Codec.parse("")
        XCTAssertEqual(result.entries.count, 0)
        XCTAssertEqual(result.issues.count, 0)
    }

    func testImportOnlyHeader() {
        let result = M3U8Codec.parse("#EXTM3U\n")
        XCTAssertEqual(result.entries.count, 0)
        XCTAssertEqual(result.issues.count, 0)
    }

    func testImportSingleAbsolutePath() {
        let m3u8 = "#EXTM3U\n/Music/song.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].path, "/Music/song.mp3")
        XCTAssertEqual(result.entries[0].lineNumber, 2)
        XCTAssertEqual(result.issues.count, 0)
    }

    func testImportMultipleTracks() {
        let m3u8 = "#EXTM3U\n/Music/track1.mp3\n/Music/track2.mp3\n/Music/track3.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.entries[0].path, "/Music/track1.mp3")
        XCTAssertEqual(result.entries[1].path, "/Music/track2.mp3")
        XCTAssertEqual(result.entries[2].path, "/Music/track3.mp3")
    }

    func testImportPreservesOrder() {
        let m3u8 = "#EXTM3U\n/Music/z.mp3\n/Music/a.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries[0].path, "/Music/z.mp3")
        XCTAssertEqual(result.entries[1].path, "/Music/a.mp3")
    }

    func testImportPreservesDuplicatesWithDiagnostic() {
        let m3u8 = "#EXTM3U\n/Music/song.mp3\n/Music/other.mp3\n/Music/song.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 3, "duplicates must be preserved in entries")
        XCTAssertEqual(result.entries[0].path, "/Music/song.mp3")
        XCTAssertEqual(result.entries[1].path, "/Music/other.mp3")
        XCTAssertEqual(result.entries[2].path, "/Music/song.mp3")

        XCTAssertEqual(result.issues.count, 1, "duplicate should generate diagnostic")
        let issue = result.issues[0]
        XCTAssertEqual(issue.lineNumber, 4, "duplicate appears on line 4")
        XCTAssertEqual(issue.content, "/Music/song.mp3")
        XCTAssertTrue(issue.reason.contains("duplicate") || issue.reason.contains("重复"))
        XCTAssertEqual(issue.firstOccurrenceLineNumber, 2, "must reference first occurrence on line 2")
    }

    func testImportIgnoresComments() {
        let m3u8 = "#EXTM3U\n# Comment\n/Music/song1.mp3\n#EXTINF:123,Title\n/Music/song2.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].path, "/Music/song1.mp3")
        XCTAssertEqual(result.entries[1].path, "/Music/song2.mp3")
    }

    func testImportSkipsEmptyLines() {
        let m3u8 = "#EXTM3U\n\n/Music/song1.mp3\n\n/Music/song2.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.issues.count, 0, "empty lines are not errors")
    }

    func testImportRelativePathWithBaseURL() {
        let baseURL = URL(fileURLWithPath: "/Music")
        let m3u8 = "#EXTM3U\nsong1.mp3\nsubfolder/song2.mp3\n"
        let result = M3U8Codec.parse(m3u8, baseURL: baseURL)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].path, "/Music/song1.mp3")
        XCTAssertEqual(result.entries[1].path, "/Music/subfolder/song2.mp3")
    }

    func testImportFileURLScheme() {
        let m3u8 = "#EXTM3U\nfile:///Music/song.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].path, "/Music/song.mp3")
    }

    func testImportRejectsHTTPURL() {
        let m3u8 = "#EXTM3U\r\nhttp://example.com/stream.mp3\r\n/Music/local.mp3\r\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 1, "http URL should be rejected")
        XCTAssertEqual(result.entries[0].path, "/Music/local.mp3")
        XCTAssertEqual(result.entries[0].lineNumber, 3, "CRLF must not break line numbers for issues")
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues[0].lineNumber, 2)
        XCTAssertEqual(result.issues[0].content, "http://example.com/stream.mp3")
        XCTAssertTrue(result.issues[0].reason.contains("remote") || result.issues[0].reason.contains("URL"))
    }

    func testImportRejectsHTTPSURL() {
        let m3u8 = "#EXTM3U\nhttps://example.com/stream.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 0)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].reason.contains("remote") || result.issues[0].reason.contains("URL"))
    }

    func testImportRejectsCaseInsensitiveHTTP() {
        let m3u8 = "#EXTM3U\nHTTP://example.com/stream.mp3\nHtTpS://example.com/other.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 0, "case-insensitive HTTP/HTTPS should be rejected")
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(result.issues[0].reason.contains("remote") || result.issues[0].reason.contains("URL"))
        XCTAssertTrue(result.issues[1].reason.contains("remote") || result.issues[1].reason.contains("URL"))
    }

    func testImportRejectsUnsupportedScheme() {
        let m3u8 = "#EXTM3U\nftp://server/file.mp3\nsmb://nas/music.mp3\nrtsp://stream/live\n/Music/valid.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 1, "only file:// and local paths should be accepted")
        XCTAssertEqual(result.entries[0].path, "/Music/valid.mp3")
        XCTAssertEqual(result.issues.count, 3)
        XCTAssertTrue(result.issues[0].reason.contains("scheme") || result.issues[0].reason.contains("不支持"))
        XCTAssertTrue(result.issues[1].reason.contains("scheme") || result.issues[1].reason.contains("不支持"))
        XCTAssertTrue(result.issues[2].reason.contains("scheme") || result.issues[2].reason.contains("不支持"))
    }

    func testImportRejectsFileURLWithRemoteHost() throws {
        let m3u8 = "#EXTM3U\nfile://localhost/Music/local.mp3\nfile://remote-server/Music/remote.mp3\n/Music/valid.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.map(\.path), ["/Music/local.mp3", "/Music/valid.mp3"],
                      "file://localhost should be accepted, file://remote-host should be rejected")

        XCTAssertEqual(result.issues.count, 1)
        let issue = try XCTUnwrap(result.issues.first)
        XCTAssertEqual(issue.lineNumber, 3)
        XCTAssertTrue(issue.reason.contains("非本地") || issue.reason.contains("non-local"))
    }

    func testImportWithUTF8BOM() {
        let bom = "\u{FEFF}"
        let m3u8 = bom + "#EXTM3U\n/Music/song.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].path, "/Music/song.mp3")
    }

    func testImportWithCRLF() {
        let m3u8 = "#EXTM3U\r\n/Music/song1.mp3\r\n/Music/song2.mp3\r\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].path, "/Music/song1.mp3")
        XCTAssertEqual(result.entries[0].lineNumber, 2, "CRLF must not break line numbers")
        XCTAssertEqual(result.entries[1].path, "/Music/song2.mp3")
        XCTAssertEqual(result.entries[1].lineNumber, 3, "CRLF must not break line numbers")
    }

    func testImportWithoutHeaderStillWorks() {
        let m3u8 = "/Music/song1.mp3\n/Music/song2.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries.count, 2)
    }

    func testImportLineNumbers() {
        let m3u8 = "#EXTM3U\n# Comment\n/Music/song1.mp3\n\n/Music/song2.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.entries[0].lineNumber, 3)
        XCTAssertEqual(result.entries[1].lineNumber, 5)
    }

    func testImportIssueStructure() {
        let m3u8 = "#EXTM3U\nhttp://example.com/stream.mp3\n/Music/valid.mp3\n"
        let result = M3U8Codec.parse(m3u8)

        XCTAssertEqual(result.issues.count, 1)
        let issue = result.issues[0]
        XCTAssertEqual(issue.lineNumber, 2)
        XCTAssertEqual(issue.content, "http://example.com/stream.mp3")
        XCTAssertFalse(issue.reason.isEmpty)
    }

    // MARK: - Round-trip Tests

    func testRoundTripPreservesAllTracks() throws {
        let originalTracks = [
            UserPlaylist.Track(path: "/Music/track1.mp3"),
            UserPlaylist.Track(path: "/Music/track2.mp3"),
            UserPlaylist.Track(path: "/Music/track3.mp3")
        ]
        let playlist = UserPlaylist(name: "Test", tracks: originalTracks)

        let exported = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))
        let parsed = M3U8Codec.parse(exported)

        XCTAssertEqual(parsed.entries.count, originalTracks.count)
        for (idx, track) in originalTracks.enumerated() {
            XCTAssertEqual(parsed.entries[idx].path, track.path)
        }
    }

    func testRoundTripPreservesOrder() throws {
        let originalTracks = [
            UserPlaylist.Track(path: "/Music/z.mp3"),
            UserPlaylist.Track(path: "/Music/a.mp3"),
            UserPlaylist.Track(path: "/Music/m.mp3")
        ]
        let playlist = UserPlaylist(name: "Order", tracks: originalTracks)

        let exported = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))
        let parsed = M3U8Codec.parse(exported)

        XCTAssertEqual(parsed.entries[0].path, "/Music/z.mp3")
        XCTAssertEqual(parsed.entries[1].path, "/Music/a.mp3")
        XCTAssertEqual(parsed.entries[2].path, "/Music/m.mp3")
    }

    func testRoundTripWithRelativePaths() throws {
        let baseURL = URL(fileURLWithPath: "/Music")
        let originalTracks = [
            UserPlaylist.Track(path: "/Music/song1.mp3"),
            UserPlaylist.Track(path: "/Music/subfolder/song2.mp3")
        ]
        let playlist = UserPlaylist(name: "Relative", tracks: originalTracks)

        let exported = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: baseURL))
        let parsed = M3U8Codec.parse(exported, baseURL: baseURL)

        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(parsed.entries[0].path, "/Music/song1.mp3")
        XCTAssertEqual(parsed.entries[1].path, "/Music/subfolder/song2.mp3")
    }

    func testRoundTripPreservesDuplicates() throws {
        let originalTracks = [
            UserPlaylist.Track(path: "/Music/song.mp3"),
            UserPlaylist.Track(path: "/Music/other.mp3"),
            UserPlaylist.Track(path: "/Music/song.mp3")
        ]
        let playlist = UserPlaylist(name: "Duplicates", tracks: originalTracks)

        let exported = try XCTUnwrap(M3U8Codec.export(playlist: playlist, baseURL: nil))
        let parsed = M3U8Codec.parse(exported)

        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertEqual(parsed.entries[0].path, "/Music/song.mp3")
        XCTAssertEqual(parsed.entries[1].path, "/Music/other.mp3")
        XCTAssertEqual(parsed.entries[2].path, "/Music/song.mp3")

        // Duplicate diagnostic should exist but not block round-trip
        XCTAssertEqual(parsed.issues.count, 1)
        XCTAssertEqual(parsed.issues[0].lineNumber, 4)
    }
}
