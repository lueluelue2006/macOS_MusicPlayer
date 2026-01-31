import Foundation

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

