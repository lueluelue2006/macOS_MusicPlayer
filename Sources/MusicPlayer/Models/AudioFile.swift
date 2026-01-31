import Foundation
import AVFoundation

struct AudioMetadata {
    let title: String
    let artist: String
    let album: String
    let year: String?
    let genre: String?
    let artwork: Data?
    
    init(title: String, artist: String, album: String, year: String?, genre: String?, artwork: Data?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.artwork = artwork
    }

    static func load(from asset: AVAsset, includeArtwork: Bool = true) async -> AudioMetadata {
        let items: [AVMetadataItem]
        if #available(macOS 13.0, *) {
            items = (try? await asset.load(.commonMetadata)) ?? []
        } else {
            items = asset.commonMetadata
        }
        return await load(from: items, asset: asset, includeArtwork: includeArtwork)
    }

    static func load(from metadataItems: [AVMetadataItem], asset: AVAsset?, includeArtwork: Bool = true) async -> AudioMetadata {
        var title = "未知标题"
        var artist = "未知艺术家"
        var album = "未知专辑"
        var year: String?
        var genre: String?
        var artwork: Data?

        for item in metadataItems {
            guard let key = item.commonKey?.rawValue else { continue }

            switch key {
            case "title":
                if let value = await loadStringValue(from: item) {
                    title = value
                }
            case "artist":
                if let value = await loadStringValue(from: item) {
                    artist = value
                }
            case "albumName":
                if let value = await loadStringValue(from: item) {
                    album = value
                }
            case "creationDate":
                if let value = await loadStringValue(from: item) {
                    year = value
                }
            case "type":
                if let value = await loadStringValue(from: item) {
                    genre = value
                }
            case "artwork":
                if includeArtwork, let value = await loadDataValue(from: item) {
                    artwork = value
                }
            default:
                break
            }
        }

        // 当缺少 ID3v2/QuickTime 信息或疑似乱码时，尝试回退读取 ID3v1（支持 GBK/GB18030 解码）
        if let urlAsset = asset as? AVURLAsset {
            if let v1 = ID3v1Reader.read(from: urlAsset.url) {
                // 条件1：缺失 -> 直接回补
                if title == "未知标题", let t = v1.title { title = t }
                if artist == "未知艺术家", let a = v1.artist { artist = a }
                if album == "未知专辑", let al = v1.album { album = al }
                if year == nil, let y = v1.year { year = y }
                // 条件2：疑似乱码（无中文）且 v1 含中文 -> 以 v1 覆盖
                if let t = v1.title, ID3v1Reader.containsCJK(t), !ID3v1Reader.containsCJK(title) { title = t }
                if let a = v1.artist, ID3v1Reader.containsCJK(a), !ID3v1Reader.containsCJK(artist) { artist = a }
                if let al = v1.album, ID3v1Reader.containsCJK(al), !ID3v1Reader.containsCJK(album) { album = al }
            }
        }

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            year: year,
            genre: genre,
            artwork: artwork
        )
    }

    private static func loadStringValue(from item: AVMetadataItem) async -> String? {
        if #available(macOS 13.0, *) {
            return try? await item.load(.stringValue)
        } else {
            return item.stringValue
        }
    }

    private static func loadDataValue(from item: AVMetadataItem) async -> Data? {
        if #available(macOS 13.0, *) {
            return try? await item.load(.dataValue)
        } else {
            return item.dataValue
        }
    }
}

struct AudioFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let metadata: AudioMetadata
    // Lazy-loaded lyrics timeline cache key by url
    var lyricsTimeline: LyricsTimeline?
    
    init(url: URL, metadata: AudioMetadata, lyricsTimeline: LyricsTimeline? = nil) {
        self.url = url
        self.metadata = metadata
        self.lyricsTimeline = lyricsTimeline
    }
    
    static func == (lhs: AudioFile, rhs: AudioFile) -> Bool {
        lhs.id == rhs.id
    }
}
