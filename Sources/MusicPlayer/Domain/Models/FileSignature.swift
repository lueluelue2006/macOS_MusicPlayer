import Foundation

/// Comprehensive file signature for cache invalidation.
/// Pure value type capturing multiple identity dimensions to detect file changes reliably.
struct FileSignature: Codable, Equatable, Hashable, Sendable {
    /// Canonical path key (NFD-normalized, symlink-resolved, standardized)
    let pathKey: String

    /// File size in bytes
    let size: Int64

    /// Modification time in nanoseconds since epoch
    let modificationTimeNanoseconds: Int64

    /// File system inode number (if available)
    let inode: UInt64?

    /// File resource identifier (stable across renames, encodes to string)
    let fileResourceIdentifier: String?

    /// Volume identifier (stable across mounts, encodes to string)
    let volumeIdentifier: String?

    init(
        pathKey: String,
        size: Int64,
        modificationTimeNanoseconds: Int64,
        inode: UInt64? = nil,
        fileResourceIdentifier: String? = nil,
        volumeIdentifier: String? = nil
    ) {
        self.pathKey = pathKey
        self.size = size
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.inode = inode
        self.fileResourceIdentifier = fileResourceIdentifier
        self.volumeIdentifier = volumeIdentifier
    }
}
