import Foundation

struct UserPlaylist: Identifiable, Codable, Equatable {
    struct Track: Codable, Equatable, Hashable {
        /// Stored as a standardized file path (case preserved).
        let path: String
    }

    let id: UUID
    var name: String
    var tracks: [Track]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, tracks: [Track], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

