import Foundation

/// Pure domain model representing a music track.
/// Separates domain concept from file system and AVFoundation concerns.
struct Track: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let title: String
    let artist: String
    let album: String
    let year: String?
    let genre: String?

    /// Duration in seconds, if known
    var duration: TimeInterval?

    init(
        id: String,
        url: URL,
        title: String,
        artist: String,
        album: String,
        year: String? = nil,
        genre: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.duration = duration
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Bridge to existing AudioFile

extension Track {
    /// Creates a Track from an existing AudioFile (bridge during migration)
    init(from audioFile: AudioFile) {
        self.init(
            id: audioFile.id,
            url: audioFile.url,
            title: audioFile.metadata.title,
            artist: audioFile.metadata.artist,
            album: audioFile.metadata.album,
            year: audioFile.metadata.year,
            genre: audioFile.metadata.genre,
            duration: audioFile.duration
        )
    }
}
