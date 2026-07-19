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
        /// Optional persisted root bookmark identity for removable media.
        let locationID: UUID?
        /// Validated path below a directory root; nil for legacy/single-file rows.
        let relativePath: String?

        init(
            id: UUID = UUID(),
            path: String,
            signature: FileSignature? = nil,
            locationID: UUID? = nil,
            relativePath: String? = nil
        ) {
            self.id = id
            self.path = path
            self.signature = signature
            self.locationID = locationID
            self.relativePath = relativePath
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case path
            case signature
            case locationID
            case relativePath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            path = try container.decode(String.self, forKey: .path)
            signature = try container.decodeIfPresent(FileSignature.self, forKey: .signature)
            locationID = try container.decodeIfPresent(UUID.self, forKey: .locationID)
            relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(signature, forKey: .signature)
            try container.encodeIfPresent(locationID, forKey: .locationID)
            try container.encodeIfPresent(relativePath, forKey: .relativePath)
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
