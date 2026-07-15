import AVFoundation
import XCTest
@testable import MusicPlayer

final class AudioFileSnifferTests: XCTestCase {
    func testDetectsM4AMagicBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fake.mp3")
        // M4A magic: 4 bytes size, then "ftyp"
        let magic = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]) + Data(repeating: 0, count: 56)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.m4a.rawValue)
    }

    func testDetectsWAVMagicBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fake.mp3")
        // WAV magic: "RIFF" + 4 bytes size + "WAVE"
        let magic = Data("RIFF".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("WAVE".utf8) + Data(repeating: 0, count: 52)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.wav.rawValue)
    }

    func testDetectsAIFFMagicBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fake.mp3")
        // AIFF magic: "FORM" + 4 bytes size + "AIFF"
        let magic = Data("FORM".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("AIFF".utf8) + Data(repeating: 0, count: 52)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.aiff.rawValue)
    }

    func testDetectsAIFCMagicBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fake.mp3")
        // AIFC magic: "FORM" + 4 bytes size + "AIFC"
        let magic = Data("FORM".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("AIFC".utf8) + Data(repeating: 0, count: 52)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.aifc.rawValue)
    }

    func testDetectsCAFMagicBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fake.mp3")
        // CAF magic: "caff"
        let magic = Data("caff".utf8) + Data(repeating: 0, count: 60)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.caf.rawValue)
    }

    func testDetectsMP3WithID3v2Tag() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("file.mp3")
        // MP3 with ID3v2: "ID3" + version + flags
        let magic = Data("ID3".utf8) + Data([0x03, 0x00, 0x00]) + Data(repeating: 0, count: 58)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.mp3.rawValue)
    }

    func testDetectsMP3FrameSync() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("file.mp3")
        // MP3 frame sync: 0xFF 0xFB (11 sync bits set)
        let magic = Data([0xFF, 0xFB]) + Data(repeating: 0, count: 62)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, AVFileType.mp3.rawValue)
    }

    func testDetectsAACFromExtensionWhenFrameSync() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("file.aac")
        // AAC ADTS frame sync: 0xFF 0xF1 (same pattern as MP3)
        let magic = Data([0xFF, 0xF1]) + Data(repeating: 0, count: 62)
        try magic.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertEqual(hint, "public.aac-audio")
    }

    func testReturnsNilForUnknownFormat() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("unknown.bin")
        let data = Data([0x00, 0x01, 0x02, 0x03]) + Data(repeating: 0xFF, count: 60)
        try data.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertNil(hint)
    }

    func testReturnsNilForTooShortFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("short.mp3")
        let data = Data([0xFF, 0xFB]) // Only 2 bytes
        try data.write(to: url)

        let hint = AudioFileSniffer.avAudioPlayerFileTypeHint(at: url)
        XCTAssertNil(hint)
    }

    func testDetectsHTMLDownloadPage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("download.mp3")
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Download Page</title></head>
        <body>Click to download</body>
        </html>
        """
        try Data(html.utf8).write(to: url)

        let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("HTML"))
    }

    func testDetectsJSONMasqueradingAsAudio() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("data.mp3")
        let json = """
        {"error": "File not found"}
        """
        try Data(json.utf8).write(to: url)

        let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("JSON") || reason!.contains("文本"))
    }

    func testDoesNotFlagRealAudioWithID3() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("real.mp3")
        // MP3 with ID3v2 tag
        let magic = Data("ID3".utf8) + Data([0x03, 0x00, 0x00]) + Data(repeating: 0, count: 1018)
        try magic.write(to: url)

        let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url)
        XCTAssertNil(reason, "Real audio file should not be flagged as text")
    }

    func testDoesNotFlagRealAudioWithM4AMagic() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("real.m4a")
        // M4A magic
        let magic = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]) + Data(repeating: 0, count: 1016)
        try magic.write(to: url)

        let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url)
        XCTAssertNil(reason, "Real audio file should not be flagged as text")
    }

    func testHandlesUTF8BOMInTextDetection() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("bom.mp3")
        // UTF-8 BOM + HTML
        let bom = Data([0xEF, 0xBB, 0xBF])
        let html = Data("<html><head></head></html>".utf8)
        try (bom + html).write(to: url)

        let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("HTML"))
    }

    func testReturnsNilForBinaryDataWithNullBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("binary.mp3")
        // Binary data with null bytes (not text)
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0xFF, 0xAA])
        try data.write(to: url)

        let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url)
        XCTAssertNil(reason, "Binary data with null bytes should not be detected as text")
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-sniffer-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
