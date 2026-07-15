import XCTest
@testable import MusicPlayer

final class ID3v1ReaderTests: XCTestCase {

    // MARK: - containsCJK Tests

    func testContainsCJKWithPureASCII() {
        XCTAssertFalse(ID3v1Reader.containsCJK("Hello World"))
        XCTAssertFalse(ID3v1Reader.containsCJK("Test123"))
        XCTAssertFalse(ID3v1Reader.containsCJK(""))
    }

    func testContainsCJKWithChineseCharacters() {
        XCTAssertTrue(ID3v1Reader.containsCJK("你好"))
        XCTAssertTrue(ID3v1Reader.containsCJK("世界"))
        XCTAssertTrue(ID3v1Reader.containsCJK("测试"))
    }

    func testContainsCJKWithJapaneseKanji() {
        XCTAssertTrue(ID3v1Reader.containsCJK("日本"))
        XCTAssertTrue(ID3v1Reader.containsCJK("東京"))
    }

    func testContainsCJKWithMixedContent() {
        XCTAssertTrue(ID3v1Reader.containsCJK("Hello 世界"))
        XCTAssertTrue(ID3v1Reader.containsCJK("Test 测试 123"))
    }

    func testContainsCJKWithCJKExtensionA() {
        // U+3400 is first character in CJK Extension A
        XCTAssertTrue(ID3v1Reader.containsCJK("\u{3400}"))
    }

    func testContainsCJKWithCJKCompatibility() {
        // U+F900 is in CJK Compatibility Ideographs
        XCTAssertTrue(ID3v1Reader.containsCJK("\u{F900}"))
    }

    func testContainsCJKWithNonCJKUnicode() {
        XCTAssertFalse(ID3v1Reader.containsCJK("Café"))
        XCTAssertFalse(ID3v1Reader.containsCJK("Здравствуй")) // Cyrillic
        XCTAssertFalse(ID3v1Reader.containsCJK("مرحبا")) // Arabic
    }

    // MARK: - ID3v1 Parsing Tests

    func testReadWithNoTAGSignature() throws {
        let tempFile = try createTempFile(withData: Data(repeating: 0, count: 128))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = ID3v1Reader.read(from: tempFile)
        XCTAssertNil(tag)
    }

    func testReadWithFileTooSmall() throws {
        let tempFile = try createTempFile(withData: Data(repeating: 0, count: 100))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = ID3v1Reader.read(from: tempFile)
        XCTAssertNil(tag)
    }

    func testReadBasicASCIITag() throws {
        let data = makeID3v1Data(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            year: "2024"
        )
        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertEqual(tag.title, "Test Song")
        XCTAssertEqual(tag.artist, "Test Artist")
        XCTAssertEqual(tag.album, "Test Album")
        XCTAssertEqual(tag.year, "2024")
    }

    func testReadEmptyFields() throws {
        let data = makeID3v1Data(
            title: "",
            artist: "",
            album: "",
            year: ""
        )
        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertNil(tag.title)
        XCTAssertNil(tag.artist)
        XCTAssertNil(tag.album)
        XCTAssertNil(tag.year)
    }

    func testReadWithTrailingSpacesAndNulls() throws {
        // Create data with trailing spaces and nulls (common in ID3v1)
        var titleBytes = "Song".data(using: .ascii)!
        titleBytes.append(Data(repeating: 0x20, count: 10)) // spaces
        titleBytes.append(Data(repeating: 0x00, count: 16)) // nulls

        var data = Data([0x54, 0x41, 0x47]) // TAG
        data.append(titleBytes)
        data.append(Data(repeating: 0x00, count: 30)) // artist
        data.append(Data(repeating: 0x00, count: 30)) // album
        data.append(Data(repeating: 0x00, count: 4))  // year
        data.append(Data(repeating: 0x00, count: 30)) // comment
        data.append(0x00) // genre

        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertEqual(tag.title, "Song")
    }

