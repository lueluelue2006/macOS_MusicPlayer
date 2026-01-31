import Foundation
import CoreFoundation

// Lightweight ID3v1 reader with GBK/GB18030 fallback decoding
struct ID3v1Tag {
    var title: String?
    var artist: String?
    var album: String?
    var year: String?
    var comment: String?
    var track: UInt8?
    var genre: UInt8?
}

enum ID3v1Reader {
    /// Read ID3v1/1.1 tag from file tail. Returns nil if no TAG signature exists.
    static func read(from url: URL) -> ID3v1Tag? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let fileSize = try handle.seekToEnd()
            guard fileSize >= 128 else { return nil }
            try handle.seek(toOffset: fileSize - 128)
            let data = try handle.read(upToCount: 128) ?? Data()
            guard data.count == 128 else { return nil }
            // Signature 'TAG'
            if !(data[0] == 0x54 && data[1] == 0x41 && data[2] == 0x47) { return nil }

            func field(_ range: Range<Int>) -> Data {
                return data.subdata(in: range)
            }
            // Trim trailing nulls and spaces
            func trim(_ d: Data) -> Data {
                var bytes = Array(d)
                while let last = bytes.last, (last == 0x00 || last == 0x20) { bytes.removeLast() }
                return Data(bytes)
            }
            // ID3v1.1 track number in comment[29] if comment[28] == 0
            let rawTitle = trim(field(3..<33))
            let rawArtist = trim(field(33..<63))
            let rawAlbum = trim(field(63..<93))
            let rawYear = trim(field(93..<97))
            var rawComment = field(97..<127)
            var track: UInt8? = nil
            if rawComment.count == 30 && rawComment[28] == 0x00 {
                track = rawComment[29]
            }
            rawComment = trim(rawComment)
            let genre = data[127]

            let title = decodeText(rawTitle)
            let artist = decodeText(rawArtist)
            let album = decodeText(rawAlbum)
            let year = decodeYear(rawYear)
            let comment = decodeText(rawComment)

            return ID3v1Tag(title: emptyToNil(title),
                            artist: emptyToNil(artist),
                            album: emptyToNil(album),
                            year: emptyToNil(year),
                            comment: emptyToNil(comment),
                            track: track,
                            genre: genre)
        } catch {
            return nil
        }
    }

    private static func emptyToNil(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    /// Heuristic decode for ID3v1 text field (30 bytes max)
    /// Priority:
    /// - ASCII if all bytes < 0x80
    /// - Try GB18030 (common for zh-CN) if high bytes exist and result contains CJK
    /// - Else fall back to ISO-8859-1
    private static func decodeText(_ data: Data) -> String {
        if data.isEmpty { return "" }
        let hasHighBytes = data.contains { $0 >= 0x80 }
        if !hasHighBytes {
            return String(data: data, encoding: .ascii) ?? String(decoding: data, as: Unicode.ASCII.self)
        }
        // Try GB18030
        if let s = decode(data, as: .GB_18030_2000), containsCJK(s) {
            return s
        }
        // Fallback to ISO Latin-1
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        // Last resort: try UTF-8 then GBK
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = decode(data, as: .GB_18030_2000) { return s }
        return String(decoding: data, as: Unicode.ASCII.self)
    }

    private static func decodeYear(_ data: Data) -> String {
        // 4 ASCII digits typically
        let s = String(data: data, encoding: .ascii) ?? String(decoding: data, as: Unicode.ASCII.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ data: Data, as cfEnc: CFStringEncodings) -> String? {
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        let enc = String.Encoding(rawValue: nsEnc)
        return String(data: data, encoding: enc)
    }

    static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,      // CJK Unified Ideographs
                 0x3400...0x4DBF,      // CJK Extension A
                 0x20000...0x2A6DF,    // CJK Extension B
                 0x2A700...0x2B73F,    // CJK Extension C
                 0x2B740...0x2B81F,    // CJK Extension D
                 0x2B820...0x2CEAF,    // CJK Extension E
                 0x2CEB0...0x2EBEF,    // CJK Extension F
                 0xF900...0xFAFF,      // CJK Compatibility Ideographs
                 0x2F800...0x2FA1F:    // CJK Compatibility Ideographs Supplement
                return true
            default:
                continue
            }
        }
        return false
    }
}
