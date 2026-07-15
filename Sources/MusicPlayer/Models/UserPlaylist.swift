import Foundation

struct UserPlaylist: Identifiable, Codable, Equatable {
    struct Track: Codable, Equatable, Hashable, Sendable {
        /// Stored as a standardized file path (case preserved).
        let path: String
        /// Optional file signature for relocation support.
        let signature: FileSignature?

        init(path: String, signature: FileSignature? = nil) {
            self.path = path
            self.signature = signature
        }
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

