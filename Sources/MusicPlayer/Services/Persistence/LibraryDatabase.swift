import Foundation

enum LibraryDatabaseError: Error, Equatable, LocalizedError, Sendable {
    case invalidData(String)
    case readOnly
    case inconsistentState(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let detail):
            return "音乐库数据无效：\(detail)"
        case .readOnly:
            return "音乐库处于只读保护模式"
        case .inconsistentState(let detail):
            return "音乐库状态不一致：\(detail)"
        }
    }
}

/// Result of one revision-guarded authoritative write. Callers that need an
/// optimistic compare-and-set receipt use the overloads with
/// `expectedRevision`; compatibility wrappers throw for stale/conflicting data.
enum LibraryRevisionCommitResult: Equatable, Sendable {
    case committed(revision: UInt64)
    case alreadyCurrent(revision: UInt64)
    case stale(storedRevision: UInt64)
    case conflict(revision: UInt64)

    var isDurable: Bool {
        switch self {
        case .committed, .alreadyCurrent: return true
        case .stale, .conflict: return false
        }
    }
}

struct LibraryQueueEntry: Equatable, Sendable {
    let id: UUID
    let sortKey: Int64
    let path: String
    let signature: FileSignature?
    let locationID: UUID?
    let relativePath: String?
}

struct LibraryQueueRekeyIntent: Equatable, Sendable {
    let id: UUID
    let oldPath: String
    let newPath: String
    let createdAt: Date
}

struct LibraryQueueSnapshot: Equatable, Sendable {
    let revision: UInt64
    let entries: [LibraryQueueEntry]
    let currentEntryID: UUID?
    let pendingRekeys: [LibraryQueueRekeyIntent]
}

struct LibraryPlaylistsSnapshot: Equatable, Sendable {
    let revision: UInt64
    let playlists: [UserPlaylist]
    let pendingCleanup: [PlaylistCleanupIntent]
}

struct LibraryWeightsSnapshot: Equatable, Sendable {
    let revision: UInt64
    let queueLevels: [String: Int]
    let playlistLevels: [UUID: [String: Int]]
}

struct LibraryPlaybackSession: Equatable, Sendable {
    enum Scope: Int, Equatable, Sendable {
        case queue = 0
        case playlist = 1
    }

    let revision: UInt64
    let scope: Scope
    let playlistID: UUID?
    let scopeTrackID: UUID?
    let queueEntryID: UUID?
    let fallbackPath: String?
    let positionMilliseconds: Int64
}

struct LibraryMigrationSource: Equatable, Sendable {
    let name: String
    let sourceVersion: Int?
    let byteCount: Int
    let modificationTimeNanoseconds: Int64
    let digest: String
    let importedAt: Date
}

struct LibraryLocationRecord: Equatable, Sendable {
    let location: LibraryLocation
    let updatedAt: Date
}

struct LibraryLocationReferenceCounts: Equatable, Sendable {
    let queueEntries: Int
    let playlistTracks: Int

    var total: Int { queueEntries + playlistTracks }
}

/// The single authoritative SQLite connection for queue, playlists, weights,
/// cleanup debt, external-media roots, and the resumable playback session.
///
/// The public value types intentionally remain independent of UI state. Stores
/// can therefore capture a COW snapshot on the main actor and commit it on their
/// existing utility queues without transferring ObservableObject ownership.
final class LibraryDatabase: @unchecked Sendable {
    static let applicationID: Int32 = 0x4D50_4C42 // "MPLB"
    static let schemaVersion = 1

    enum AccessMode: Equatable, Sendable {
        case writable
        case readOnlyFuture(version: Int)
        case readOnlyForeign(applicationID: Int32)
    }

    private enum Domain: String {
        case locations
        case queue
        case playlists
        case weights
        case session
    }

    private enum Limits {
        static let maximumQueueEntries = 100_000
        static let maximumPlaylists = 2_000
        static let maximumPlaylistTracks = 50_000
        static let maximumCleanupIntents = 10_000
        static let maximumRekeyIntents = 4_096
        static let maximumLibraryLocations = 4_096
        static let maximumAggregateBookmarkBytes = 8 * 1_024 * 1_024
        static let maximumPathBytes = 16 * 1_024
        static let maximumNameBytes = 512
        static let maximumIdentifierBytes = 64 * 1_024
        static let insertChunkSize = 48
    }

    let fileURL: URL
    let accessMode: AccessMode
    private let database: SQLiteDatabase

    init(
        fileURL: URL,
        configuration: SQLiteConfiguration = LibraryDatabase.productionConfiguration
    ) throws {
        let database = try SQLiteDatabase(
            fileURL: fileURL,
            schema: Self.schema,
            configuration: configuration
        )
        self.database = database
        self.fileURL = database.fileURL
        switch database.accessMode {
        case .writable:
            accessMode = .writable
        case .readOnlyFuture(let version):
            accessMode = .readOnlyFuture(version: version)
        case .readOnlyForeign(let applicationID):
            accessMode = .readOnlyForeign(applicationID: applicationID)
        }
    }

    static var productionConfiguration: SQLiteConfiguration {
        var configuration = SQLiteConfiguration.production
        configuration.pageCacheKiB = 512
        configuration.journalSizeLimitBytes = 1_048_576
        configuration.walAutoCheckpointPages = 128
        configuration.durability = .full
        configuration.keepsTemporaryTablesInMemory = false
        configuration.validatesIntegrityOnOpen = true
        return configuration
    }

    func close() {
        database.close()
    }

    func checkpoint() throws {
        try ensureWritable()
        try database.checkpoint()
    }

    func quickCheck() throws -> Bool {
        try database.readTransaction { connection in
            let rows = try connection.query("PRAGMA quick_check(1)") { $0.string(at: 0) }
            guard rows.count == 1, rows[0] == "ok" else { return false }
            var hasForeignKeyViolation = false
            _ = try connection.forEachRow("PRAGMA foreign_key_check") { _ in
                hasForeignKeyViolation = true
                return false
            }
            return !hasForeignKeyViolation
        }
    }

    // MARK: - Migration authority

    func hasImportedSource(_ sourceName: String) throws -> Bool {
        guard Self.isValidMetaKey(sourceName) else {
            throw LibraryDatabaseError.invalidData("迁移源名称越界")
        }
        return try database.scalarInt(
            "SELECT COUNT(*) FROM migration_sources WHERE source_name = ?",
            bindings: [.text(sourceName)]
        ) == 1
    }

