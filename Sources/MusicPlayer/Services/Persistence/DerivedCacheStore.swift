import Foundation

/// Shared, low-memory persistence for cache data that can always be rebuilt
/// from the user's media files. The store intentionally keeps user-authored
/// library state out of this database so the complete file may be evicted.
final class DerivedCacheStore: @unchecked Sendable {
    static let shared: DerivedCacheStore? = {
        do {
            let environment = try PersistenceEnvironment.production()
            let directory = try environment.prepareCachesDirectory()
            return try DerivedCacheStore(
                databaseURL: directory.appendingPathComponent(
                    "derived-cache.sqlite3",
                    isDirectory: false
                )
            )
        } catch {
            PersistenceLogger.log("初始化派生缓存数据库失败：\(error.localizedDescription)")
            return nil
        }
    }()

    enum CacheKind: String, CaseIterable, Hashable, Sendable {
        case metadata
        case duration
        case immersive

        fileprivate var tableName: String {
            switch self {
            case .metadata: return "metadata_cache"
            case .duration: return "duration_cache"
            case .immersive: return "immersive_cache"
            }
        }
    }

    struct FileIdentity: Equatable, Sendable {
        let fileSize: Int64
        let modificationTimeNanoseconds: Int64
        let fileIdentifier: Int64?

        init(
            fileSize: Int64,
            modificationTimeNanoseconds: Int64,
            fileIdentifier: Int64?
        ) {
            self.fileSize = fileSize
            self.modificationTimeNanoseconds = modificationTimeNanoseconds
            self.fileIdentifier = fileIdentifier
        }
    }

    struct Record: Equatable, Sendable {
        let kind: CacheKind
        let key: String
        /// Identifies the payload/algorithm format. Metadata and duration may
        /// use a short schema tag; immersive analysis should use its complete
        /// algorithm/configuration signature.
        let variant: String
        let payload: Data
        let fileIdentity: FileIdentity
        let updatedAt: TimeInterval
        let lastAccessedAt: TimeInterval

        init(
            kind: CacheKind,
            key: String,
            variant: String = "",
            payload: Data,
            fileIdentity: FileIdentity,
            updatedAt: TimeInterval,
            lastAccessedAt: TimeInterval
        ) {
            self.kind = kind
            self.key = key
            self.variant = variant
            self.payload = payload
            self.fileIdentity = fileIdentity
            self.updatedAt = updatedAt
            self.lastAccessedAt = lastAccessedAt
        }
    }

    struct TableLimit: Equatable, Sendable {
        let maximumEntries: Int
        let lowWatermark: Int

        init(maximumEntries: Int, lowWatermark: Int) {
            let maximumEntries = max(1, maximumEntries)
            self.maximumEntries = maximumEntries
            self.lowWatermark = min(max(0, lowWatermark), maximumEntries)
        }
    }

    struct Limits: Equatable, Sendable {
        static let standard = Limits()

        let metadata: TableLimit
        let duration: TableLimit
        let immersive: TableLimit
        let maximumKeyBytes: Int
        let maximumVariantBytes: Int
        let maximumPayloadBytes: Int
        let maximumMigrationKeyBytes: Int
        let maximumMigrationFingerprintBytes: Int
        let maximumMigrationMarkers: Int
        let migrationMarkerLowWatermark: Int
        let maximumPendingOperations: Int
        let writeDelay: TimeInterval
        let accessRefreshInterval: TimeInterval

