import Foundation
import AVFoundation

enum AudioFileSniffer {
    /// Returns a user-facing reason if the file is very likely not an audio file
    /// (e.g. an HTML download page saved with a `.mp3` extension).
    static func nonAudioReasonIfClearlyText(at url: URL) -> String? {
        guard url.isFileURL else { return nil }

        let header = readHeader(url: url, length: 1024)
        guard !header.isEmpty else { return nil }

        if looksLikeKnownAudioMagic(header) {
            return nil
        }

        guard let text = decodePossiblyTextHeader(header) else { return nil }
        let lowered = text.lowercased()

        if looksLikeHTML(lowered) {
            return "不是音频文件（疑似网页 HTML 下载页）：\(url.lastPathComponent)"
        }

        // Conservative: only flag obvious “text masquerading as audio”.
        if lowered.hasPrefix("{") || lowered.hasPrefix("[") {
            return "不是音频文件（疑似文本/JSON 内容）：\(url.lastPathComponent)"
        }

        return nil
    }

    /// Best-effort file type hint for `AVAudioPlayer(contentsOf:fileTypeHint:)`, based on magic bytes.
    /// This helps with files whose extension doesn't match the actual container (e.g. a `.mp3` file name
    /// that is actually an `.m4a` AAC file).
    static func avAudioPlayerFileTypeHint(at url: URL) -> String? {
        guard url.isFileURL else { return nil }

        let header = readHeader(url: url, length: 64)
        guard header.count >= 12 else { return nil }

        func ascii(_ start: Int, _ length: Int) -> String? {
            guard header.count >= start + length else { return nil }
            return String(bytes: header[start..<(start + length)], encoding: .ascii)
        }

        // MP4/M4A (....ftyp)
        if ascii(4, 4) == "ftyp" {
            return AVFileType.m4a.rawValue
        }

        // WAV (RIFF....WAVE)
        if ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" {
            return AVFileType.wav.rawValue
        }

        // AIFF/AIFC (FORM....AIFF/AIFC)
        if ascii(0, 4) == "FORM" {
            let formType = ascii(8, 4)
            if formType == "AIFF" { return AVFileType.aiff.rawValue }
            if formType == "AIFC" { return AVFileType.aifc.rawValue }
        }

        // CAF (caff)
        if ascii(0, 4) == "caff" {
            return AVFileType.caf.rawValue
        }

        // MP3 with ID3v2 tag
        if ascii(0, 3) == "ID3" {
            return AVFileType.mp3.rawValue
        }

        // MP3 / AAC ADTS frame sync (0xFFFx)
        if header[0] == 0xFF, (header[1] & 0xE0) == 0xE0 {
            // We can't reliably distinguish MP3 vs AAC ADTS from just the sync word.
            // If the extension says AAC, hint AAC; otherwise prefer MP3 as the common case.
            if url.pathExtension.lowercased() == "aac" {
                return "public.aac-audio"
            }
            return AVFileType.mp3.rawValue
        }

        return nil
    }

    private static func readHeader(url: URL, length: Int) -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            return Data()
        }
    }

    private static func decodePossiblyTextHeader(_ data: Data) -> String? {
        if data.isEmpty { return nil }
        if data.contains(0) { return nil } // NUL usually indicates binary data

        var trimmed = data
        // UTF-8 BOM
        if trimmed.count >= 3, trimmed[0] == 0xEF, trimmed[1] == 0xBB, trimmed[2] == 0xBF {
            trimmed = trimmed.advanced(by: 3)
        }
        // Leading whitespace/newlines
        while let first = trimmed.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            trimmed = trimmed.advanced(by: 1)
        }

        return String(data: trimmed, encoding: .utf8)
    }

    private static func looksLikeHTML(_ lowered: String) -> Bool {
        if lowered.hasPrefix("<!doctype html") { return true }
        if lowered.hasPrefix("<html") { return true }
        if lowered.contains("<html") { return true }
        if lowered.contains("<head") && lowered.contains("<meta") { return true }
        return false
    }

    private static func looksLikeKnownAudioMagic(_ data: Data) -> Bool {
        if data.count < 12 { return false }

        func ascii(_ start: Int, _ length: Int) -> String? {
            guard data.count >= start + length else { return nil }
            return String(bytes: data[start..<(start + length)], encoding: .ascii)
        }

        // MP3 with ID3v2 tag
        if ascii(0, 3) == "ID3" { return true }
        // MP3 / AAC ADTS frame sync (0xFFFx)
        if data[0] == 0xFF, (data[1] & 0xE0) == 0xE0 { return true }

        // MP4/M4A (....ftyp)
        if ascii(4, 4) == "ftyp" { return true }
        // WAV (RIFF....WAVE)
        if ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" { return true }
        // AIFF/AIFC (FORM....AIFF/AIFC)
        if ascii(0, 4) == "FORM", (ascii(8, 4) == "AIFF" || ascii(8, 4) == "AIFC") { return true }
        // CAF (caff)
        if ascii(0, 4) == "caff" { return true }
        // FLAC (fLaC)
        if ascii(0, 4) == "fLaC" { return true }
        // OGG (OggS)
        if ascii(0, 4) == "OggS" { return true }

        return false
    }
}

private extension Data {
    func advanced(by count: Int) -> Data {
        guard count > 0 else { return self }
        guard self.count > count else { return Data() }
        return self.subdata(in: count..<self.count)
    }
}