    func recordImportedSource(
        name: String,
        sourceVersion: Int?,
        byteCount: Int,
        modificationTimeNanoseconds: Int64,
        digest: String,
        importedAt: Date = Date()
    ) throws {
        try ensureWritable()
        guard Self.isValidMetaKey(name), byteCount >= 0,
              digest.utf8.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw LibraryDatabaseError.invalidData("迁移源收据无效")
        }
        try database.execute(
            """
            INSERT INTO migration_sources(
                source_name, source_version, byte_count, mtime_ns, sha256, imported_at
            ) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_name) DO UPDATE SET
                source_version = excluded.source_version,
                byte_count = excluded.byte_count,
                mtime_ns = excluded.mtime_ns,
                sha256 = excluded.sha256,
                imported_at = excluded.imported_at
            """,
            bindings: [
                .text(name),
                sourceVersion.map { .integer(Int64($0)) } ?? .null,
                .integer(Int64(byteCount)),
                .integer(modificationTimeNanoseconds),
                .text(digest.lowercased()),
                .real(importedAt.timeIntervalSince1970),
            ]
        )
    }

    /// Installs the complete legacy image in one transaction. It is intended for
    /// an `.importing` database that is not yet authoritative; callers still
    /// verify and atomically rename that closed file before runtime stores use it.
    func importInitialState(
        queue: LibraryQueueSnapshot,
        playlists: LibraryPlaylistsSnapshot,
        weights: LibraryWeightsSnapshot,
        playbackSession: LibraryPlaybackSession?,
        sources: [LibraryMigrationSource]
    ) throws {
        try ensureWritable()
        try Self.validate(queue)
        try Self.validate(playlists)
        try Self.validate(weights)
        if let playbackSession { try Self.validate(playbackSession) }
        for source in sources {
            guard Self.isValidMetaKey(source.name), source.byteCount >= 0,
                  source.digest.utf8.count == 64,
                  source.digest.allSatisfy({ $0.isHexDigit }),
                  source.importedAt.timeIntervalSince1970.isFinite else {
                throw LibraryDatabaseError.invalidData("迁移源收据无效")
            }
        }
        try database.transaction { connection in
            try connection.execute("DELETE FROM migration_sources")
            try connection.execute("DELETE FROM playback_session")
            try connection.execute("DELETE FROM playlist_cleanup_intents")
            try connection.execute("DELETE FROM playlist_weight_overrides")
            try connection.execute("DELETE FROM queue_weight_overrides")
            try connection.execute("DELETE FROM playlists")
            try connection.execute("DELETE FROM queue_rekey_intents")
            try connection.execute("DELETE FROM queue_entries")
            try connection.execute("DELETE FROM library_locations")

            try Self.insertQueueEntries(queue.entries, connection: connection)
            try Self.insertQueueRekeys(queue.pendingRekeys, connection: connection)
            try connection.execute(
                "UPDATE queue_state SET current_entry_id = ? WHERE singleton = 1",
                bindings: [queue.currentEntryID.map { .text($0.uuidString) } ?? .null]
            )
            try Self.requireExactlyOneChangedRow(connection, metadata: "queue_state")
            try Self.insertPlaylists(playlists.playlists, connection: connection)
            try Self.insertCleanup(playlists.pendingCleanup, connection: connection)
            try Self.insertWeights(weights, connection: connection)
            if let playbackSession {
                try Self.storePlaybackSession(playbackSession, connection: connection)
            }
            try Self.storeRevision(queue.revision, domain: .queue, connection: connection)
            try Self.storeRevision(0, domain: .locations, connection: connection)
            try Self.storeRevision(playlists.revision, domain: .playlists, connection: connection)
            try Self.storeRevision(weights.revision, domain: .weights, connection: connection)
            try Self.storeRevision(
                playbackSession?.revision ?? 0,
                domain: .session,
                connection: connection
            )
            for source in sources {
                try connection.execute(
                    """
                    INSERT INTO migration_sources(
                        source_name, source_version, byte_count, mtime_ns, sha256, imported_at
                    ) VALUES(?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(source.name),
                        source.sourceVersion.map { .integer(Int64($0)) } ?? .null,
                        .integer(Int64(source.byteCount)),
                        .integer(source.modificationTimeNanoseconds),
                        .text(source.digest.lowercased()),
                        .real(source.importedAt.timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    // MARK: - Library locations

    func libraryLocationsRevision() throws -> UInt64 {
        try loadRevision(.locations)
    }

    func loadLibraryLocation(id: UUID) throws -> LibraryLocationRecord? {
        let rows = try database.query(
            """
            SELECT location_id, kind, bookmark, bookmark_kind, fallback_path,
                   volume_id, volume_relative_root, root_resource_id, display_name,
                   updated_at
            FROM library_locations
            WHERE location_id = ?
            """,
            bindings: [.text(id.uuidString)],
            map: Self.decodeLibraryLocationRecord
        )
        guard rows.count <= 1 else {
            throw LibraryDatabaseError.inconsistentState("外置位置身份重复")
        }
        return rows.first
    }

    /// Streams locations in stable identity order. Bookmark bytes are decoded
    /// one row at a time, and both row count and aggregate bookmark bytes remain
    /// bounded even when a foreign/future database contains malformed data.
    @discardableResult
    func forEachLibraryLocation(
        _ body: (LibraryLocationRecord) throws -> Bool
    ) throws -> Int {
        var delivered = 0
        var aggregateBookmarkBytes = 0
        return try database.forEachRow(
            """
            SELECT location_id, kind, bookmark, bookmark_kind, fallback_path,
                   volume_id, volume_relative_root, root_resource_id, display_name,
                   updated_at
            FROM library_locations
            ORDER BY location_id ASC
            """
        ) { row in
            delivered += 1
            guard delivered <= Limits.maximumLibraryLocations else {
                throw LibraryDatabaseError.inconsistentState("外置位置数量超过产品上限")
            }
            let record = try Self.decodeLibraryLocationRecord(row)
            aggregateBookmarkBytes += record.location.bookmarkData.count
            guard aggregateBookmarkBytes <= Limits.maximumAggregateBookmarkBytes else {
                throw LibraryDatabaseError.inconsistentState("外置位置书签总量超过产品上限")
            }
            return try body(record)
        }
    }

    /// Inserts or replaces one root/file bookmark under an optimistic revision
    /// check. The location and its revision become durable in the same SQLite
    /// transaction, so a stale resolver cannot overwrite a newer authorization.
    @discardableResult
    func upsertLibraryLocation(
        _ record: LibraryLocationRecord,
        expectedRevision: UInt64,
        nextRevision: UInt64
    ) throws -> Bool {
        try ensureWritable()
        try Self.validate(record)
        try Self.validateRevisionTransition(from: expectedRevision, to: nextRevision)
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.locations, connection: connection)
            guard storedRevision == expectedRevision else { return false }
            try Self.validateLocationCapacity(record, connection: connection)
            try connection.execute(
                """
                INSERT INTO library_locations(
                    location_id, kind, bookmark, bookmark_kind, fallback_path,
                    volume_id, volume_relative_root, root_resource_id, display_name,
                    updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(location_id) DO UPDATE SET
                    kind = excluded.kind,
                    bookmark = excluded.bookmark,
                    bookmark_kind = excluded.bookmark_kind,
                    fallback_path = excluded.fallback_path,
                    volume_id = excluded.volume_id,
                    volume_relative_root = excluded.volume_relative_root,
                    root_resource_id = excluded.root_resource_id,
                    display_name = excluded.display_name,
                    updated_at = excluded.updated_at
                """,
                bindings: Self.libraryLocationBindings(record)
            )
            try Self.storeRevision(nextRevision, domain: .locations, connection: connection)
            return true
        }
    }

    /// Updates only the freshness timestamp. Resolver authorization remains an
    /// in-memory state; refreshed bookmark bytes are persisted through upsert.
    @discardableResult
    func touchLibraryLocation(
        id: UUID,
        updatedAt: Date = Date(),
        expectedRevision: UInt64,
        nextRevision: UInt64
    ) throws -> Bool {
        try ensureWritable()
        guard updatedAt.timeIntervalSince1970.isFinite else {
            throw LibraryDatabaseError.invalidData("外置位置更新时间无效")
        }
        try Self.validateRevisionTransition(from: expectedRevision, to: nextRevision)
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.locations, connection: connection)
            guard storedRevision == expectedRevision else { return false }
            guard try connection.scalarInt(
                "SELECT COUNT(*) FROM library_locations WHERE location_id = ?",
                bindings: [.text(id.uuidString)]
            ) == 1 else { return false }
            try connection.execute(
                "UPDATE library_locations SET updated_at = ? WHERE location_id = ?",
                bindings: [
                    .real(updatedAt.timeIntervalSinceReferenceDate),
                    .text(id.uuidString),
                ]
            )
            try Self.requireExactlyOneChangedRow(connection, metadata: "library_locations")
            try Self.storeRevision(nextRevision, domain: .locations, connection: connection)
            return true
        }
    }

    func libraryLocationReferenceCounts(
        id: UUID
    ) throws -> LibraryLocationReferenceCounts {
        try database.readTransaction { connection in
            LibraryLocationReferenceCounts(
                queueEntries: Int(try connection.scalarInt(
                    "SELECT COUNT(*) FROM queue_entries WHERE location_id = ?",
                    bindings: [.text(id.uuidString)]
                ) ?? 0),
                playlistTracks: Int(try connection.scalarInt(
                    "SELECT COUNT(*) FROM playlist_tracks WHERE location_id = ?",
                    bindings: [.text(id.uuidString)]
                ) ?? 0)
            )
        }
    }

    /// Detaches track references before deleting the root. Legacy absolute paths
    /// and signatures remain intact, while relative paths are cleared together
    /// with the foreign key so no half-reference survives ON DELETE SET NULL.
    @discardableResult
    func deleteLibraryLocation(
        id: UUID,
        expectedRevision: UInt64,
        nextRevision: UInt64
    ) throws -> Bool {
        try ensureWritable()
        try Self.validateRevisionTransition(from: expectedRevision, to: nextRevision)
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.locations, connection: connection)
            guard storedRevision == expectedRevision else { return false }
            guard try connection.scalarInt(
                "SELECT COUNT(*) FROM library_locations WHERE location_id = ?",
                bindings: [.text(id.uuidString)]
            ) == 1 else { return false }
            let binding: [SQLiteValue] = [.text(id.uuidString)]
            try connection.execute(
                "UPDATE queue_entries SET location_id = NULL, relative_path = NULL WHERE location_id = ?",
                bindings: binding
            )
            let queueChanged = connection.changes() > 0
            try connection.execute(
                "UPDATE playlist_tracks SET location_id = NULL, relative_path = NULL WHERE location_id = ?",
                bindings: binding
            )
            let playlistsChanged = connection.changes() > 0
            try connection.execute(
                "DELETE FROM library_locations WHERE location_id = ?",
                bindings: binding
            )
            try Self.requireExactlyOneChangedRow(connection, metadata: "library_locations")
            try Self.storeRevision(nextRevision, domain: .locations, connection: connection)
            if queueChanged {
                _ = try Self.advanceRevision(.queue, connection: connection)
            }
            if playlistsChanged {
                _ = try Self.advanceRevision(.playlists, connection: connection)
            }
            return true
        }
    }

    // MARK: - Queue

    func loadQueue() throws -> LibraryQueueSnapshot {
        try database.readTransaction { connection in
            try Self.loadQueue(connection: connection)
        }
    }

    private static func loadQueue(
        connection: SQLiteConnection
    ) throws -> LibraryQueueSnapshot {
        let storedCount = try connection.scalarInt("SELECT COUNT(*) FROM queue_entries") ?? 0
        guard storedCount >= 0, storedCount <= Int64(Limits.maximumQueueEntries) else {
            throw LibraryDatabaseError.inconsistentState("队列条目超过产品上限")
        }
        var entries: [LibraryQueueEntry] = []
        entries.reserveCapacity(Int(storedCount))
        try connection.forEachRow(
            """
            SELECT entry_id, sort_key, path, sig_path_key, sig_size, sig_mtime_ns,
                   sig_inode, sig_file_resource_id, sig_volume_id, location_id,
                   relative_path
            FROM queue_entries
            ORDER BY sort_key ASC
            """
        ) { row in
            guard let id = row.string(at: 0).flatMap(UUID.init(uuidString:)),
                  let sortKey = row.int64(at: 1),
                  let path = row.string(at: 2) else {
                throw LibraryDatabaseError.inconsistentState("队列行无法解码")
            }
            entries.append(
                LibraryQueueEntry(
                    id: id,
                    sortKey: sortKey,
                    path: path,
                    signature: try Self.decodeSignature(row, start: 3),
                    locationID: try Self.decodeOptionalUUID(row, at: 9, field: "location_id"),
                    relativePath: row.string(at: 10)
                )
            )
            guard entries.count <= Limits.maximumQueueEntries else {
                throw LibraryDatabaseError.inconsistentState("队列条目超过产品上限")
            }
            return true
        }

        let stateRows = try connection.query(
            "SELECT current_entry_id FROM queue_state WHERE singleton = 1"
        ) { $0.string(at: 0).flatMap(UUID.init(uuidString:)) }
        guard stateRows.count == 1 else {
            throw LibraryDatabaseError.inconsistentState("缺少队列游标单例")
        }
        let currentEntryID = stateRows.first ?? nil
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            throw LibraryDatabaseError.inconsistentState("队列游标指向不存在的条目")
        }

        var rekeys: [LibraryQueueRekeyIntent] = []
        try connection.forEachRow(
            """
            SELECT intent_id, old_path, new_path, created_at
            FROM queue_rekey_intents
            ORDER BY created_at ASC, intent_id ASC
            """
        ) { row in
            guard let id = row.string(at: 0).flatMap(UUID.init(uuidString:)),
                  let oldPath = row.string(at: 1),
                  let newPath = row.string(at: 2),
                  let createdAt = row.double(at: 3), createdAt.isFinite else {
                throw LibraryDatabaseError.inconsistentState("队列重键意图无法解码")
            }
            rekeys.append(
                LibraryQueueRekeyIntent(
                    id: id,
                    oldPath: oldPath,
                    newPath: newPath,
                    createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
                )
            )
            guard rekeys.count <= Limits.maximumRekeyIntents else {
                throw LibraryDatabaseError.inconsistentState("队列重键意图超过产品上限")
            }
            return true
        }
        return LibraryQueueSnapshot(
            revision: try Self.loadRevision(.queue, connection: connection),
            entries: entries,
            currentEntryID: currentEntryID,
            pendingRekeys: rekeys
        )
    }

    func replaceQueue(_ snapshot: LibraryQueueSnapshot) throws {
        let result = try replaceQueue(snapshot, expectedRevision: nil)
        try Self.requireDurable(result, domain: "queue")
    }

    @discardableResult
    func replaceQueue(
        _ snapshot: LibraryQueueSnapshot,
        expectedRevision: UInt64
    ) throws -> LibraryRevisionCommitResult {
        try replaceQueue(snapshot, expectedRevision: Optional(expectedRevision))
    }

    private func replaceQueue(
        _ snapshot: LibraryQueueSnapshot,
        expectedRevision: UInt64?
    ) throws -> LibraryRevisionCommitResult {
        try ensureWritable()
        try Self.validate(snapshot)
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.queue, connection: connection)
            if snapshot.revision == storedRevision {
                return try Self.loadQueue(connection: connection) == snapshot
                    ? .alreadyCurrent(revision: storedRevision)
                    : .conflict(revision: storedRevision)
            }
            if let expectedRevision, expectedRevision != storedRevision {
                return .stale(storedRevision: storedRevision)
            }
            if snapshot.revision < storedRevision {
                return .stale(storedRevision: storedRevision)
            }

            try connection.execute("DELETE FROM queue_rekey_intents")
            try connection.execute("DELETE FROM queue_entries")
            try Self.insertQueueEntries(snapshot.entries, connection: connection)
            try Self.insertQueueRekeys(snapshot.pendingRekeys, connection: connection)
            try connection.execute(
                "UPDATE queue_state SET current_entry_id = ? WHERE singleton = 1",
                bindings: [snapshot.currentEntryID.map { .text($0.uuidString) } ?? .null]
            )
            try Self.requireExactlyOneChangedRow(connection, metadata: "queue_state")
            try Self.storeRevision(snapshot.revision, domain: .queue, connection: connection)
            return .committed(revision: snapshot.revision)
        }
    }

    /// O(1) navigation persistence. The expected structural revision prevents a
    /// stale UI event from moving the cursor in a newly replaced queue.
    func updateQueueCursor(
        currentEntryID: UUID?,
        expectedQueueRevision: UInt64
    ) throws -> Bool {
        try ensureWritable()
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.queue, connection: connection)
            guard storedRevision == expectedQueueRevision else { return false }
            if let currentEntryID {
                let exists = try connection.scalarInt(
                    "SELECT COUNT(*) FROM queue_entries WHERE entry_id = ?",
                    bindings: [.text(currentEntryID.uuidString)]
                ) == 1
                guard exists else {
                    throw LibraryDatabaseError.invalidData("队列游标目标不存在")
                }
            }
            try connection.execute(
                "UPDATE queue_state SET current_entry_id = ? WHERE singleton = 1",
                bindings: [currentEntryID.map { .text($0.uuidString) } ?? .null]
            )
            try Self.requireExactlyOneChangedRow(connection, metadata: "queue_state")
            return true
        }
    }

    // MARK: - Playlists

    func loadPlaylists() throws -> LibraryPlaylistsSnapshot {
        try database.readTransaction { connection in
            try Self.loadPlaylists(connection: connection)
        }
    }

    private static func loadPlaylists(
        connection: SQLiteConnection
    ) throws -> LibraryPlaylistsSnapshot {
        var playlists: [UserPlaylist] = []
        var indexByID: [UUID: Int] = [:]
        try connection.forEachRow(
            """
            SELECT playlist_id, name, created_at, updated_at
            FROM playlists ORDER BY sort_key ASC
            """
        ) { row in
            guard let id = row.string(at: 0).flatMap(UUID.init(uuidString:)),
                  let name = row.string(at: 1),
                  let created = row.double(at: 2), created.isFinite,
                  let updated = row.double(at: 3), updated.isFinite,
                  indexByID[id] == nil else {
                throw LibraryDatabaseError.inconsistentState("歌单行无法解码")
            }
            indexByID[id] = playlists.count
            playlists.append(
                UserPlaylist(
                    id: id,
                    name: name,
                    tracks: [],
                    createdAt: Date(timeIntervalSinceReferenceDate: created),
                    updatedAt: Date(timeIntervalSinceReferenceDate: updated)
                )
            )
            guard playlists.count <= Limits.maximumPlaylists else {
                throw LibraryDatabaseError.inconsistentState("歌单数超过产品上限")
            }
            return true
        }

        var totalTracks = 0
        try connection.forEachRow(
            """
            SELECT playlist_id, track_id, path, sig_path_key, sig_size, sig_mtime_ns,
                   sig_inode, sig_file_resource_id, sig_volume_id, location_id, relative_path
            FROM playlist_tracks
            ORDER BY playlist_id ASC, sort_key ASC
            """
        ) { row in
            guard let playlistID = row.string(at: 0).flatMap(UUID.init(uuidString:)),
                  let playlistIndex = indexByID[playlistID],
                  let trackID = row.string(at: 1).flatMap(UUID.init(uuidString:)),
                  let path = row.string(at: 2) else {
                throw LibraryDatabaseError.inconsistentState("歌单歌曲行无法解码")
            }
            playlists[playlistIndex].tracks.append(
                UserPlaylist.Track(
                    id: trackID,
                    path: path,
                    signature: try Self.decodeSignature(row, start: 3),
                    locationID: try Self.decodeOptionalUUID(row, at: 9, field: "location_id"),
                    relativePath: row.string(at: 10)
                )
            )
            totalTracks += 1
            guard totalTracks <= Limits.maximumPlaylistTracks else {
                throw LibraryDatabaseError.inconsistentState("歌单歌曲总数超过产品上限")
            }
            return true
        }

        let cleanup = try loadCleanupIntents(connection: connection)
        return LibraryPlaylistsSnapshot(
            revision: try Self.loadRevision(.playlists, connection: connection),
            playlists: playlists,
            pendingCleanup: cleanup
        )
    }

    func replacePlaylists(_ snapshot: LibraryPlaylistsSnapshot) throws {
        let result = try replacePlaylists(snapshot, expectedRevision: nil)
        try Self.requireDurable(result, domain: "playlists")
    }

    @discardableResult
    func replacePlaylists(
        _ snapshot: LibraryPlaylistsSnapshot,
        expectedRevision: UInt64
    ) throws -> LibraryRevisionCommitResult {
        try replacePlaylists(snapshot, expectedRevision: Optional(expectedRevision))
    }

    private func replacePlaylists(
        _ snapshot: LibraryPlaylistsSnapshot,
        expectedRevision: UInt64?
    ) throws -> LibraryRevisionCommitResult {
        try ensureWritable()
        try Self.validate(snapshot)
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.playlists, connection: connection)
            if snapshot.revision == storedRevision {
                return try Self.loadPlaylists(connection: connection) == snapshot
                    ? .alreadyCurrent(revision: storedRevision)
                    : .conflict(revision: storedRevision)
            }
            if let expectedRevision, expectedRevision != storedRevision {
                return .stale(storedRevision: storedRevision)
            }
            if snapshot.revision < storedRevision {
                return .stale(storedRevision: storedRevision)
            }

            var existingIDs = Set<UUID>()
            try connection.forEachRow("SELECT playlist_id FROM playlists") { row in
                guard let rawID = row.string(at: 0),
                      let id = UUID(uuidString: rawID),
                      existingIDs.insert(id).inserted else {
                    throw LibraryDatabaseError.inconsistentState("歌单身份无法解码或重复")
                }
                return true
            }
            let incomingByID = Dictionary(
                uniqueKeysWithValues: snapshot.playlists.map { ($0.id, $0) }
            )
            let trackRewriteIDs = try Self.playlistsNeedingTrackReplacement(
                incomingByID: incomingByID,
                existingIDs: existingIDs,
                connection: connection
            )
            let incomingIDs = Set(snapshot.playlists.map(\.id))
            var removedWeights = false
            for existingID in existingIDs where !incomingIDs.contains(existingID) {
                try connection.execute(
                    "DELETE FROM playlist_weight_overrides WHERE playlist_id = ?",
                    bindings: [.text(existingID.uuidString)]
                )
                removedWeights = removedWeights || connection.changes() > 0
                try connection.execute(
                    "DELETE FROM playlists WHERE playlist_id = ?",
                    bindings: [.text(existingID.uuidString)]
                )
                try Self.requireExactlyOneChangedRow(connection, metadata: "playlists")
            }

            // Move existing sort keys into a disjoint range before assigning
            // the new order, avoiding transient UNIQUE collisions.
            try connection.execute("UPDATE playlists SET sort_key = -sort_key - 1")
            for (index, playlist) in snapshot.playlists.enumerated() {
                try connection.execute(
                    """
                    INSERT INTO playlists(
                        playlist_id, name, sort_key, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(playlist_id) DO UPDATE SET
                        name = excluded.name,
                        sort_key = excluded.sort_key,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    """,
                    bindings: [
                        .text(playlist.id.uuidString), .text(playlist.name),
                        .integer(Int64(index) * 1_024),
                        .real(playlist.createdAt.timeIntervalSinceReferenceDate),
                        .real(playlist.updatedAt.timeIntervalSinceReferenceDate),
                    ]
                )
                if trackRewriteIDs.contains(playlist.id) {
                    try connection.execute(
                        "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                        bindings: [.text(playlist.id.uuidString)]
                    )
                    try Self.insertPlaylistTracks(
                        playlist.tracks,
                        playlistID: playlist.id,
                        connection: connection
                    )
                }
            }
            try connection.execute("DELETE FROM playlist_cleanup_intents")
            try Self.insertCleanup(snapshot.pendingCleanup, connection: connection)
            try Self.storeRevision(snapshot.revision, domain: .playlists, connection: connection)
            if removedWeights {
                _ = try Self.advanceRevision(.weights, connection: connection)
            }
            return .committed(revision: snapshot.revision)
        }
    }

    /// Cross-domain deletion used by the runtime once PlaylistsStore is switched
    /// to delta commits. Playlist rows and sparse weights cannot diverge.
    func deletePlaylist(
        id: UUID,
        cleanupIntent: PlaylistCleanupIntent?,
        nextRevision: UInt64
    ) throws -> Bool {
        try ensureWritable()
        if let cleanupIntent, cleanupIntent.playlistID != id {
            throw LibraryDatabaseError.invalidData("删除歌单与清理意图不匹配")
        }
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.playlists, connection: connection)
            try Self.validateRevisionTransition(from: storedRevision, to: nextRevision)
            guard try connection.scalarInt(
                "SELECT COUNT(*) FROM playlists WHERE playlist_id = ?",
                bindings: [.text(id.uuidString)]
            ) == 1 else { return false }
            try connection.execute(
                "DELETE FROM playlist_weight_overrides WHERE playlist_id = ?",
                bindings: [.text(id.uuidString)]
            )
            let removedWeights = connection.changes() > 0
            try connection.execute(
                "DELETE FROM playlists WHERE playlist_id = ?",
                bindings: [.text(id.uuidString)]
            )
            try Self.requireExactlyOneChangedRow(connection, metadata: "playlists")
            if let cleanupIntent {
                try Self.insertCleanup([cleanupIntent], connection: connection)
            }
            try Self.storeRevision(nextRevision, domain: .playlists, connection: connection)
            if removedWeights {
                _ = try Self.advanceRevision(.weights, connection: connection)
            }
            return true
        }
    }

    // MARK: - Weights

    func loadWeights() throws -> LibraryWeightsSnapshot {
        try database.readTransaction { connection in
            try Self.loadWeights(connection: connection)
        }
    }

    private static func loadWeights(
        connection: SQLiteConnection
    ) throws -> LibraryWeightsSnapshot {
        var queueLevels: [String: Int] = [:]
        var total = 0
        try connection.forEachRow(
            "SELECT path_key, level FROM queue_weight_overrides ORDER BY path_key ASC"
        ) { row in
            guard let path = row.string(at: 0), let raw = row.int64(at: 1),
                  queueLevels[path] == nil else {
                throw LibraryDatabaseError.inconsistentState("队列权重无法解码")
            }
            let level = Int(raw)
            try Self.validateStoredWeight(path: path, level: level)
            queueLevels[path] = level
            total += 1
            guard total <= Limits.maximumQueueEntries else {
                throw LibraryDatabaseError.inconsistentState("权重条目超过产品上限")
            }
            return true
        }
        var playlistLevels: [UUID: [String: Int]] = [:]
        try connection.forEachRow(
            """
            SELECT playlist_id, path_key, level
            FROM playlist_weight_overrides
            ORDER BY playlist_id ASC, path_key ASC
            """
        ) { row in
            guard let playlistID = row.string(at: 0).flatMap(UUID.init(uuidString:)),
                  let path = row.string(at: 1), let raw = row.int64(at: 2),
                  playlistLevels[playlistID]?[path] == nil else {
                throw LibraryDatabaseError.inconsistentState("歌单权重无法解码")
            }
            let level = Int(raw)
            try Self.validateStoredWeight(path: path, level: level)
            playlistLevels[playlistID, default: [:]][path] = level
            total += 1
            guard total <= Limits.maximumQueueEntries else {
                throw LibraryDatabaseError.inconsistentState("权重条目超过产品上限")
            }
            return true
        }
        return LibraryWeightsSnapshot(
            revision: try Self.loadRevision(.weights, connection: connection),
            queueLevels: queueLevels,
            playlistLevels: playlistLevels
        )
    }

    func replaceWeights(_ snapshot: LibraryWeightsSnapshot) throws {
        let result = try replaceWeights(snapshot, expectedRevision: nil)
        try Self.requireDurable(result, domain: "weights")
    }

    @discardableResult
    func replaceWeights(
        _ snapshot: LibraryWeightsSnapshot,
        expectedRevision: UInt64
    ) throws -> LibraryRevisionCommitResult {
        try replaceWeights(snapshot, expectedRevision: Optional(expectedRevision))
    }

    private func replaceWeights(
        _ snapshot: LibraryWeightsSnapshot,
        expectedRevision: UInt64?
    ) throws -> LibraryRevisionCommitResult {
        try ensureWritable()
        try Self.validate(snapshot)
        return try database.transaction { connection in
            let storedRevision = try Self.loadRevision(.weights, connection: connection)
            if snapshot.revision == storedRevision {
                return try Self.loadWeights(connection: connection) == snapshot
                    ? .alreadyCurrent(revision: storedRevision)
                    : .conflict(revision: storedRevision)
            }
            if let expectedRevision, expectedRevision != storedRevision {
                return .stale(storedRevision: storedRevision)
            }
            if snapshot.revision < storedRevision {
                return .stale(storedRevision: storedRevision)
            }
            try connection.execute("DELETE FROM queue_weight_overrides")
            try connection.execute("DELETE FROM playlist_weight_overrides")
            try Self.insertWeights(snapshot, connection: connection)
            try Self.storeRevision(snapshot.revision, domain: .weights, connection: connection)
            return .committed(revision: snapshot.revision)
        }
    }

    // MARK: - Playback session

    func loadPlaybackSession() throws -> LibraryPlaybackSession? {
        try database.readTransaction { connection in
            try Self.loadPlaybackSession(connection: connection)
        }
    }

    private static func loadPlaybackSession(
        connection: SQLiteConnection
    ) throws -> LibraryPlaybackSession? {
        let session = try playbackSessionRow(connection: connection)
        let domainRevision = try loadRevision(.session, connection: connection)
        guard session?.revision == domainRevision || (session == nil && domainRevision == 0) else {
            throw LibraryDatabaseError.inconsistentState("播放会话行与修订号不一致")
        }
        return session
    }

    private static func playbackSessionRow(
        connection: SQLiteConnection
    ) throws -> LibraryPlaybackSession? {
        let rows = try connection.query(
            """
            SELECT revision, scope_kind, playlist_id, scope_track_id, queue_entry_id,
                   fallback_path, position_ms
            FROM playback_session WHERE singleton = 1
            """
        ) { row -> LibraryPlaybackSession in
            guard let revision = row.int64(at: 0), revision >= 0,
                  let rawScope = row.int64(at: 1),
                  let scope = LibraryPlaybackSession.Scope(rawValue: Int(rawScope)),
                  let position = row.int64(at: 6), position >= 0 else {
                throw LibraryDatabaseError.inconsistentState("播放会话行无法解码")
            }
            let session = LibraryPlaybackSession(
                revision: UInt64(revision),
                scope: scope,
                playlistID: try Self.decodeOptionalUUID(row, at: 2, field: "playlist_id"),
                scopeTrackID: try Self.decodeOptionalUUID(row, at: 3, field: "scope_track_id"),
                queueEntryID: try Self.decodeOptionalUUID(row, at: 4, field: "queue_entry_id"),
                fallbackPath: row.string(at: 5),
                positionMilliseconds: position
            )
            do {
                try Self.validate(session)
            } catch {
                throw LibraryDatabaseError.inconsistentState("播放会话字段不一致")
            }
            return session
        }
        guard rows.count <= 1 else {
            throw LibraryDatabaseError.inconsistentState("播放会话单例重复")
        }
        return rows.first
    }

    func playbackSessionRevision() throws -> UInt64 {
        try loadRevision(.session)
    }

    func storePlaybackSession(_ session: LibraryPlaybackSession) throws {
        let result = try storePlaybackSession(session, expectedRevision: nil)
        try Self.requireDurable(result, domain: "session")
    }

    @discardableResult
    func storePlaybackSession(
        _ session: LibraryPlaybackSession,
        expectedRevision: UInt64
    ) throws -> LibraryRevisionCommitResult {
        try storePlaybackSession(session, expectedRevision: Optional(expectedRevision))
    }

    private func storePlaybackSession(
        _ session: LibraryPlaybackSession,
        expectedRevision: UInt64?
    ) throws -> LibraryRevisionCommitResult {
        try ensureWritable()
        try Self.validate(session)
        return try database.transaction { connection in
            let domainRevision = try Self.loadRevision(.session, connection: connection)
            let storedSession = try Self.playbackSessionRow(connection: connection)
            guard storedSession?.revision == domainRevision
                    || (storedSession == nil && domainRevision == 0) else {
                throw LibraryDatabaseError.inconsistentState("播放会话行与修订号不一致")
            }
            if session.revision == domainRevision, let storedSession {
                return storedSession == session
                    ? .alreadyCurrent(revision: domainRevision)
                    : .conflict(revision: domainRevision)
            }
            if let expectedRevision, expectedRevision != domainRevision {
                return .stale(storedRevision: domainRevision)
            }
            if session.revision < domainRevision {
                return .stale(storedRevision: domainRevision)
            }
            if session.revision == domainRevision, storedSession == nil, domainRevision != 0 {
                return .conflict(revision: domainRevision)
            }
            try Self.storePlaybackSession(session, connection: connection)
            try Self.storeRevision(session.revision, domain: .session, connection: connection)
            return .committed(revision: session.revision)
        }
    }

    // MARK: - Private schema and validation

    private static let schema = SQLiteSchema(
        applicationID: applicationID,
        version: schemaVersion,
        migrations: [
            SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                try connection.execute(
                    """
                    CREATE TABLE library_meta(
                        key TEXT PRIMARY KEY,
                        value BLOB NOT NULL
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE domain_revisions(
                        domain TEXT PRIMARY KEY,
                        revision INTEGER NOT NULL CHECK(revision >= 0)
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE library_locations(
                        location_id TEXT PRIMARY KEY,
                        kind INTEGER NOT NULL CHECK(kind IN (0, 1)),
                        bookmark BLOB NOT NULL CHECK(length(bookmark) BETWEEN 1 AND 65536),
                        bookmark_kind INTEGER NOT NULL CHECK(bookmark_kind IN (0, 1)),
                        fallback_path TEXT NOT NULL,
                        volume_id TEXT,
                        volume_relative_root TEXT,
                        root_resource_id TEXT,
                        display_name TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE queue_entries(
                        entry_id TEXT PRIMARY KEY,
                        sort_key INTEGER NOT NULL UNIQUE,
                        path TEXT NOT NULL,
                        path_key TEXT NOT NULL,
                        sig_path_key TEXT,
                        sig_size INTEGER,
                        sig_mtime_ns INTEGER,
                        sig_inode TEXT,
                        sig_file_resource_id TEXT,
                        sig_volume_id TEXT,
                        location_id TEXT REFERENCES library_locations(location_id) ON DELETE SET NULL,
                        relative_path TEXT
                    )
                    """
                )
                try connection.execute("CREATE INDEX queue_entries_path ON queue_entries(path_key)")
                try connection.execute(
                    "CREATE INDEX queue_entries_resource ON queue_entries(sig_volume_id, sig_file_resource_id)"
                )
                try connection.execute(
                    "CREATE INDEX queue_entries_inode ON queue_entries(sig_volume_id, sig_inode, sig_size, sig_mtime_ns)"
                )
                try connection.execute(
                    """
                    CREATE TABLE queue_state(
                        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                        current_entry_id TEXT REFERENCES queue_entries(entry_id)
                            ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED
                    )
                    """
                )
                try connection.execute("INSERT INTO queue_state(singleton, current_entry_id) VALUES(1, NULL)")
                try connection.execute(
                    """
                    CREATE TABLE queue_rekey_intents(
                        intent_id TEXT PRIMARY KEY,
                        old_path TEXT NOT NULL,
                        old_path_key TEXT NOT NULL,
                        new_path TEXT NOT NULL,
                        new_path_key TEXT NOT NULL,
                        created_at REAL NOT NULL
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE playlists(
                        playlist_id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        sort_key INTEGER NOT NULL UNIQUE,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE playlist_tracks(
                        track_id TEXT PRIMARY KEY,
                        playlist_id TEXT NOT NULL REFERENCES playlists(playlist_id) ON DELETE CASCADE,
                        sort_key INTEGER NOT NULL,
                        path TEXT NOT NULL,
                        path_key TEXT NOT NULL,
                        sig_path_key TEXT,
                        sig_size INTEGER,
                        sig_mtime_ns INTEGER,
                        sig_inode TEXT,
                        sig_file_resource_id TEXT,
                        sig_volume_id TEXT,
                        location_id TEXT REFERENCES library_locations(location_id) ON DELETE SET NULL,
                        relative_path TEXT,
                        UNIQUE(playlist_id, sort_key)
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX playlist_tracks_order ON playlist_tracks(playlist_id, sort_key)"
                )
                try connection.execute(
                    "CREATE INDEX playlist_tracks_path ON playlist_tracks(playlist_id, path_key)"
                )
                try connection.execute(
                    """
                    CREATE TABLE queue_weight_overrides(
                        path_key TEXT PRIMARY KEY,
                        level INTEGER NOT NULL CHECK(level IN (0, 2, 3, 4, 5))
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE playlist_weight_overrides(
                        playlist_id TEXT NOT NULL,
                        path_key TEXT NOT NULL,
                        level INTEGER NOT NULL CHECK(level IN (0, 2, 3, 4, 5)),
                        PRIMARY KEY(playlist_id, path_key)
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE playlist_cleanup_intents(
                        intent_id TEXT PRIMARY KEY,
                        kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 2),
                        playlist_id TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        next_attempt_at REAL,
                        last_error TEXT
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE playlist_cleanup_items(
                        intent_id TEXT NOT NULL REFERENCES playlist_cleanup_intents(intent_id) ON DELETE CASCADE,
                        ordinal INTEGER NOT NULL,
                        track_id TEXT,
                        old_path TEXT NOT NULL,
                        old_path_key TEXT NOT NULL,
                        new_path TEXT,
                        new_path_key TEXT,
                        PRIMARY KEY(intent_id, ordinal)
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX cleanup_due ON playlist_cleanup_intents(next_attempt_at, created_at)"
                )
                try connection.execute(
                    """
                    CREATE TABLE playback_session(
                        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                        revision INTEGER NOT NULL CHECK(revision >= 0),
                        scope_kind INTEGER NOT NULL CHECK(scope_kind IN (0, 1)),
                        playlist_id TEXT,
                        scope_track_id TEXT,
                        queue_entry_id TEXT,
                        fallback_path TEXT,
                        position_ms INTEGER NOT NULL CHECK(position_ms >= 0)
                    )
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE migration_sources(
                        source_name TEXT PRIMARY KEY,
                        source_version INTEGER,
                        byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                        mtime_ns INTEGER NOT NULL,
                        sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
                        imported_at REAL NOT NULL
                    )
                    """
                )
                for domain in [Domain.locations, .queue, .playlists, .weights, .session] {
                    try connection.execute(
                        "INSERT INTO domain_revisions(domain, revision) VALUES(?, 0)",
                        bindings: [.text(domain.rawValue)]
                    )
                }
            }
        ]
    )

    private func ensureWritable() throws {
        guard accessMode == .writable else { throw LibraryDatabaseError.readOnly }
    }

    private func loadRevision(_ domain: Domain) throws -> UInt64 {
        let value = try database.scalarInt(
            "SELECT revision FROM domain_revisions WHERE domain = ?",
            bindings: [.text(domain.rawValue)]
        )
        guard let value, value >= 0 else {
            throw LibraryDatabaseError.inconsistentState("缺少 \(domain.rawValue) 修订号")
        }
        return UInt64(value)
    }

    private static func loadRevision(
        _ domain: Domain,
        connection: SQLiteConnection
    ) throws -> UInt64 {
        let value = try connection.scalarInt(
            "SELECT revision FROM domain_revisions WHERE domain = ?",
            bindings: [.text(domain.rawValue)]
        )
        guard let value, value >= 0 else {
            throw LibraryDatabaseError.inconsistentState("缺少 \(domain.rawValue) 修订号")
        }
        return UInt64(value)
    }

    private static func storeRevision(
        _ revision: UInt64,
        domain: Domain,
        connection: SQLiteConnection
    ) throws {
        try connection.execute(
            "UPDATE domain_revisions SET revision = ? WHERE domain = ?",
            bindings: [.integer(try sqliteRevision(revision)), .text(domain.rawValue)]
        )
        try requireExactlyOneChangedRow(connection, metadata: "domain_revisions.\(domain.rawValue)")
    }

    @discardableResult
    private static func advanceRevision(
        _ domain: Domain,
        connection: SQLiteConnection
    ) throws -> UInt64 {
        let current = try loadRevision(domain, connection: connection)
        guard current < UInt64(Int64.max) else {
            throw LibraryDatabaseError.inconsistentState("\(domain.rawValue) 修订号已耗尽")
        }
        let next = current + 1
        try storeRevision(next, domain: domain, connection: connection)
        return next
    }

    private static func requireExactlyOneChangedRow(
        _ connection: SQLiteConnection,
        metadata: String
    ) throws {
        guard connection.changes() == 1 else {
            throw LibraryDatabaseError.inconsistentState("\(metadata) 单例更新未命中唯一行")
        }
    }

    private static func requireDurable(
        _ result: LibraryRevisionCommitResult,
        domain: String
    ) throws {
        switch result {
        case .committed, .alreadyCurrent:
            return
        case .stale(let storedRevision):
            throw LibraryDatabaseError.inconsistentState(
                "\(domain) 写入已过期，当前修订号为 \(storedRevision)"
            )
        case .conflict(let revision):
            throw LibraryDatabaseError.inconsistentState(
                "\(domain) 修订号 \(revision) 对应不同内容"
            )
        }
    }

    private static func sqliteRevision(_ revision: UInt64) throws -> Int64 {
        guard revision <= UInt64(Int64.max) else {
            throw LibraryDatabaseError.invalidData("修订号超过 SQLite 安全范围")
        }
        return Int64(revision)
    }

    private static func validateRevisionTransition(
        from expectedRevision: UInt64,
        to nextRevision: UInt64
    ) throws {
        _ = try sqliteRevision(expectedRevision)
        _ = try sqliteRevision(nextRevision)
        guard expectedRevision < UInt64(Int64.max),
              nextRevision == expectedRevision + 1 else {
            throw LibraryDatabaseError.invalidData("外置位置修订号必须连续递增")
        }
    }

    private static func count(_ database: SQLiteDatabase, table: String) -> Int {
        let value: Int64?
        do {
            value = try database.scalarInt("SELECT COUNT(*) FROM \(table)")
        } catch {
            return 0
        }
        return Int(value ?? 0)
    }

    private static func validate(_ snapshot: LibraryQueueSnapshot) throws {
        guard snapshot.entries.count <= Limits.maximumQueueEntries,
              snapshot.pendingRekeys.count <= Limits.maximumRekeyIntents else {
            throw LibraryDatabaseError.invalidData("队列容量超过产品上限")
        }
        _ = try sqliteRevision(snapshot.revision)
        let IDs = Set(snapshot.entries.map(\.id))
        guard IDs.count == snapshot.entries.count,
              Set(snapshot.entries.map(\.sortKey)).count == snapshot.entries.count else {
            throw LibraryDatabaseError.invalidData("队列身份或排序键重复")
        }
        if let current = snapshot.currentEntryID, !IDs.contains(current) {
            throw LibraryDatabaseError.invalidData("队列游标不在快照中")
        }
        for entry in snapshot.entries {
            try validatePath(entry.path)
            try validate(signature: entry.signature)
            try validateRelativePath(entry.relativePath, locationID: entry.locationID)
        }
        guard Set(snapshot.pendingRekeys.map(\.id)).count == snapshot.pendingRekeys.count else {
            throw LibraryDatabaseError.invalidData("队列重键意图身份重复")
        }
        for intent in snapshot.pendingRekeys {
            try validatePath(intent.oldPath)
            try validatePath(intent.newPath)
            guard intent.createdAt.timeIntervalSince1970.isFinite else {
                throw LibraryDatabaseError.invalidData("队列重键时间无效")
            }
        }
    }

    private static func validate(_ record: LibraryLocationRecord) throws {
        guard record.updatedAt.timeIntervalSince1970.isFinite else {
            throw LibraryDatabaseError.invalidData("外置位置更新时间无效")
        }
        do {
            _ = try LibraryLocation(
                id: record.location.id,
                kind: record.location.kind,
                bookmarkData: record.location.bookmarkData,
                bookmarkKind: record.location.bookmarkKind,
                fallbackPath: record.location.fallbackPath,
                volumeIdentifier: record.location.volumeIdentifier,
                volumeRelativeRootPath: record.location.volumeRelativeRootPath,
                rootResourceIdentifier: record.location.rootResourceIdentifier,
                displayName: record.location.displayName
            )
        } catch {
            throw LibraryDatabaseError.invalidData("外置位置字段越界")
        }
    }

    private static func validateLocationCapacity(
        _ record: LibraryLocationRecord,
        connection: SQLiteConnection
    ) throws {
        let existingBookmarkBytes = try connection.scalarInt(
            "SELECT length(bookmark) FROM library_locations WHERE location_id = ?",
            bindings: [.text(record.location.id.uuidString)]
        ) ?? 0
        let locationCount = try connection.scalarInt(
            "SELECT COUNT(*) FROM library_locations"
        ) ?? 0
        if existingBookmarkBytes == 0,
           locationCount >= Int64(Limits.maximumLibraryLocations) {
            throw LibraryDatabaseError.invalidData("外置位置数量超过产品上限")
        }
        let aggregateBookmarkBytes = try connection.scalarInt(
            "SELECT COALESCE(SUM(length(bookmark)), 0) FROM library_locations"
        ) ?? 0
        let nextAggregate = aggregateBookmarkBytes
            - existingBookmarkBytes
            + Int64(record.location.bookmarkData.count)
        guard nextAggregate >= 0,
              nextAggregate <= Int64(Limits.maximumAggregateBookmarkBytes) else {
            throw LibraryDatabaseError.invalidData("外置位置书签总量超过产品上限")
        }
    }

    private static func libraryLocationBindings(
        _ record: LibraryLocationRecord
    ) -> [SQLiteValue] {
        let location = record.location
        let rawKind: Int64 = location.kind == .directory ? 0 : 1
        let rawBookmarkKind: Int64 = location.bookmarkKind == .securityScoped ? 0 : 1
        return [
            .text(location.id.uuidString),
            .integer(rawKind),
            .blob(location.bookmarkData),
            .integer(rawBookmarkKind),
            .text(location.fallbackPath),
            location.volumeIdentifier.map(SQLiteValue.text) ?? .null,
            location.volumeRelativeRootPath.map(SQLiteValue.text) ?? .null,
            location.rootResourceIdentifier.map(SQLiteValue.text) ?? .null,
            .text(location.displayName),
            .real(record.updatedAt.timeIntervalSinceReferenceDate),
        ]
    }

    private static func decodeLibraryLocationRecord(
        _ row: SQLiteRow
    ) throws -> LibraryLocationRecord {
        guard let id = row.string(at: 0).flatMap(UUID.init(uuidString:)),
              let rawKind = row.int64(at: 1),
              let bookmarkData = row.data(at: 2),
              let rawBookmarkKind = row.int64(at: 3),
              let fallbackPath = row.string(at: 4),
              let displayName = row.string(at: 8),
              let updatedAtRaw = row.double(at: 9),
              updatedAtRaw.isFinite else {
            throw LibraryDatabaseError.inconsistentState("外置位置行无法解码")
        }
        let kind: LibraryLocationKind
        switch rawKind {
        case 0: kind = .directory
        case 1: kind = .singleFile
        default:
            throw LibraryDatabaseError.inconsistentState("外置位置类型无效")
        }
        let bookmarkKind: LibraryBookmarkKind
        switch rawBookmarkKind {
        case 0: bookmarkKind = .securityScoped
        case 1: bookmarkKind = .regular
        default:
            throw LibraryDatabaseError.inconsistentState("外置位置书签类型无效")
        }
        do {
            let location = try LibraryLocation(
                id: id,
                kind: kind,
                bookmarkData: bookmarkData,
                bookmarkKind: bookmarkKind,
                fallbackPath: fallbackPath,
                volumeIdentifier: row.string(at: 5),
                volumeRelativeRootPath: row.string(at: 6),
                rootResourceIdentifier: row.string(at: 7),
                displayName: displayName
            )
            return LibraryLocationRecord(
                location: location,
                updatedAt: Date(timeIntervalSinceReferenceDate: updatedAtRaw)
            )
        } catch {
            throw LibraryDatabaseError.inconsistentState("外置位置字段越界")
        }
    }

    private static func validate(_ snapshot: LibraryPlaylistsSnapshot) throws {
        guard snapshot.playlists.count <= Limits.maximumPlaylists,
              snapshot.pendingCleanup.count <= Limits.maximumCleanupIntents,
              snapshot.playlists.reduce(0, { $0 + $1.tracks.count }) <= Limits.maximumPlaylistTracks else {
            throw LibraryDatabaseError.invalidData("歌单容量超过产品上限")
        }
        _ = try sqliteRevision(snapshot.revision)
        guard Set(snapshot.playlists.map(\.id)).count == snapshot.playlists.count else {
            throw LibraryDatabaseError.invalidData("歌单身份重复")
        }
        var trackIDs = Set<UUID>()
        for playlist in snapshot.playlists {
            let nameBytes = playlist.name.utf8.count
            guard nameBytes > 0, nameBytes <= Limits.maximumNameBytes,
                  playlist.createdAt.timeIntervalSince1970.isFinite,
                  playlist.updatedAt.timeIntervalSince1970.isFinite else {
                throw LibraryDatabaseError.invalidData("歌单名称或时间无效")
            }
            for track in playlist.tracks {
                guard trackIDs.insert(track.id).inserted else {
                    throw LibraryDatabaseError.invalidData("歌单歌曲身份重复")
                }
                try validatePath(track.path)
                try validate(signature: track.signature)
                try validateRelativePath(track.relativePath, locationID: track.locationID)
            }
        }
        guard Set(snapshot.pendingCleanup.map(\.id)).count == snapshot.pendingCleanup.count else {
            throw LibraryDatabaseError.invalidData("清理意图身份重复")
        }
        for intent in snapshot.pendingCleanup {
            guard intent.createdAt.timeIntervalSince1970.isFinite else {
                throw LibraryDatabaseError.invalidData("清理意图时间无效")
            }
            for path in intent.trackPaths { try validatePath(path) }
            for relocation in intent.trackRelocations ?? [] {
                try validatePath(relocation.oldPath)
                try validatePath(relocation.newPath)
            }
        }
    }

    private static func validate(_ snapshot: LibraryWeightsSnapshot) throws {
        _ = try sqliteRevision(snapshot.revision)
        let total = snapshot.queueLevels.count
            + snapshot.playlistLevels.values.reduce(0) { $0 + $1.count }
        guard total <= Limits.maximumQueueEntries else {
            throw LibraryDatabaseError.invalidData("权重条目超过产品上限")
        }
        for (path, level) in snapshot.queueLevels {
            try validatePathKey(path)
            try validateStoredLevel(level)
        }
        for (playlistID, levels) in snapshot.playlistLevels {
            _ = playlistID
            for (path, level) in levels {
                try validatePathKey(path)
                try validateStoredLevel(level)
            }
        }
    }

    private static func validate(_ session: LibraryPlaybackSession) throws {
        _ = try sqliteRevision(session.revision)
        guard session.positionMilliseconds >= 0 else {
            throw LibraryDatabaseError.invalidData("播放进度为负数")
        }
        if session.scope == .queue,
           session.playlistID != nil || session.scopeTrackID != nil {
            throw LibraryDatabaseError.invalidData("队列会话包含歌单身份")
        }
        if session.scope == .playlist,
           session.playlistID == nil || session.scopeTrackID == nil {
            throw LibraryDatabaseError.invalidData("歌单会话缺少歌曲身份")
        }
        if let path = session.fallbackPath { try validatePath(path) }
    }

    private static func validatePath(_ path: String) throws {
        let bytes = path.utf8.count
        guard path.hasPrefix("/"), bytes > 1, bytes <= Limits.maximumPathBytes,
              !path.utf8.contains(0) else {
            throw LibraryDatabaseError.invalidData("路径越界")
        }
    }

    private static func validatePathKey(_ path: String) throws {
        let bytes = path.utf8.count
        guard path.hasPrefix("/"), bytes > 1, bytes <= Limits.maximumPathBytes,
              !path.utf8.contains(0) else {
            throw LibraryDatabaseError.invalidData("路径键越界")
        }
    }

    private static func validate(signature: FileSignature?) throws {
        guard let signature else { return }
        guard signature.size >= 0 else {
            throw LibraryDatabaseError.invalidData("签名文件大小为负数")
        }
        for value in [
            signature.pathKey,
            signature.fileResourceIdentifier,
            signature.volumeIdentifier,
        ].compactMap({ $0 }) {
            guard !value.utf8.contains(0),
                  value.utf8.count <= Limits.maximumIdentifierBytes else {
                throw LibraryDatabaseError.invalidData("签名标识越界")
            }
        }
    }

    private static func validateRelativePath(_ path: String?, locationID: UUID?) throws {
        guard let path else {
            guard locationID == nil else {
                throw LibraryDatabaseError.invalidData("外置位置缺少相对路径")
            }
            return
        }
        guard locationID != nil, !path.hasPrefix("/"), path.utf8.count <= Limits.maximumPathBytes else {
            throw LibraryDatabaseError.invalidData("外置相对路径无效")
        }
        let components = NSString(string: path).pathComponents
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LibraryDatabaseError.invalidData("外置相对路径尝试逃逸")
        }
    }

    private static func validateStoredLevel(_ level: Int) throws {
        guard [0, 2, 3, 4, 5].contains(level) else {
            throw LibraryDatabaseError.invalidData("默认权重不应落盘或档位无效")
        }
    }

    private static func validateStoredWeight(path: String, level: Int) throws {
        do {
            try validatePathKey(path)
            try validateStoredLevel(level)
        } catch {
            throw LibraryDatabaseError.inconsistentState("落盘权重字段无效")
        }
    }

    private static func isValidMetaKey(_ key: String) -> Bool {
        let bytes = key.utf8.count
        return bytes > 0 && bytes <= 256 && !key.utf8.contains(0)
    }

    /// Compares authoritative track rows against the incoming snapshot without
    /// retaining a second copy of every track. This keeps unchanged playlists
    /// out of the delete/reinsert path even when `updatedAt` collides.
    private static func playlistsNeedingTrackReplacement(
        incomingByID: [UUID: UserPlaylist],
        existingIDs: Set<UUID>,
        connection: SQLiteConnection
    ) throws -> Set<UUID> {
        var offsets = Dictionary(
            uniqueKeysWithValues: incomingByID.keys.map { ($0, 0) }
        )
        var replacements = Set(incomingByID.keys.filter { !existingIDs.contains($0) })
        var totalTracks = 0
        try connection.forEachRow(
            """
            SELECT playlist_id, track_id, path, sig_path_key, sig_size, sig_mtime_ns,
                   sig_inode, sig_file_resource_id, sig_volume_id, location_id, relative_path
            FROM playlist_tracks
            ORDER BY playlist_id ASC, sort_key ASC
            """
        ) { row in
            totalTracks += 1
            guard totalTracks <= Limits.maximumPlaylistTracks,
                  let rawPlaylistID = row.string(at: 0),
                  let playlistID = UUID(uuidString: rawPlaylistID) else {
                throw LibraryDatabaseError.inconsistentState("歌单歌曲行无法解码")
            }
            guard let incoming = incomingByID[playlistID] else {
                // Tracks belonging to a removed playlist will be deleted by the
                // parent-row cascade and do not need to be materialized.
                return true
            }
            let offset = offsets[playlistID] ?? 0
            guard offset < incoming.tracks.count else {
                replacements.insert(playlistID)
                offsets[playlistID] = offset + 1
                return true
            }
            let storedTrack = try decodePlaylistTrack(row, trackIDIndex: 1, pathIndex: 2)
            if storedTrack != incoming.tracks[offset] {
                replacements.insert(playlistID)
            }
            offsets[playlistID] = offset + 1
            return true
        }
        for (playlistID, playlist) in incomingByID {
            if offsets[playlistID] != playlist.tracks.count {
                replacements.insert(playlistID)
            }
        }
        return replacements
    }

    private static func decodePlaylistTrack(
        _ row: SQLiteRow,
        trackIDIndex: Int,
        pathIndex: Int
    ) throws -> UserPlaylist.Track {
        guard let rawTrackID = row.string(at: trackIDIndex),
              let trackID = UUID(uuidString: rawTrackID),
              let path = row.string(at: pathIndex) else {
            throw LibraryDatabaseError.inconsistentState("歌单歌曲行无法解码")
        }
        return UserPlaylist.Track(
            id: trackID,
            path: path,
            signature: try decodeSignature(row, start: pathIndex + 1),
            locationID: try decodeOptionalUUID(
                row,
                at: pathIndex + 7,
                field: "location_id"
            ),
            relativePath: row.string(at: pathIndex + 8)
        )
    }

    // MARK: - Batch insertion

    private static func insertQueueEntries(
        _ entries: [LibraryQueueEntry],
        connection: SQLiteConnection
    ) throws {
        for chunk in entries.chunked(maximumCount: Limits.insertChunkSize) {
            let placeholders = Array(repeating: "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", count: chunk.count)
                .joined(separator: ",")
            var bindings: [SQLiteValue] = []
            bindings.reserveCapacity(chunk.count * 12)
            for entry in chunk {
                bindings.append(contentsOf: [
                    .text(entry.id.uuidString), .integer(entry.sortKey), .text(entry.path),
                    .text(PathKey.canonical(path: entry.path)),
                ])
                bindings.append(contentsOf: signatureBindings(entry.signature))
                bindings.append(entry.locationID.map { .text($0.uuidString) } ?? .null)
                bindings.append(entry.relativePath.map(SQLiteValue.text) ?? .null)
            }
            try connection.execute(
                """
                INSERT INTO queue_entries(
                    entry_id, sort_key, path, path_key, sig_path_key, sig_size,
                    sig_mtime_ns, sig_inode, sig_file_resource_id, sig_volume_id,
                    location_id, relative_path
                ) VALUES \(placeholders)
                """,
                bindings: bindings
            )
        }
    }

    private static func insertQueueRekeys(
        _ intents: [LibraryQueueRekeyIntent],
        connection: SQLiteConnection
    ) throws {
        for intent in intents {
            try connection.execute(
                """
                INSERT INTO queue_rekey_intents(
                    intent_id, old_path, old_path_key, new_path, new_path_key, created_at
                ) VALUES(?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(intent.id.uuidString), .text(intent.oldPath),
                    .text(PathKey.canonical(path: intent.oldPath)), .text(intent.newPath),
                    .text(PathKey.canonical(path: intent.newPath)),
                    .real(intent.createdAt.timeIntervalSinceReferenceDate),
                ]
            )
        }
    }

    private static func insertPlaylists(
        _ playlists: [UserPlaylist],
        connection: SQLiteConnection
    ) throws {
        for (index, playlist) in playlists.enumerated() {
            try connection.execute(
                """
                INSERT INTO playlists(
                    playlist_id, name, sort_key, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(playlist.id.uuidString), .text(playlist.name),
                    .integer(Int64(index) * 1_024),
                    .real(playlist.createdAt.timeIntervalSinceReferenceDate),
                    .real(playlist.updatedAt.timeIntervalSinceReferenceDate),
                ]
            )
            try insertPlaylistTracks(
                playlist.tracks,
                playlistID: playlist.id,
                connection: connection
            )
        }
    }

    private static func insertPlaylistTracks(
        _ tracks: [UserPlaylist.Track],
        playlistID: UUID,
        connection: SQLiteConnection
    ) throws {
        for chunkStart in stride(from: 0, to: tracks.count, by: Limits.insertChunkSize) {
            let end = min(tracks.count, chunkStart + Limits.insertChunkSize)
            let chunk = tracks[chunkStart..<end]
            let placeholders = Array(
                repeating: "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                count: chunk.count
            ).joined(separator: ",")
            var bindings: [SQLiteValue] = []
            bindings.reserveCapacity(chunk.count * 13)
            for (offset, track) in chunk.enumerated() {
                bindings.append(contentsOf: [
                    .text(track.id.uuidString), .text(playlistID.uuidString),
                    .integer(Int64(chunkStart + offset) * 1_024), .text(track.path),
                    .text(PathKey.canonical(path: track.path)),
                ])
                bindings.append(contentsOf: signatureBindings(track.signature))
                bindings.append(track.locationID.map { .text($0.uuidString) } ?? .null)
                bindings.append(track.relativePath.map(SQLiteValue.text) ?? .null)
            }
            try connection.execute(
                """
                INSERT INTO playlist_tracks(
                    track_id, playlist_id, sort_key, path, path_key, sig_path_key,
                    sig_size, sig_mtime_ns, sig_inode, sig_file_resource_id, sig_volume_id,
                    location_id, relative_path
                ) VALUES \(placeholders)
                """,
                bindings: bindings
            )
        }
    }

    private static func insertCleanup(
        _ intents: [PlaylistCleanupIntent],
        connection: SQLiteConnection
    ) throws {
        for intent in intents {
            let kind: Int
            switch intent.kind {
            case .deletePlaylist: kind = 0
            case .removeTracks: kind = 1
            case .relocateTracks: kind = 2
            }
            try connection.execute(
                """
                INSERT INTO playlist_cleanup_intents(
                    intent_id, kind, playlist_id, created_at
                ) VALUES(?, ?, ?, ?)
                """,
                bindings: [
                    .text(intent.id.uuidString), .integer(Int64(kind)),
                    .text(intent.playlistID.uuidString),
                    .real(intent.createdAt.timeIntervalSinceReferenceDate),
                ]
            )
            let relocations = intent.trackRelocations ?? []
            if !relocations.isEmpty {
                for (ordinal, relocation) in relocations.enumerated() {
                    try connection.execute(
                        """
                        INSERT INTO playlist_cleanup_items(
                            intent_id, ordinal, track_id, old_path, old_path_key,
                            new_path, new_path_key
                        ) VALUES(?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(intent.id.uuidString), .integer(Int64(ordinal)),
                            relocation.trackID.map { .text($0.uuidString) } ?? .null,
                            .text(relocation.oldPath),
                            .text(PathKey.canonical(path: relocation.oldPath)),
                            .text(relocation.newPath),
                            .text(PathKey.canonical(path: relocation.newPath)),
                        ]
                    )
                }
            } else {
                for (ordinal, path) in intent.trackPaths.enumerated() {
                    let trackID = intent.trackIDs?.indices.contains(ordinal) == true
                        ? intent.trackIDs?[ordinal]
                        : nil
                    try connection.execute(
                        """
                        INSERT INTO playlist_cleanup_items(
                            intent_id, ordinal, track_id, old_path, old_path_key,
                            new_path, new_path_key
                        ) VALUES(?, ?, ?, ?, ?, NULL, NULL)
                        """,
                        bindings: [
                            .text(intent.id.uuidString), .integer(Int64(ordinal)),
                            trackID.map { .text($0.uuidString) } ?? .null,
                            .text(path), .text(PathKey.canonical(path: path)),
                        ]
                    )
                }
            }
        }
    }

    private static func loadCleanupIntents(
        connection: SQLiteConnection
    ) throws -> [PlaylistCleanupIntent] {
        struct Header {
            let id: UUID
            let kind: PlaylistCleanupIntent.Kind
            let playlistID: UUID
            let createdAt: Date
        }
        let headers = try connection.query(
            """
            SELECT intent_id, kind, playlist_id, created_at
            FROM playlist_cleanup_intents ORDER BY created_at ASC, intent_id ASC
            """
        ) { row -> Header in
            guard let id = row.string(at: 0).flatMap(UUID.init(uuidString:)),
                  let rawKind = row.int64(at: 1),
                  let playlistID = row.string(at: 2).flatMap(UUID.init(uuidString:)),
                  let createdAt = row.double(at: 3), createdAt.isFinite else {
                throw LibraryDatabaseError.inconsistentState("清理意图无法解码")
            }
            let kind: PlaylistCleanupIntent.Kind
            switch rawKind {
            case 0: kind = .deletePlaylist
            case 1: kind = .removeTracks
            case 2: kind = .relocateTracks
            default: throw LibraryDatabaseError.inconsistentState("清理意图类型无效")
            }
            return Header(
                id: id,
                kind: kind,
                playlistID: playlistID,
                createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
            )
        }
        guard headers.count <= Limits.maximumCleanupIntents else {
            throw LibraryDatabaseError.inconsistentState("清理意图超过产品上限")
        }
        var result: [PlaylistCleanupIntent] = []
        result.reserveCapacity(headers.count)
        var totalItems = 0
        for header in headers {
            let rows = try connection.query(
                """
                SELECT track_id, old_path, new_path
                FROM playlist_cleanup_items
                WHERE intent_id = ? ORDER BY ordinal ASC
                """,
                bindings: [.text(header.id.uuidString)]
            ) { row -> (UUID?, String, String?) in
                guard let oldPath = row.string(at: 1) else {
                    throw LibraryDatabaseError.inconsistentState("清理意图歌曲无法解码")
                }
                let trackID = try decodeOptionalUUID(row, at: 0, field: "track_id")
                return (trackID, oldPath, row.string(at: 2))
            }
            totalItems += rows.count
            guard totalItems <= Limits.maximumPlaylistTracks else {
                throw LibraryDatabaseError.inconsistentState("清理意图歌曲超过产品上限")
            }
            let paths = rows.map { $0.1 }
            let trackIDs = rows.compactMap { $0.0 }
            let relocations: [PlaylistCleanupIntent.TrackRelocation]?
            if header.kind == .relocateTracks {
                relocations = try rows.map { trackID, oldPath, newPath in
                    guard let newPath else {
                        throw LibraryDatabaseError.inconsistentState("迁移清理意图缺少新路径")
                    }
                    return .init(trackID: trackID, oldPath: oldPath, newPath: newPath)
                }
            } else {
                guard rows.allSatisfy({ $0.2 == nil }) else {
                    throw LibraryDatabaseError.inconsistentState("非迁移清理意图包含新路径")
                }
                relocations = nil
            }
            result.append(
                PlaylistCleanupIntent(
                    id: header.id,
                    kind: header.kind,
                    playlistID: header.playlistID,
                    trackPaths: paths,
                    trackIDs: trackIDs.isEmpty ? nil : trackIDs,
                    trackRelocations: relocations,
                    createdAt: header.createdAt
                )
            )
        }
        return result
    }

    private static func insertWeights(
        _ snapshot: LibraryWeightsSnapshot,
        connection: SQLiteConnection
    ) throws {
        for (path, level) in snapshot.queueLevels {
            try connection.execute(
                "INSERT INTO queue_weight_overrides(path_key, level) VALUES(?, ?)",
                bindings: [.text(path), .integer(Int64(level))]
            )
        }
        for (playlistID, levels) in snapshot.playlistLevels {
            for (path, level) in levels {
                try connection.execute(
                    """
                    INSERT INTO playlist_weight_overrides(playlist_id, path_key, level)
                    VALUES(?, ?, ?)
                    """,
                    bindings: [
                        .text(playlistID.uuidString), .text(path), .integer(Int64(level)),
                    ]
                )
            }
        }
    }

    private static func storePlaybackSession(
        _ session: LibraryPlaybackSession,
        connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            INSERT INTO playback_session(
                singleton, revision, scope_kind, playlist_id, scope_track_id,
                queue_entry_id, fallback_path, position_ms
            ) VALUES(1, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET
                revision = excluded.revision,
                scope_kind = excluded.scope_kind,
                playlist_id = excluded.playlist_id,
                scope_track_id = excluded.scope_track_id,
                queue_entry_id = excluded.queue_entry_id,
                fallback_path = excluded.fallback_path,
                position_ms = excluded.position_ms
            WHERE excluded.revision > playback_session.revision
            """,
            bindings: [
                .integer(try sqliteRevision(session.revision)),
                .integer(Int64(session.scope.rawValue)),
                session.playlistID.map { .text($0.uuidString) } ?? .null,
                session.scopeTrackID.map { .text($0.uuidString) } ?? .null,
                session.queueEntryID.map { .text($0.uuidString) } ?? .null,
                session.fallbackPath.map(SQLiteValue.text) ?? .null,
                .integer(session.positionMilliseconds),
            ]
        )
        try requireExactlyOneChangedRow(connection, metadata: "playback_session")
    }

    private static func signatureBindings(_ signature: FileSignature?) -> [SQLiteValue] {
        guard let signature else { return Array(repeating: .null, count: 6) }
        return [
            .text(signature.pathKey), .integer(signature.size),
            .integer(signature.modificationTimeNanoseconds),
            signature.inode.map { .text(String($0)) } ?? .null,
            signature.fileResourceIdentifier.map(SQLiteValue.text) ?? .null,
            signature.volumeIdentifier.map(SQLiteValue.text) ?? .null,
        ]
    }

    private static func decodeOptionalUUID(
        _ row: SQLiteRow,
        at index: Int,
        field: String
    ) throws -> UUID? {
        switch row.value(at: index) {
        case .null:
            return nil
        case .text(let raw):
            guard let value = UUID(uuidString: raw) else {
                throw LibraryDatabaseError.inconsistentState("\(field) 身份无效")
            }
            return value
        default:
            throw LibraryDatabaseError.inconsistentState("\(field) 类型无效")
        }
    }

    private static func decodeSignature(
        _ row: SQLiteRow,
        start: Int
    ) throws -> FileSignature? {
        let values = (0..<6).map { row.value(at: start + $0) }
        if values.allSatisfy({ $0 == .null }) { return nil }
        guard let pathKey = row.string(at: start),
              let size = row.int64(at: start + 1),
              let mtime = row.int64(at: start + 2) else {
            throw LibraryDatabaseError.inconsistentState("文件签名字段不完整")
        }
        let inode: UInt64?
        switch row.value(at: start + 3) {
        case .null:
            inode = nil
        case .text(let raw):
            guard let parsed = UInt64(raw) else {
                throw LibraryDatabaseError.inconsistentState("文件签名 inode 无效")
            }
            inode = parsed
        default:
            throw LibraryDatabaseError.inconsistentState("文件签名 inode 类型无效")
        }
        for index in [start + 4, start + 5] {
            switch row.value(at: index) {
            case .null, .text(_):
                break
            default:
                throw LibraryDatabaseError.inconsistentState("文件签名标识类型无效")
            }
        }
        let signature = FileSignature(
            pathKey: pathKey,
            size: size,
            modificationTimeNanoseconds: mtime,
            inode: inode,
            fileResourceIdentifier: row.string(at: start + 4),
            volumeIdentifier: row.string(at: start + 5)
        )
        do {
            try validate(signature: signature)
        } catch {
            throw LibraryDatabaseError.inconsistentState("文件签名字段无效")
        }
        return signature
    }
}

private extension Collection {
    func chunked(maximumCount: Int) -> [SubSequence] {
        precondition(maximumCount > 0)
        var chunks: [SubSequence] = []
        chunks.reserveCapacity((count + maximumCount - 1) / maximumCount)
        var cursor = startIndex
        while cursor != endIndex {
            let next = index(cursor, offsetBy: maximumCount, limitedBy: endIndex) ?? endIndex
            chunks.append(self[cursor..<next])
            cursor = next
        }
        return chunks
    }
}