    func testReadID3v11WithTrackNumber() throws {
        // ID3v1.1: comment[28] == 0x00 and comment[29] contains track number
        var data = Data([0x54, 0x41, 0x47]) // TAG
        data.append(Data(repeating: 0x00, count: 30)) // title
        data.append(Data(repeating: 0x00, count: 30)) // artist
        data.append(Data(repeating: 0x00, count: 30)) // album
        data.append(Data(repeating: 0x00, count: 4))  // year

        // Comment: 28 bytes + null byte + track number
        var comment = Data(repeating: 0x00, count: 28)
        comment.append(0x00) // separator
        comment.append(0x05) // track 5
        data.append(comment)
        data.append(0x00) // genre

        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertEqual(tag.track, 5)
    }

    func testReadID3v11WithNonEmptyCommentAndTrack() throws {
        // Regression: track byte should not leak into comment text
        let data = makeID3v1Data(
            title: "Song",
            artist: "Artist",
            album: "Album",
            year: "2024",
            comment: "Great song",
            track: 5
        )
        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertEqual(tag.comment, "Great song")
        XCTAssertEqual(tag.track, 5)
    }

    func testReadWithGBKEncodedChineseText() throws {
        // GBK encoding for "测试" (test)
        let gbkTitle = Data([0xB2, 0xE2, 0xCA, 0xD4])

        var data = Data([0x54, 0x41, 0x47]) // TAG
        var titleField = gbkTitle
        titleField.append(Data(repeating: 0x00, count: 30 - gbkTitle.count))
        data.append(titleField)
        data.append(Data(repeating: 0x00, count: 30)) // artist
        data.append(Data(repeating: 0x00, count: 30)) // album
        data.append(Data(repeating: 0x00, count: 4))  // year
        data.append(Data(repeating: 0x00, count: 30)) // comment
        data.append(0x00) // genre

        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertEqual(tag.title, "测试")
    }

    func testReadGenreField() throws {
        let data = makeID3v1Data(
            title: "Song",
            artist: "Artist",
            album: "Album",
            year: "2024",
            genre: 17 // Rock genre code
        )
        let tempFile = try createTempFile(withData: data)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let tag = try XCTUnwrap(ID3v1Reader.read(from: tempFile))
        XCTAssertEqual(tag.genre, 17)
    }

    func testReadWithNonexistentFile() {
        let nonexistentURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).mp3")
        let tag = ID3v1Reader.read(from: nonexistentURL)
        XCTAssertNil(tag)
    }

    // MARK: - Helper Methods

    private func createTempFile(withData data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).mp3")
        try data.write(to: tempFile)
        return tempFile
    }

    private func makeID3v1Data(
        title: String,
        artist: String,
        album: String,
        year: String,
        comment: String = "",
        track: UInt8? = nil,
        genre: UInt8 = 0
    ) -> Data {
        var data = Data()

        // TAG signature
        data.append(contentsOf: [0x54, 0x41, 0x47])

        // Title (30 bytes)
        data.append(paddedField(title, length: 30))

        // Artist (30 bytes)
        data.append(paddedField(artist, length: 30))

        // Album (30 bytes)
        data.append(paddedField(album, length: 30))

        // Year (4 bytes)
        data.append(paddedField(year, length: 4))

        // Comment (30 bytes, or 28 + null + track for ID3v1.1)
        if let track = track {
            data.append(paddedField(comment, length: 28))
            data.append(0x00)
            data.append(track)
        } else {
            data.append(paddedField(comment, length: 30))
        }

        // Genre (1 byte)
        data.append(genre)

        return data
    }

    private func paddedField(_ string: String, length: Int) -> Data {
        var data = string.data(using: .ascii) ?? Data()
        if data.count > length {
            data = data.prefix(length)
        } else if data.count < length {
            data.append(Data(repeating: 0x00, count: length - data.count))
        }
        return data
    }
}
