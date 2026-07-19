import Foundation

struct UserPlaylist: Identifiable, Codable, Equatable {
    struct Track: Identifiable, Codable, Equatable, Hashable, Sendable {
        /// Stable identity used to merge asynchronous enrichment without
        /// reviving a removed track or updating a replacement at the same path.
        let id: UUID
        /// Stored as a standardized file path (case preserved).
        let path: String
        /// Optional file signature for relocation support.
        let signature: FileSignature?

        init(id: UUID = UUID(), path: String, signature: FileSignature? = nil) {
            self.id = id
            self.path = path
            self.signature = signature
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case path
            case signature
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            path = try container.decode(String.self, forKey: .path)
            signature = try container.decodeIfPresent(FileSignature.self, forKey: .signature)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(signature, forKey: .signature)
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