        init(
            metadata: TableLimit = TableLimit(maximumEntries: 100_000, lowWatermark: 90_000),
            duration: TableLimit = TableLimit(maximumEntries: 100_000, lowWatermark: 90_000),
            immersive: TableLimit = TableLimit(maximumEntries: 100_000, lowWatermark: 90_000),
            maximumKeyBytes: Int = 16 * 1_024,
            maximumVariantBytes: Int = 4 * 1_024,
            maximumPayloadBytes: Int = 256 * 1_024,
            maximumMigrationKeyBytes: Int = 1_024,
            maximumMigrationFingerprintBytes: Int = 4 * 1_024,
            maximumMigrationMarkers: Int = 256,
            migrationMarkerLowWatermark: Int = 224,
            maximumPendingOperations: Int = 256,
            writeDelay: TimeInterval = 0.25,
            accessRefreshInterval: TimeInterval = 24 * 60 * 60
        ) {
            self.metadata = metadata
            self.duration = duration
            self.immersive = immersive
            // The schema repeats these ceilings as CHECK constraints. Clamp
            // injected limits so validation can never accept a row SQLite will
            // subsequently reject for exceeding the physical schema bound.
            self.maximumKeyBytes = min(16 * 1_024, max(1, maximumKeyBytes))
            self.maximumVariantBytes = min(4 * 1_024, max(0, maximumVariantBytes))
            self.maximumPayloadBytes = min(256 * 1_024, max(1, maximumPayloadBytes))
            self.maximumMigrationKeyBytes = min(1_024, max(1, maximumMigrationKeyBytes))
            self.maximumMigrationFingerprintBytes = min(
                4 * 1_024,
                max(1, maximumMigrationFingerprintBytes)
            )
            let maximumMigrationMarkers = max(1, maximumMigrationMarkers)
            self.maximumMigrationMarkers = maximumMigrationMarkers
            self.migrationMarkerLowWatermark = min(
                max(0, migrationMarkerLowWatermark),
                maximumMigrationMarkers
            )
            self.maximumPendingOperations = max(1, maximumPendingOperations)
            self.writeDelay = max(0.01, writeDelay)
            self.accessRefreshInterval = max(0, accessRefreshInterval)
        }

        fileprivate func tableLimit(for kind: CacheKind) -> TableLimit {
            switch kind {
            case .metadata: return metadata
            case .duration: return duration
            case .immersive: return immersive
            }
        }
    }

    struct MigrationMarker: Equatable, Sendable {
        let key: String
        let sourceFingerprint: String
        let completedAt: TimeInterval

        init(key: String, sourceFingerprint: String, completedAt: TimeInterval) {
            self.key = key
            self.sourceFingerprint = sourceFingerprint
            self.completedAt = completedAt
        }
    }

    enum AccessMode: Equatable, Sendable {
        case writable
        case readOnlyFuture(schemaVersion: Int)
        case readOnlyForeign(applicationID: Int32)
    }

    enum StoreError: Error, Equatable, LocalizedError, Sendable {
        case storageUnavailable
        case readOnly(AccessMode)
        case invalidKey
        case invalidVariant
        case payloadTooLarge(maximumBytes: Int)
        case invalidRecord
        case invalidMigrationMarker
        case staleGeneration(kind: CacheKind, expected: UInt64, actual: UInt64)
        case databaseFailure(String)

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "派生缓存目录不可用"
            case .readOnly:
                return "派生缓存数据库处于只读保护"
            case .invalidKey:
                return "派生缓存键为空或超过长度限制"
            case .invalidVariant:
                return "派生缓存版本标识超过长度限制"
            case .payloadTooLarge(let maximumBytes):
                return "派生缓存负载超过 \(maximumBytes) 字节限制"
            case .invalidRecord:
                return "派生缓存记录包含无效字段"
            case .invalidMigrationMarker:
                return "派生缓存迁移标记无效"
            case .staleGeneration:
                return "派生缓存写入来自已失效的任务"
            case .databaseFailure(let detail):
                return "派生缓存数据库操作失败：\(detail)"
            }
        }
    }

    struct Mutation: Sendable {
        fileprivate enum Operation: Sendable {
            case upsert(Record)
            case delete(kind: CacheKind, key: String, variant: String)
        }

        fileprivate let operation: Operation
        fileprivate let expectedGeneration: UInt64?

        static func upsert(
            _ record: Record,
            expectedGeneration: UInt64? = nil
        ) -> Mutation {
            Mutation(operation: .upsert(record), expectedGeneration: expectedGeneration)
        }

        static func delete(
            kind: CacheKind,
            key: String,
            variant: String = "",
            expectedGeneration: UInt64? = nil
        ) -> Mutation {
            Mutation(
                operation: .delete(kind: kind, key: key, variant: variant),
                expectedGeneration: expectedGeneration
            )
        }
    }

    struct EnqueueReport: Equatable, Sendable {
        let acceptedMutationCount: Int
        let acceptedMigrationMarkerCount: Int
    }

    struct FlushReport: Equatable, Sendable {
        let wroteDatabase: Bool
        let appliedMutationCount: Int
        let appliedMigrationMarkerCount: Int
        let prunedEntryCount: Int
        let prunedMigrationMarkerCount: Int
    }

    struct ClearReport: Equatable, Sendable {
        let removedEntryCount: Int
        let clearedKinds: Set<CacheKind>
    }

    static let applicationID: Int32 = 0x4D50_4443 // "MPDC"
    static let schemaVersion = 1
    static let databaseFileName = "derived-cache.sqlite3"

    private struct RecordIdentity: Hashable {
        let kind: CacheKind
        let key: String
        let variant: String
    }

    private enum PendingMutation {
        case upsert(Record)
        case delete
        case touch(TimeInterval)
    }

    private static let schema = SQLiteSchema(
        applicationID: applicationID,
        version: schemaVersion,
        migrations: [
            SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                for kind in CacheKind.allCases {
                    try connection.execute(
                        """
                        CREATE TABLE \(kind.tableName)(
                            path_key TEXT NOT NULL,
                            variant TEXT NOT NULL,
                            payload BLOB NOT NULL,
                            file_size INTEGER NOT NULL,
                            mtime_ns INTEGER NOT NULL,
                            file_identifier INTEGER,
                            updated_at REAL NOT NULL,
                            last_accessed_at REAL NOT NULL,
                            PRIMARY KEY(path_key, variant),
                            CHECK(length(CAST(path_key AS BLOB)) BETWEEN 1 AND 16384),
                            CHECK(length(CAST(variant AS BLOB)) <= 4096),
                            CHECK(length(payload) <= 262144),
                            CHECK(file_size >= 0)
                        )
                        """
                    )
                    try connection.execute(
                        "CREATE INDEX \(kind.tableName)_lru ON \(kind.tableName)(last_accessed_at, updated_at, path_key, variant)"
                    )
                }
                try connection.execute(
                    """
                    CREATE TABLE migration_markers(
                        marker_key TEXT PRIMARY KEY NOT NULL,
                        source_fingerprint TEXT NOT NULL,
                        completed_at REAL NOT NULL,
                        CHECK(length(CAST(marker_key AS BLOB)) BETWEEN 1 AND 1024),
                        CHECK(length(CAST(source_fingerprint AS BLOB)) BETWEEN 1 AND 4096)
                    )
                    """
                )
            }
        ]
    )

    private let queue = DispatchQueue(label: "musicplayer.derived-cache.store", qos: .utility)
    private let limits: Limits
    private let now: @Sendable () -> TimeInterval
    private var database: SQLiteDatabase
    private var pendingMutations: [RecordIdentity: PendingMutation] = [:]
    private var pendingMigrationMarkers: [String: MigrationMarker] = [:]
    private var generations: [CacheKind: UInt64] = Dictionary(
        uniqueKeysWithValues: CacheKind.allCases.map { ($0, 0) }
    )
    private var scheduledFlush: DispatchWorkItem?
    private var retryAttempt = 0

    convenience init(
        limits: Limits = .standard,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) throws {
        guard let databaseURL = Self.defaultDatabaseURL() else {
            throw StoreError.storageUnavailable
        }
        try self.init(databaseURL: databaseURL, limits: limits, now: now)
    }

    init(
        databaseURL: URL,
        limits: Limits = .standard,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) throws {
        self.limits = limits
        self.now = now

        var configuration = SQLiteConfiguration.production
        configuration.pageCacheKiB = 512
        configuration.journalSizeLimitBytes = 1_048_576
        configuration.walAutoCheckpointPages = 128
        configuration.keepsTemporaryTablesInMemory = false
        database = try SQLiteDatabase(
            fileURL: databaseURL,
            schema: Self.schema,
            configuration: configuration
        )
    }

    deinit {
        scheduledFlush?.cancel()
        database.close()
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("MusicPlayer", isDirectory: true)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    var accessMode: AccessMode {
        queue.sync { mappedAccessModeLocked() }
    }

    func generation(for kind: CacheKind) -> UInt64 {
        queue.sync { generations[kind, default: 0] }
    }

    /// Returns one matching record without materializing any other cache rows.
    /// A mismatched file identity is treated as a miss and removed lazily when
    /// the database is writable.
    func record(
        kind: CacheKind,
        key: String,
        variant: String = "",
        matching expectedIdentity: FileIdentity? = nil,
        touch: Bool = true
    ) -> Record? {
        queue.sync {
            guard validateKey(key), validateVariant(variant) else { return nil }
            let identity = RecordIdentity(kind: kind, key: key, variant: variant)

            let loaded: Record?
            switch pendingMutations[identity] {
            case .upsert(let record):
                loaded = record
            case .delete:
                return nil
            case .touch(let timestamp):
                loaded = fetchRecordLocked(identity: identity).map {
                    Record(
                        kind: $0.kind,
                        key: $0.key,
                        variant: $0.variant,
                        payload: $0.payload,
                        fileIdentity: $0.fileIdentity,
                        updatedAt: $0.updatedAt,
                        lastAccessedAt: max($0.lastAccessedAt, timestamp)
                    )
                }
            case nil:
                loaded = fetchRecordLocked(identity: identity)
            }

            guard var record = loaded, validate(record) == nil else {
                if loaded != nil, database.accessMode == .writable {
                    mergePendingLocked(.delete, identity: identity)
                    scheduleFlushLocked()
                }
                return nil
            }
            if let expectedIdentity, record.fileIdentity != expectedIdentity {
                if database.accessMode == .writable {
                    mergePendingLocked(.delete, identity: identity)
                    scheduleFlushLocked()
                }
                return nil
            }

            let timestamp = now()
            if touch,
               timestamp.isFinite,
               timestamp - record.lastAccessedAt >= limits.accessRefreshInterval,
               database.accessMode == .writable {
                record = Record(
                    kind: record.kind,
                    key: record.key,
                    variant: record.variant,
                    payload: record.payload,
                    fileIdentity: record.fileIdentity,
                    updatedAt: record.updatedAt,
                    lastAccessedAt: timestamp
                )
                mergePendingLocked(.touch(timestamp), identity: identity)
                scheduleFlushLocked()
            }
            return record
        }
    }

    @discardableResult
    func enqueue(
        _ mutations: [Mutation],
        migrationMarkers: [MigrationMarker] = []
    ) -> Result<EnqueueReport, StoreError> {
        queue.sync {
            let mode = mappedAccessModeLocked()
            guard mode == .writable else { return .failure(.readOnly(mode)) }

            for mutation in mutations {
                if let error = validate(mutation) { return .failure(error) }
                let kind = kind(of: mutation)
                if let expected = mutation.expectedGeneration {
                    let actual = generations[kind, default: 0]
                    guard expected == actual else {
                        return .failure(
                            .staleGeneration(kind: kind, expected: expected, actual: actual)
                        )
                    }
                }
            }
            for marker in migrationMarkers {
                guard validate(marker) else { return .failure(.invalidMigrationMarker) }
            }

            retryAttempt = 0
            // Drain while accepting a large migration/import batch instead of
            // retaining every row until the caller explicitly flushes. A final
            // migration marker is enqueued only after every preceding chunk has
            // committed; a crash before that marker simply causes an idempotent
            // retry on the next launch.
            for mutation in mutations {
                mergePendingLocked(mutation)
                if pendingOperationCount >= limits.maximumPendingOperations {
                    scheduledFlush?.cancel()
                    scheduledFlush = nil
                    switch drainPendingLocked() {
                    case .success:
                        break
                    case .failure(let error):
                        scheduleRetryLocked()
                        return .failure(error)
                    }
                }
            }
            for marker in migrationMarkers {
                pendingMigrationMarkers[marker.key] = marker
                if pendingOperationCount >= limits.maximumPendingOperations {
                    scheduledFlush?.cancel()
                    scheduledFlush = nil
                    switch drainPendingLocked() {
                    case .success:
                        break
                    case .failure(let error):
                        scheduleRetryLocked()
                        return .failure(error)
                    }
                }
            }

            if pendingOperationCount > 0 {
                scheduleFlushLocked()
            }

            return .success(
                EnqueueReport(
                    acceptedMutationCount: mutations.count,
                    acceptedMigrationMarkerCount: migrationMarkers.count
                )
            )
        }
    }

    @discardableResult
    func flush() -> Result<FlushReport, StoreError> {
        queue.sync {
            let mode = mappedAccessModeLocked()
            guard mode == .writable else { return .failure(.readOnly(mode)) }
            scheduledFlush?.cancel()
            scheduledFlush = nil
            let result = drainPendingLocked()
            if case .failure = result { scheduleRetryLocked() }
            return result
        }
    }

    func migrationMarker(for key: String) -> MigrationMarker? {
        queue.sync {
            if let pending = pendingMigrationMarkers[key] { return pending }
            guard validateMigrationKey(key) else { return nil }
            do {
                return try database.query(
                    "SELECT marker_key, source_fingerprint, completed_at FROM migration_markers WHERE marker_key = ? LIMIT 1",
                    bindings: [.text(key)]
                ) { row in
                    guard let markerKey = row.string(at: 0),
                          let fingerprint = row.string(at: 1),
                          let completedAt = row.double(at: 2) else { return nil }
                    return MigrationMarker(
                        key: markerKey,
                        sourceFingerprint: fingerprint,
                        completedAt: completedAt
                    )
                }.first ?? nil
            } catch {
                return nil
            }
        }
    }

    /// Returns the durable row count. Call `flush()` first when the caller also
    /// needs pending in-memory mutations reflected in this value.
    func persistedEntryCount(for kind: CacheKind) -> Int {
        queue.sync {
            Int(
                (try? database.scalarInt("SELECT COUNT(*) FROM \(kind.tableName)")) ?? 0
            )
        }
    }

    @discardableResult
    func clear(_ kind: CacheKind) -> Result<ClearReport, StoreError> {
        clear(kinds: [kind])
    }

    @discardableResult
    func clearAll() -> Result<ClearReport, StoreError> {
        clear(kinds: Set(CacheKind.allCases))
    }

    /// Forces capacity maintenance even when no new rows were inserted.
    @discardableResult
    func pruneNow() -> Result<Int, StoreError> {
        queue.sync {
            let mode = mappedAccessModeLocked()
            guard mode == .writable else { return .failure(.readOnly(mode)) }
            scheduledFlush?.cancel()
            scheduledFlush = nil
            switch drainPendingLocked() {
            case .failure(let error):
                scheduleRetryLocked()
                return .failure(error)
            case .success:
                break
            }

            do {
                var pruned = 0
                try database.transaction { connection in
                    for kind in CacheKind.allCases {
                        pruned += try pruneLocked(kind: kind, connection: connection)
                    }
                }
                return .success(pruned)
            } catch {
                return .failure(.databaseFailure(error.localizedDescription))
            }
        }
    }

    private var pendingOperationCount: Int {
        pendingMutations.count + pendingMigrationMarkers.count
    }

    private func mappedAccessModeLocked() -> AccessMode {
        switch database.accessMode {
        case .writable:
            return .writable
        case .readOnlyFuture(let version):
            return .readOnlyFuture(schemaVersion: version)
        case .readOnlyForeign(let applicationID):
            return .readOnlyForeign(applicationID: applicationID)
        }
    }

    private func kind(of mutation: Mutation) -> CacheKind {
        switch mutation.operation {
        case .upsert(let record): return record.kind
        case .delete(let kind, _, _): return kind
        }
    }

    private func identity(of mutation: Mutation) -> RecordIdentity {
        switch mutation.operation {
        case .upsert(let record):
            return RecordIdentity(kind: record.kind, key: record.key, variant: record.variant)
        case .delete(let kind, let key, let variant):
            return RecordIdentity(kind: kind, key: key, variant: variant)
        }
    }

    private func validate(_ mutation: Mutation) -> StoreError? {
        switch mutation.operation {
        case .upsert(let record):
            return validate(record)
        case .delete(_, let key, let variant):
            guard validateKey(key) else { return .invalidKey }
            guard validateVariant(variant) else { return .invalidVariant }
            return nil
        }
    }

    private func validate(_ record: Record) -> StoreError? {
        guard validateKey(record.key) else { return .invalidKey }
        guard validateVariant(record.variant) else { return .invalidVariant }
        guard record.payload.count <= limits.maximumPayloadBytes else {
            return .payloadTooLarge(maximumBytes: limits.maximumPayloadBytes)
        }
        guard record.fileIdentity.fileSize >= 0,
              record.updatedAt.isFinite,
              record.lastAccessedAt.isFinite else {
            return .invalidRecord
        }
        return nil
    }

    private func validate(_ marker: MigrationMarker) -> Bool {
        validateMigrationKey(marker.key)
            && !marker.sourceFingerprint.isEmpty
            && marker.sourceFingerprint.utf8.count <= limits.maximumMigrationFingerprintBytes
            && marker.completedAt.isFinite
    }

    private func validateKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= limits.maximumKeyBytes
    }

    private func validateVariant(_ variant: String) -> Bool {
        variant.utf8.count <= limits.maximumVariantBytes
    }

    private func validateMigrationKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= limits.maximumMigrationKeyBytes
    }

    private func mergePendingLocked(_ mutation: Mutation) {
        let identity = identity(of: mutation)
        switch mutation.operation {
        case .upsert(let record):
            mergePendingLocked(.upsert(record), identity: identity)
        case .delete:
            mergePendingLocked(.delete, identity: identity)
        }
    }

    private func mergePendingLocked(
        _ mutation: PendingMutation,
        identity: RecordIdentity
    ) {
        switch (pendingMutations[identity], mutation) {
        case (.upsert(let record), .touch(let timestamp)):
            pendingMutations[identity] = .upsert(
                Record(
                    kind: record.kind,
                    key: record.key,
                    variant: record.variant,
                    payload: record.payload,
                    fileIdentity: record.fileIdentity,
                    updatedAt: record.updatedAt,
                    lastAccessedAt: max(record.lastAccessedAt, timestamp)
                )
            )
        case (.delete, .touch):
            break
        case (.touch(let existing), .touch(let timestamp)):
            pendingMutations[identity] = .touch(max(existing, timestamp))
        default:
            pendingMutations[identity] = mutation
        }
    }

    private func scheduleFlushLocked() {
        scheduledFlush?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runScheduledFlush()
        }
        scheduledFlush = workItem
        queue.asyncAfter(deadline: .now() + limits.writeDelay, execute: workItem)
    }

    private func runScheduledFlush() {
        scheduledFlush = nil
        switch drainPendingLocked() {
        case .success:
            retryAttempt = 0
        case .failure:
            scheduleRetryLocked()
        }
    }

    private func scheduleRetryLocked() {
        guard database.accessMode == .writable,
              pendingOperationCount > 0,
              retryAttempt < 3 else { return }
        scheduledFlush?.cancel()
        let delays: [TimeInterval] = [2, 10, 60]
        let delay = delays[retryAttempt]
        retryAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            self?.runScheduledFlush()
        }
        scheduledFlush = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func drainPendingLocked() -> Result<FlushReport, StoreError> {
        guard !pendingMutations.isEmpty || !pendingMigrationMarkers.isEmpty else {
            return .success(
                FlushReport(
                    wroteDatabase: false,
                    appliedMutationCount: 0,
                    appliedMigrationMarkerCount: 0,
                    prunedEntryCount: 0,
                    prunedMigrationMarkerCount: 0
                )
            )
        }

        let mutationSnapshot = pendingMutations.sorted { lhs, rhs in
            if lhs.key.kind.rawValue != rhs.key.kind.rawValue {
                return lhs.key.kind.rawValue < rhs.key.kind.rawValue
            }
            if lhs.key.key != rhs.key.key { return lhs.key.key < rhs.key.key }
            return lhs.key.variant < rhs.key.variant
        }
        let markerSnapshot = pendingMigrationMarkers.values.sorted { $0.key < $1.key }
        let touchedKinds = Set(mutationSnapshot.compactMap { item -> CacheKind? in
            if case .upsert = item.value { return item.key.kind }
            return nil
        })

        do {
            var prunedEntryCount = 0
            var prunedMigrationMarkerCount = 0
            try database.transaction { connection in
                for (identity, mutation) in mutationSnapshot {
                    try applyLocked(mutation, identity: identity, connection: connection)
                }
                for marker in markerSnapshot {
                    try connection.execute(
                        """
                        INSERT INTO migration_markers(marker_key, source_fingerprint, completed_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(marker_key) DO UPDATE SET
                            source_fingerprint = excluded.source_fingerprint,
                            completed_at = excluded.completed_at
                        """,
                        bindings: [
                            .text(marker.key),
                            .text(marker.sourceFingerprint),
                            .real(marker.completedAt)
                        ]
                    )
                }
                if !markerSnapshot.isEmpty {
                    prunedMigrationMarkerCount = try pruneMigrationMarkersLocked(
                        connection: connection
                    )
                }
                for kind in touchedKinds {
                    prunedEntryCount += try pruneLocked(kind: kind, connection: connection)
                }
            }
            pendingMutations.removeAll(keepingCapacity: true)
            pendingMigrationMarkers.removeAll(keepingCapacity: true)
            retryAttempt = 0
            return .success(
                FlushReport(
                    wroteDatabase: true,
                    appliedMutationCount: mutationSnapshot.count,
                    appliedMigrationMarkerCount: markerSnapshot.count,
                    prunedEntryCount: prunedEntryCount,
                    prunedMigrationMarkerCount: prunedMigrationMarkerCount
                )
            )
        } catch {
            return .failure(.databaseFailure(error.localizedDescription))
        }
    }

    private func applyLocked(
        _ mutation: PendingMutation,
        identity: RecordIdentity,
        connection: SQLiteConnection
    ) throws {
        switch mutation {
        case .upsert(let record):
            try connection.execute(
                """
                INSERT INTO \(identity.kind.tableName)(
                    path_key, variant, payload, file_size, mtime_ns,
                    file_identifier, updated_at, last_accessed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path_key, variant) DO UPDATE SET
                    payload = excluded.payload,
                    file_size = excluded.file_size,
                    mtime_ns = excluded.mtime_ns,
                    file_identifier = excluded.file_identifier,
                    updated_at = excluded.updated_at,
                    last_accessed_at = excluded.last_accessed_at
                """,
                bindings: [
                    .text(record.key),
                    .text(record.variant),
                    .blob(record.payload),
                    .integer(record.fileIdentity.fileSize),
                    .integer(record.fileIdentity.modificationTimeNanoseconds),
                    record.fileIdentity.fileIdentifier.map(SQLiteValue.integer) ?? .null,
                    .real(record.updatedAt),
                    .real(record.lastAccessedAt)
                ]
            )
        case .delete:
            try connection.execute(
                "DELETE FROM \(identity.kind.tableName) WHERE path_key = ? AND variant = ?",
                bindings: [.text(identity.key), .text(identity.variant)]
            )
        case .touch(let timestamp):
            try connection.execute(
                "UPDATE \(identity.kind.tableName) SET last_accessed_at = ? WHERE path_key = ? AND variant = ?",
                bindings: [.real(timestamp), .text(identity.key), .text(identity.variant)]
            )
        }
    }

    private func pruneLocked(
        kind: CacheKind,
        connection: SQLiteConnection
    ) throws -> Int {
        let limit = limits.tableLimit(for: kind)
        let count = Int(
            try connection.scalarInt("SELECT COUNT(*) FROM \(kind.tableName)") ?? 0
        )
        guard count > limit.maximumEntries else { return 0 }
        let removeCount = count - limit.lowWatermark
        try connection.execute(
            """
            DELETE FROM \(kind.tableName)
            WHERE rowid IN (
                SELECT rowid FROM \(kind.tableName)
                ORDER BY last_accessed_at ASC, updated_at ASC, path_key ASC, variant ASC
                LIMIT ?
            )
            """,
            bindings: [.integer(Int64(removeCount))]
        )
        return removeCount
    }

    private func pruneMigrationMarkersLocked(connection: SQLiteConnection) throws -> Int {
        let count = Int(
            try connection.scalarInt("SELECT COUNT(*) FROM migration_markers") ?? 0
        )
        guard count > limits.maximumMigrationMarkers else { return 0 }
        let removeCount = count - limits.migrationMarkerLowWatermark
        try connection.execute(
            """
            DELETE FROM migration_markers
            WHERE marker_key IN (
                SELECT marker_key FROM migration_markers
                ORDER BY completed_at ASC, marker_key ASC
                LIMIT ?
            )
            """,
            bindings: [.integer(Int64(removeCount))]
        )
        return removeCount
    }

    private func fetchRecordLocked(identity: RecordIdentity) -> Record? {
        do {
            return try database.query(
                """
                SELECT path_key, variant, payload, file_size, mtime_ns,
                       file_identifier, updated_at, last_accessed_at
                FROM \(identity.kind.tableName)
                WHERE path_key = ? AND variant = ?
                LIMIT 1
                """,
                bindings: [.text(identity.key), .text(identity.variant)]
            ) { row in
                guard let key = row.string(at: 0),
                      let variant = row.string(at: 1),
                      let payload = row.data(at: 2),
                      let fileSize = row.int64(at: 3),
                      let mtime = row.int64(at: 4),
                      let updatedAt = row.double(at: 6),
                      let lastAccessedAt = row.double(at: 7) else { return nil }
                return Record(
                    kind: identity.kind,
                    key: key,
                    variant: variant,
                    payload: payload,
                    fileIdentity: FileIdentity(
                        fileSize: fileSize,
                        modificationTimeNanoseconds: mtime,
                        fileIdentifier: row.int64(at: 5)
                    ),
                    updatedAt: updatedAt,
                    lastAccessedAt: lastAccessedAt
                )
            }.first ?? nil
        } catch {
            return nil
        }
    }

    private func clear(kinds: Set<CacheKind>) -> Result<ClearReport, StoreError> {
        queue.sync {
            let mode = mappedAccessModeLocked()
            guard mode == .writable else { return .failure(.readOnly(mode)) }
            guard !kinds.isEmpty else {
                return .success(ClearReport(removedEntryCount: 0, clearedKinds: []))
            }

            scheduledFlush?.cancel()
            scheduledFlush = nil
            // A migration marker and its imported rows must never be separated.
            // Commit the complete pending batch before deleting the requested
            // cache tables; a successful clear then prevents legacy re-import.
            switch drainPendingLocked() {
            case .failure(let error):
                scheduleRetryLocked()
                return .failure(error)
            case .success:
                break
            }

            do {
                var removedEntryCount = 0
                try database.transaction { connection in
                    for kind in kinds {
                        removedEntryCount += Int(
                            try connection.scalarInt(
                                "SELECT COUNT(*) FROM \(kind.tableName)"
                            ) ?? 0
                        )
                        try connection.execute("DELETE FROM \(kind.tableName)")
                    }
                }
                for kind in kinds {
                    generations[kind, default: 0] &+= 1
                }
                return .success(
                    ClearReport(
                        removedEntryCount: removedEntryCount,
                        clearedKinds: kinds
                    )
                )
            } catch {
                return .failure(.databaseFailure(error.localizedDescription))
            }
        }
    }
}
