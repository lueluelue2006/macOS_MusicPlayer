import Foundation

enum ProtectedVolumeCacheReason: Equatable, Sendable {
    case futureLegacyJSON(version: Int)
    case unknownLegacyJSON
    case futureDatabase(version: Int)
    case foreignDatabase(applicationID: Int32)
}

enum VolumeCacheClearResult: Equatable, Sendable {
    case cleared(analysisCount: Int, failureCount: Int, removedProtectedLegacy: Bool)
    case requiresConfirmation(ProtectedVolumeCacheReason)
    case failed(String)
}

enum VolumeCacheFlushResult: Equatable, Sendable {
    case flushed
    case failed(String)
}

struct VolumeAnalysisStoreError: Error, Equatable, Sendable {
    let message: String
}

enum VolumeDatabaseMigrationPhase: Equatable, Sendable {
    case beforeCommit
    case afterCommitBeforeCleanup
}

struct StoredVolumeAnalysis: Equatable, Sendable {
    let pathKey: String
    let measurement: LoudnessMeasurement
    let fileSize: Int64
    let modificationTimeNanoseconds: Int64
    let fileIdentifier: UInt64?
    let updatedAt: TimeInterval
    let lastUsedAt: TimeInterval

    func matches(_ snapshot: FileValidationSnapshot) -> Bool {
        snapshot.exists
            && fileSize == snapshot.fileSize
            && modificationTimeNanoseconds == snapshot.mtimeNs
            && fileIdentifier == snapshot.inode.map { UInt64(bitPattern: $0) }
            && measurement.usesCurrentAlgorithm
    }
}

/// Incremental, SQLite-backed persistence for volume-normalization analysis.
///
/// All database and hot-cache access is serialized on one utility queue. Audio
/// decoding remains in AudioPlayer's single normalization lane; this store never
/// loads PCM data or performs work on an audio render callback.
final class VolumeAnalysisStore: @unchecked Sendable {
    private struct HotEntry {
        var analysis: StoredVolumeAnalysis
        var accessSequence: UInt64
    }

    private struct LegacyVersionProbe: Decodable {
        let version: Int?
    }

    private struct LegacyV4File: Decodable {
        let version: Int
        let entriesByPath: [String: LegacyV4Entry]
    }

    private struct LegacyV4Entry: Decodable {
        let integratedLoudnessLUFS: Float?
        let truePeakDbTP: Float?
        let estimatedTruePeakDbTP: Float?
        let samplePeakDbFS: Float
        let estimatedTruePeakSource: EstimatedTruePeakSource?
        let analyzedFrameCount: Int64
        let sampleRate: Double
        let algorithmIdentifier: String?
        let algorithmVersion: Int
        let fileSize: Int64?
        let modificationTimeNanoseconds: Int64?
        let fileIdentifier: UInt64?
        let updatedAt: TimeInterval
        let lastUsedAt: TimeInterval?
    }

    private enum LegacyImportState: Equatable {
        case notInspected
        case absent
        case imported
        case invalidated(version: Int)
        case protectedCache(ProtectedVolumeCacheReason)

        var encoded: String {
            switch self {
            case .notInspected: return "not-inspected"
            case .absent: return "absent"
            case .imported: return "imported"
            case .invalidated(let version): return "invalidated:\(version)"
            case .protectedCache(.futureLegacyJSON(let version)): return "future-json:\(version)"
            case .protectedCache(.unknownLegacyJSON): return "unknown-json"
            case .protectedCache(.futureDatabase(let version)): return "future-db:\(version)"
            case .protectedCache(.foreignDatabase(let applicationID)): return "foreign-db:\(applicationID)"
            }
        }

        init(encoded: String) {
            if encoded == "absent" { self = .absent; return }
            if encoded == "imported" { self = .imported; return }
            if encoded == "unknown-json" {
                self = .protectedCache(.unknownLegacyJSON)
                return
            }
            if encoded.hasPrefix("invalidated:"),
               let version = Int(encoded.dropFirst("invalidated:".count)) {
                self = .invalidated(version: version)
                return
            }
            if encoded.hasPrefix("future-json:"),
               let version = Int(encoded.dropFirst("future-json:".count)) {
                self = .protectedCache(.futureLegacyJSON(version: version))
                return
            }
            self = .notInspected
        }
    }

    private static let applicationID: Int32 = 0x4D50_564C // "MPVL"
    private static let schemaVersion = 1
    private static let maximumLegacyJSONBytes = 16 * 1_024 * 1_024
    private static let legacyMetadataKey = "legacy_json_state"
    private static let legacyDatabaseMetadataKey = "legacy_application_support_database_v1"
    private static let lastUsedWriteInterval: TimeInterval = 24 * 60 * 60

    private let queue = DispatchQueue(label: "audio.volume-analysis.store", qos: .utility)
    private let databaseURL: URL
    private let legacyDatabaseURL: URL?
    private let legacyJSONURL: URL?
    private let analysisCapacity: Int
    private let failureCapacity: Int
    private let hotCacheCapacity: Int
    private let now: @Sendable () -> TimeInterval
    private let databaseMigrationHook: (@Sendable (VolumeDatabaseMigrationPhase) throws -> Void)?
    private var database: SQLiteDatabase
    private var hotEntries: [String: HotEntry] = [:]
    private var accessSequence: UInt64 = 0
    private var legacyImportState: LegacyImportState = .notInspected
    private var legacyDatabaseProtectionReason: ProtectedVolumeCacheReason?

    init(
        databaseURL: URL,
        legacyJSONURL: URL? = nil,
        analysisCapacity: Int = 20_000,
        failureCapacity: Int = 5_000,
        hotCacheCapacity: Int = 256,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        legacyDatabaseURL: URL? = nil,
        persistenceEnvironment: PersistenceEnvironment? = nil,
        databaseMigrationHook: (@Sendable (VolumeDatabaseMigrationPhase) throws -> Void)? = nil
    ) throws {
        let locations = try Self.resolveDatabaseLocations(
            requestedDatabaseURL: databaseURL,
            explicitLegacyDatabaseURL: legacyDatabaseURL,
            persistenceEnvironment: persistenceEnvironment
        )
        self.databaseURL = locations.active
        self.legacyDatabaseURL = locations.legacy
        self.legacyJSONURL = legacyJSONURL
        self.analysisCapacity = max(1, analysisCapacity)
        self.failureCapacity = max(1, failureCapacity)
        self.hotCacheCapacity = max(1, hotCacheCapacity)
        self.now = now
        self.databaseMigrationHook = databaseMigrationHook

        database = try Self.openRebuildingDerivedDatabase(at: locations.active)
        switch database.accessMode {
        case .writable:
            migrateLegacyDatabaseIfNeededLocked()
            legacyImportState = loadLegacyImportStateLocked()
            // Re-probe the bounded legacy file on every launch. A cache may be
            // restored or removed outside the app after a prior metadata marker;
            // a marker alone must not hide new data or keep a stale protection trap.
            queue.async { [weak self] in
                self?.inspectAndImportLegacyJSONLocked()
            }
        case .readOnlyFuture(let version):
            legacyImportState = .protectedCache(.futureDatabase(version: version))
        case .readOnlyForeign(let applicationID):
            legacyImportState = .protectedCache(.foreignDatabase(applicationID: applicationID))
        }
    }

    deinit { database.close() }

    var protectedCacheReason: ProtectedVolumeCacheReason? {
        queue.sync {
            protectedCacheReasonLocked()
        }
    }

    var analysisCount: Int {
        queue.sync {
            Int((try? database.scalarInt("SELECT COUNT(*) FROM analyses")) ?? 0)
        }
    }

    func measurement(for url: URL) -> LoudnessMeasurement? {
        let pathKey = PathKey.canonical(for: url)
        let snapshot = FileValidationSnapshot.load(for: url)
        return queue.sync {
            guard snapshot.exists else {
                removeAnalysisLocked(pathKey: pathKey)
                return nil
            }
            accessSequence &+= 1
            if var hot = hotEntries[pathKey] {
                guard hot.analysis.matches(snapshot) else {
                    hotEntries.removeValue(forKey: pathKey)
                    removeAnalysisLocked(pathKey: pathKey)
                    return nil
                }
                hot.accessSequence = accessSequence
                hotEntries[pathKey] = hot
                touchAnalysisIfNeededLocked(hot.analysis)
                return hot.analysis.measurement
            }

            guard let analysis = fetchAnalysisLocked(pathKey: pathKey) else { return nil }
            guard analysis.matches(snapshot) else {
                removeAnalysisLocked(pathKey: pathKey)
                return nil
            }
            cacheHotLocked(analysis)
            touchAnalysisIfNeededLocked(analysis)
            return analysis.measurement
        }
    }

    @discardableResult
    func save(
        measurement: LoudnessMeasurement,
        for url: URL,
        snapshot: FileValidationSnapshot
    ) -> Result<Int, VolumeAnalysisStoreError> {
        let pathKey = PathKey.canonical(for: url)
        guard snapshot.exists,
              measurement.usesCurrentAlgorithm,
              measurement.integratedLoudnessLUFS?.isFinite != false,
              measurement.estimatedTruePeakDbTP.isFinite,
              measurement.samplePeakDbFS.isFinite,
              measurement.analyzedFrameCount > 0,
              measurement.sampleRate.isFinite,
              measurement.sampleRate > 0 else {
            return .failure(VolumeAnalysisStoreError(message: "文件签名或响度算法无效"))
        }
        return queue.sync {
            let timestamp = now()
            let fileIdentifier = snapshot.inode.map { UInt64(bitPattern: $0) }
            do {
                try database.transaction { connection in
                    try connection.execute(
                        Self.analysisUpsertSQL,
                        bindings: Self.analysisBindings(
                            pathKey: pathKey,
                            measurement: measurement,
                            snapshot: snapshot,
                            updatedAt: timestamp,
                            lastUsedAt: timestamp
                        )
                    )
                    try connection.execute(
                        "DELETE FROM failures WHERE path_key = ?",
                        bindings: [.text(pathKey)]
                    )
                    try Self.enforceAnalysisCapacity(
                        connection: connection,
                        capacity: analysisCapacity
                    )
                }
                let stored = StoredVolumeAnalysis(
                    pathKey: pathKey,
                    measurement: measurement,
                    fileSize: snapshot.fileSize,
                    modificationTimeNanoseconds: snapshot.mtimeNs,
                    fileIdentifier: fileIdentifier,
                    updatedAt: timestamp,
                    lastUsedAt: timestamp
                )
                cacheHotLocked(stored)
                let count = Int(try database.scalarInt("SELECT COUNT(*) FROM analyses") ?? 0)
                if count >= analysisCapacity {
                    trimHotEntriesAgainstDatabaseLocked()
                }
                return .success(count)
            } catch {
                return .failure(VolumeAnalysisStoreError(message: "音量分析缓存写入失败"))
            }
        }
    }

    func validPathKeys<URLs: Sequence>(for urls: URLs) -> Set<String>
    where URLs.Element == URL {
        var snapshots: [String: FileValidationSnapshot] = [:]
        for url in urls {
            let pathKey = PathKey.canonical(for: url)
            if snapshots[pathKey] == nil {
                snapshots[pathKey] = FileValidationSnapshot.load(for: url)
            }
        }
        guard !snapshots.isEmpty else { return [] }

        return queue.sync {
            var valid = Set<String>()
            var invalid: [String] = []
            let allKeys = Array(snapshots.keys)
            for start in stride(from: 0, to: allKeys.count, by: 400) {
                let keyChunk = Array(allKeys[start..<min(start + 400, allKeys.count)])
                let placeholders = Array(
                    repeating: "?",
                    count: keyChunk.count
                ).joined(separator: ",")
                guard let analyses = try? database.query(
                    "SELECT * FROM analyses WHERE path_key IN (\(placeholders))",
                    bindings: keyChunk.map(SQLiteValue.text),
                    map: { Self.decodeAnalysisRow($0) }
                ) else { continue }
                for analysis in analyses {
                    guard let snapshot = snapshots[analysis.pathKey] else { continue }
                    if analysis.matches(snapshot) {
                        valid.insert(analysis.pathKey)
                    } else {
                        invalid.append(analysis.pathKey)
                    }
                }
            }
            removeAnalysesLocked(pathKeys: invalid)
            return valid
        }
    }

    func shouldRetryAnalysis(for url: URL) -> Bool {
        let pathKey = PathKey.canonical(for: url)
        let snapshot = FileValidationSnapshot.load(for: url)
        return queue.sync {
            guard snapshot.exists else { return false }
            guard let failure = fetchFailureLocked(pathKey: pathKey) else { return true }
            guard failure.matches(snapshot) else {
                try? database.execute(
                    "DELETE FROM failures WHERE path_key = ?",
                    bindings: [.text(pathKey)]
                )
                return true
            }
            return failure.retryAfter <= now()
        }
    }

    var nextRetryDate: Date? {
        queue.sync {
            do {
                let rows = try database.query(
                    "SELECT MIN(retry_after) FROM failures WHERE retry_after > ?",
                    bindings: [.real(now())]
                ) { $0.double(at: 0) }
                return (rows.first ?? nil).map { Date(timeIntervalSince1970: $0) }
            } catch {
                return nil
            }
        }
    }

    func recordFailure(
        _ error: LoudnessAnalysisError,
        for url: URL,
        snapshot: FileValidationSnapshot
    ) {
        guard error != .cancelled, snapshot.exists else { return }
        let pathKey = PathKey.canonical(for: url)
        queue.sync {
            let previous = fetchFailureLocked(pathKey: pathKey)
            let attempts = previous?.matches(snapshot) == true ? min(16, previous!.attempts + 1) : 1
            let delay = min(24 * 60 * 60, 15 * 60 * pow(2, Double(attempts - 1)))
            let timestamp = now()
            do {
                try database.transaction { connection in
                    try connection.execute(
                        Self.failureUpsertSQL,
                        bindings: [
                            .text(pathKey),
                            .integer(snapshot.fileSize),
                            .integer(snapshot.mtimeNs),
                            snapshot.inode.map(SQLiteValue.integer) ?? .null,
                            .text(Self.failureCode(error)),
                            .integer(Int64(attempts)),
                            .real(timestamp + delay),
                            .real(timestamp)
                        ]
                    )
                    try Self.enforceFailureCapacity(
                        connection: connection,
                        capacity: failureCapacity
                    )
                }
            } catch {
                // A failed derived-cache write must never make playback fail.
            }
        }
    }

    func clear(forceProtectedData: Bool = false) -> VolumeCacheClearResult {
        queue.sync {
            if let reason = protectedCacheReasonLocked(), !forceProtectedData {
                return .requiresConfirmation(reason)
            }

            let analyses = Int((try? database.scalarInt("SELECT COUNT(*) FROM analyses")) ?? 0)
            let failures = Int((try? database.scalarInt("SELECT COUNT(*) FROM failures")) ?? 0)
            var removedProtectedLegacy = false
            do {
                if database.accessMode != .writable {
                    guard forceProtectedData else {
                        return .requiresConfirmation(
                            protectedCacheReasonLocked()
                                ?? .unknownLegacyJSON
                        )
                    }
                    try replaceProtectedDatabaseLocked()
                }
                try database.transaction { connection in
                    try connection.execute("DELETE FROM analyses")
                    try connection.execute("DELETE FROM failures")
                }
                hotEntries.removeAll(keepingCapacity: true)
                if let legacyDatabaseURL,
                   legacyDatabaseURL.standardizedFileURL != databaseURL.standardizedFileURL,
                   Self.databaseFamilyExists(at: legacyDatabaseURL) {
                    try Self.removeDatabaseFamily(at: legacyDatabaseURL)
                    if forceProtectedData {
                        removedProtectedLegacy = true
                    }
                }
                legacyDatabaseProtectionReason = nil
                if forceProtectedData, let legacyJSONURL,
                   FileManager.default.fileExists(atPath: legacyJSONURL.path) {
                    try FileManager.default.removeItem(at: legacyJSONURL)
                    removedProtectedLegacy = true
                    legacyImportState = .absent
                    try persistLegacyImportStateLocked(.absent)
                }
                try database.checkpoint()
                return .cleared(
                    analysisCount: analyses,
                    failureCount: failures,
                    removedProtectedLegacy: removedProtectedLegacy
                )
            } catch {
                return .failed("音量分析缓存清除失败")
            }
        }
    }

    func flush() -> VolumeCacheFlushResult {
        queue.sync {
            guard database.accessMode == .writable else {
                return .failed("音量分析缓存处于只读保护，未执行落盘")
            }
            do {
                try database.checkpoint()
                return .flushed
            } catch {
                return .failed("音量分析缓存落盘失败")
            }
        }
    }

    private struct StoredFailure {
        let fileSize: Int64
        let modificationTimeNanoseconds: Int64
        let fileIdentifier: Int64?
        let attempts: Int
        let retryAfter: TimeInterval

        func matches(_ snapshot: FileValidationSnapshot) -> Bool {
            snapshot.exists
                && fileSize == snapshot.fileSize
                && modificationTimeNanoseconds == snapshot.mtimeNs
                && fileIdentifier == snapshot.inode
        }
    }

    private struct DatabaseLocations {
        let active: URL
        let legacy: URL?
    }

    private static func resolveDatabaseLocations(
        requestedDatabaseURL: URL,
        explicitLegacyDatabaseURL: URL?,
        persistenceEnvironment: PersistenceEnvironment?
    ) throws -> DatabaseLocations {
        let requested = requestedDatabaseURL.standardizedFileURL
        if let explicitLegacyDatabaseURL {
            let legacy = explicitLegacyDatabaseURL.standardizedFileURL
            return DatabaseLocations(
                active: requested,
                legacy: legacy == requested ? nil : legacy
            )
        }

        let environment: PersistenceEnvironment?
        if let persistenceEnvironment {
            environment = persistenceEnvironment
        } else {
            environment = try? PersistenceEnvironment.production()
        }
        guard let environment else {
            return DatabaseLocations(active: requested, legacy: nil)
        }

        let applicationSupport = environment.applicationSupportURL.standardizedFileURL
        let caches = environment.cachesURL.standardizedFileURL
        let parent = requested.deletingLastPathComponent().standardizedFileURL
        if parent == applicationSupport || parent == caches {
            _ = try environment.prepareCachesDirectory()
            let active = caches.appendingPathComponent(
                requested.lastPathComponent,
                isDirectory: false
            )
            let legacy = applicationSupport.appendingPathComponent(
                requested.lastPathComponent,
                isDirectory: false
            )
            return DatabaseLocations(
                active: active,
                legacy: active.standardizedFileURL == legacy.standardizedFileURL ? nil : legacy
            )
        }
        return DatabaseLocations(active: requested, legacy: nil)
    }

    private static func databaseConfiguration() -> SQLiteConfiguration {
        var configuration = SQLiteConfiguration.production
        configuration.pageCacheKiB = 512
        configuration.journalSizeLimitBytes = 1_048_576
        configuration.walAutoCheckpointPages = 128
        return configuration
    }

    private static func makeDatabase(at url: URL) throws -> SQLiteDatabase {
        try SQLiteDatabase(
            fileURL: url,
            schema: schema,
            configuration: databaseConfiguration()
        )
    }

    private static func openRebuildingDerivedDatabase(at url: URL) throws -> SQLiteDatabase {
        do {
            let opened = try makeDatabase(at: url)
            guard opened.accessMode == .writable else { return opened }
            do {
                let report = try opened.integrityCheck(.quick, maximumErrors: 1)
                guard !report.isHealthy else { return opened }
            } catch {
                opened.close()
                guard isDatabaseCorruption(error) else { throw error }
                try removeDatabaseFamily(at: url)
                return try makeDatabase(at: url)
            }
            opened.close()
            try removeDatabaseFamily(at: url)
            return try makeDatabase(at: url)
        } catch {
            guard isDatabaseCorruption(error) else { throw error }
            try removeDatabaseFamily(at: url)
            return try makeDatabase(at: url)
        }
    }

    private static func isDatabaseCorruption(_ error: Error) -> Bool {
        guard let sqlite = error as? SQLitePersistenceError else { return false }
        let detail = sqlite.detail.lowercased()
        return detail.contains("not a database")
            || detail.contains("malformed")
            || detail.contains("unsupported file format")
            || detail.contains("database disk image")
    }

    private static func databaseFamilyURLs(at databaseURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            databaseURL
        ]
    }

    private static func databaseFamilyExists(at databaseURL: URL) -> Bool {
        databaseFamilyURLs(at: databaseURL).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func removeDatabaseFamily(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        for url in databaseFamilyURLs(at: databaseURL) {
            do {
                try fileManager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
    }

    private func migrateLegacyDatabaseIfNeededLocked() {
        guard let legacyDatabaseURL,
              legacyDatabaseURL.standardizedFileURL != databaseURL.standardizedFileURL,
              Self.databaseFamilyExists(at: legacyDatabaseURL) else { return }

        guard FileManager.default.fileExists(atPath: legacyDatabaseURL.path) else {
            // A prior crash may leave only disposable WAL sidecars behind.
            try? Self.removeDatabaseFamily(at: legacyDatabaseURL)
            return
        }

        let source: SQLiteDatabase
        do {
            source = try Self.makeDatabase(at: legacyDatabaseURL)
        } catch {
            if Self.isDatabaseCorruption(error) {
                try? Self.removeDatabaseFamily(at: legacyDatabaseURL)
            }
            return
        }
        defer { source.close() }

        switch source.accessMode {
        case .readOnlyFuture(let version):
            legacyDatabaseProtectionReason = .futureDatabase(version: version)
            return
        case .readOnlyForeign(let applicationID):
            legacyDatabaseProtectionReason = .foreignDatabase(applicationID: applicationID)
            return
        case .writable:
            break
        }

        do {
            let integrity = try source.integrityCheck(.quick, maximumErrors: 1)
            guard integrity.isHealthy else {
                source.close()
                try? Self.removeDatabaseFamily(at: legacyDatabaseURL)
                return
            }

            try source.transaction(.deferred) { sourceConnection in
                try database.transaction { targetConnection in
                    try copyAnalyses(
                        from: sourceConnection,
                        to: targetConnection
                    )
                    try copyFailures(
                        from: sourceConnection,
                        to: targetConnection
                    )
                    try Self.enforceAnalysisCapacity(
                        connection: targetConnection,
                        capacity: analysisCapacity
                    )
                    try Self.enforceFailureCapacity(
                        connection: targetConnection,
                        capacity: failureCapacity
                    )
                    try targetConnection.execute(
                        """
                        INSERT INTO metadata(key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                        bindings: [
                            .text(Self.legacyDatabaseMetadataKey),
                            .text("complete")
                        ]
                    )
                    try databaseMigrationHook?(.beforeCommit)
                }
            }
            try database.checkpoint()
            try databaseMigrationHook?(.afterCommitBeforeCleanup)
            source.close()
            try Self.removeDatabaseFamily(at: legacyDatabaseURL)
            legacyDatabaseProtectionReason = nil
        } catch {
            source.close()
            if Self.isDatabaseCorruption(error) {
                try? Self.removeDatabaseFamily(at: legacyDatabaseURL)
            }
            // Transient and injected failures retain the source for an idempotent
            // retry. Proven corruption is disposable derived data, so it is
            // removed and rebuilt instead of trapping every future launch.
        }
    }

    private func copyAnalyses(
        from source: SQLiteConnection,
        to target: SQLiteConnection
    ) throws {
        try source.forEachRow("SELECT * FROM analyses") { row in
            let analysis = Self.decodeAnalysisRow(row)
            guard !analysis.pathKey.isEmpty,
                  analysis.pathKey.utf8.count <= 16 * 1_024,
                  analysis.measurement.usesCurrentAlgorithm,
                  analysis.measurement.integratedLoudnessLUFS?.isFinite != false,
                  analysis.measurement.estimatedTruePeakDbTP.isFinite,
                  analysis.measurement.samplePeakDbFS.isFinite,
                  analysis.measurement.analyzedFrameCount > 0,
                  analysis.measurement.sampleRate.isFinite,
                  analysis.measurement.sampleRate > 0,
                  analysis.fileSize >= 0,
                  analysis.updatedAt.isFinite,
                  analysis.lastUsedAt.isFinite else { return true }
            let snapshot = FileValidationSnapshot(
                exists: true,
                fileSize: analysis.fileSize,
                mtimeNs: analysis.modificationTimeNanoseconds,
                inode: analysis.fileIdentifier.map { Int64(bitPattern: $0) }
            )
            try target.execute(
                Self.analysisMigrationUpsertSQL,
                bindings: Self.analysisBindings(
                    pathKey: analysis.pathKey,
                    measurement: analysis.measurement,
                    snapshot: snapshot,
                    updatedAt: analysis.updatedAt,
                    lastUsedAt: analysis.lastUsedAt
                )
            )
            return true
        }
    }

    private func copyFailures(
        from source: SQLiteConnection,
        to target: SQLiteConnection
    ) throws {
        try source.forEachRow(
            "SELECT path_key, file_size, mtime_ns, file_identifier, failure_code, attempts, retry_after, updated_at FROM failures"
        ) { row in
            guard let pathKey = row.string(at: 0),
                  !pathKey.isEmpty,
                  pathKey.utf8.count <= 16 * 1_024,
                  let fileSize = row.int64(at: 1), fileSize >= 0,
                  let modificationTime = row.int64(at: 2),
                  let failureCode = row.string(at: 4), !failureCode.isEmpty,
                  let attempts = row.int64(at: 5), attempts > 0,
                  let retryAfter = row.double(at: 6), retryAfter.isFinite,
                  let updatedAt = row.double(at: 7), updatedAt.isFinite else { return true }
            try target.execute(
                Self.failureMigrationUpsertSQL,
                bindings: [
                    .text(pathKey),
                    .integer(fileSize),
                    .integer(modificationTime),
                    row.int64(at: 3).map(SQLiteValue.integer) ?? .null,
                    .text(failureCode),
                    .integer(attempts),
                    .real(retryAfter),
                    .real(updatedAt)
                ]
            )
            return true
        }
    }

    private static let schema = SQLiteSchema(
        applicationID: applicationID,
        version: schemaVersion,
        migrations: [
            SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                try connection.execute(
                    """
                    CREATE TABLE analyses(
                        path_key TEXT PRIMARY KEY NOT NULL,
                        algorithm_id TEXT NOT NULL,
                        algorithm_version INTEGER NOT NULL,
                        integrated_lufs REAL,
                        estimated_true_peak_dbtp REAL NOT NULL,
                        sample_peak_dbfs REAL NOT NULL,
                        peak_source INTEGER NOT NULL,
                        analyzed_frames INTEGER NOT NULL,
                        sample_rate REAL NOT NULL,
                        file_size INTEGER NOT NULL,
                        mtime_ns INTEGER NOT NULL,
                        file_identifier INTEGER,
                        updated_at REAL NOT NULL,
                        last_used_at REAL NOT NULL
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX analyses_lru ON analyses(last_used_at, updated_at, path_key)"
                )
                try connection.execute(
                    """
                    CREATE TABLE failures(
                        path_key TEXT PRIMARY KEY NOT NULL,
                        file_size INTEGER NOT NULL,
                        mtime_ns INTEGER NOT NULL,
                        file_identifier INTEGER,
                        failure_code TEXT NOT NULL,
                        attempts INTEGER NOT NULL,
                        retry_after REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX failures_retry ON failures(retry_after, updated_at, path_key)"
                )
                try connection.execute(
                    "CREATE TABLE metadata(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"
                )
            }
        ]
    )

    private static let analysisUpsertSQL = """
        INSERT INTO analyses(
            path_key, algorithm_id, algorithm_version, integrated_lufs,
            estimated_true_peak_dbtp, sample_peak_dbfs, peak_source,
            analyzed_frames, sample_rate, file_size, mtime_ns, file_identifier,
            updated_at, last_used_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path_key) DO UPDATE SET
            algorithm_id = excluded.algorithm_id,
            algorithm_version = excluded.algorithm_version,
            integrated_lufs = excluded.integrated_lufs,
            estimated_true_peak_dbtp = excluded.estimated_true_peak_dbtp,
            sample_peak_dbfs = excluded.sample_peak_dbfs,
            peak_source = excluded.peak_source,
            analyzed_frames = excluded.analyzed_frames,
            sample_rate = excluded.sample_rate,
            file_size = excluded.file_size,
            mtime_ns = excluded.mtime_ns,
            file_identifier = excluded.file_identifier,
            updated_at = excluded.updated_at,
            last_used_at = excluded.last_used_at
        """

    private static let analysisMigrationUpsertSQL = analysisUpsertSQL + """

        WHERE excluded.updated_at >= analyses.updated_at
        """

    private static let failureUpsertSQL = """
        INSERT INTO failures(
            path_key, file_size, mtime_ns, file_identifier, failure_code,
            attempts, retry_after, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path_key) DO UPDATE SET
            file_size = excluded.file_size,
            mtime_ns = excluded.mtime_ns,
            file_identifier = excluded.file_identifier,
            failure_code = excluded.failure_code,
            attempts = excluded.attempts,
            retry_after = excluded.retry_after,
            updated_at = excluded.updated_at
        """

    private static let failureMigrationUpsertSQL = failureUpsertSQL + """

        WHERE excluded.updated_at >= failures.updated_at
        """

    private static func analysisBindings(
        pathKey: String,
        measurement: LoudnessMeasurement,
        snapshot: FileValidationSnapshot,
        updatedAt: TimeInterval,
        lastUsedAt: TimeInterval
    ) -> [SQLiteValue] {
        [
            .text(pathKey),
            .text(measurement.algorithmIdentifier),
            .integer(Int64(measurement.algorithmVersion)),
            measurement.integratedLoudnessLUFS.map { .real(Double($0)) } ?? .null,
            .real(Double(measurement.estimatedTruePeakDbTP)),
            .real(Double(measurement.samplePeakDbFS)),
            .integer(Int64(measurement.estimatedTruePeakSource.rawValue)),
            .integer(measurement.analyzedFrameCount),
            .real(measurement.sampleRate),
            .integer(snapshot.fileSize),
            .integer(snapshot.mtimeNs),
            snapshot.inode.map(SQLiteValue.integer) ?? .null,
            .real(updatedAt),
            .real(lastUsedAt)
        ]
    }

    private static func enforceAnalysisCapacity(
        connection: SQLiteConnection,
        capacity: Int
    ) throws {
        try connection.execute(
            """
            DELETE FROM analyses
            WHERE path_key IN (
                SELECT path_key FROM analyses
                ORDER BY last_used_at ASC, updated_at ASC, path_key ASC
                LIMIT MAX(0, (SELECT COUNT(*) FROM analyses) - ?)
            )
            """,
            bindings: [.integer(Int64(capacity))]
        )
    }

    private static func enforceFailureCapacity(
        connection: SQLiteConnection,
        capacity: Int
    ) throws {
        try connection.execute(
            """
            DELETE FROM failures
            WHERE path_key IN (
                SELECT path_key FROM failures
                ORDER BY updated_at ASC, path_key ASC
                LIMIT MAX(0, (SELECT COUNT(*) FROM failures) - ?)
            )
            """,
            bindings: [.integer(Int64(capacity))]
        )
    }

    private func fetchAnalysisLocked(pathKey: String) -> StoredVolumeAnalysis? {
        do {
            return try database.query(
                "SELECT * FROM analyses WHERE path_key = ? LIMIT 1",
                bindings: [.text(pathKey)]
            ) { Self.decodeAnalysisRow($0, fallbackPathKey: pathKey) }.first
        } catch {
            return nil
        }
    }

    private static func decodeAnalysisRow(
        _ row: SQLiteRow,
        fallbackPathKey: String = ""
    ) -> StoredVolumeAnalysis {
        let algorithmID = row.string(at: 1) ?? ""
        let algorithmVersion = Int(row.int64(at: 2) ?? 0)
        let peakSource = EstimatedTruePeakSource(
            rawValue: Int(row.int64(at: 6) ?? 0)
        ) ?? .samplePeakFallback
        return StoredVolumeAnalysis(
            pathKey: row.string(at: 0) ?? fallbackPathKey,
            measurement: LoudnessMeasurement(
                integratedLoudnessLUFS: row.double(at: 3).map { Float($0) },
                estimatedTruePeakDbTP: Float(row.double(at: 4) ?? -.infinity),
                samplePeakDbFS: Float(row.double(at: 5) ?? -.infinity),
                estimatedTruePeakSource: peakSource,
                analyzedFrameCount: row.int64(at: 7) ?? 0,
                sampleRate: row.double(at: 8) ?? 0,
                algorithmIdentifier: algorithmID,
                algorithmVersion: algorithmVersion
            ),
            fileSize: row.int64(at: 9) ?? -1,
            modificationTimeNanoseconds: row.int64(at: 10) ?? 0,
            fileIdentifier: row.int64(at: 11).map { UInt64(bitPattern: $0) },
            updatedAt: row.double(at: 12) ?? 0,
            lastUsedAt: row.double(at: 13) ?? 0
        )
    }

    private func fetchFailureLocked(pathKey: String) -> StoredFailure? {
        try? database.query(
            "SELECT file_size, mtime_ns, file_identifier, attempts, retry_after FROM failures WHERE path_key = ? LIMIT 1",
            bindings: [.text(pathKey)]
        ) { row in
            StoredFailure(
                fileSize: row.int64(at: 0) ?? -1,
                modificationTimeNanoseconds: row.int64(at: 1) ?? 0,
                fileIdentifier: row.int64(at: 2),
                attempts: Int(row.int64(at: 3) ?? 0),
                retryAfter: row.double(at: 4) ?? 0
            )
        }.first
    }

    private func cacheHotLocked(_ analysis: StoredVolumeAnalysis) {
        accessSequence &+= 1
        hotEntries[analysis.pathKey] = HotEntry(
            analysis: analysis,
            accessSequence: accessSequence
        )
        while hotEntries.count > hotCacheCapacity,
              let oldest = hotEntries.min(by: { $0.value.accessSequence < $1.value.accessSequence }) {
            hotEntries.removeValue(forKey: oldest.key)
        }
    }

    private func touchAnalysisIfNeededLocked(_ analysis: StoredVolumeAnalysis) {
        let timestamp = now()
        guard timestamp - analysis.lastUsedAt >= Self.lastUsedWriteInterval else { return }
        try? database.execute(
            "UPDATE analyses SET last_used_at = ? WHERE path_key = ?",
            bindings: [.real(timestamp), .text(analysis.pathKey)]
        )
        if var hot = hotEntries[analysis.pathKey] {
            hot.analysis = StoredVolumeAnalysis(
                pathKey: analysis.pathKey,
                measurement: analysis.measurement,
                fileSize: analysis.fileSize,
                modificationTimeNanoseconds: analysis.modificationTimeNanoseconds,
                fileIdentifier: analysis.fileIdentifier,
                updatedAt: analysis.updatedAt,
                lastUsedAt: timestamp
            )
            hotEntries[analysis.pathKey] = hot
        }
    }

    private func removeAnalysisLocked(pathKey: String) {
        hotEntries.removeValue(forKey: pathKey)
        try? database.execute(
            "DELETE FROM analyses WHERE path_key = ?",
            bindings: [.text(pathKey)]
        )
    }

    private func removeAnalysesLocked(pathKeys: [String]) {
        guard !pathKeys.isEmpty else { return }
        for pathKey in pathKeys {
            hotEntries.removeValue(forKey: pathKey)
        }
        for start in stride(from: 0, to: pathKeys.count, by: 400) {
            let chunk = Array(pathKeys[start..<min(start + 400, pathKeys.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try? database.execute(
                "DELETE FROM analyses WHERE path_key IN (\(placeholders))",
                bindings: chunk.map(SQLiteValue.text)
            )
        }
    }

    private func trimHotEntriesAgainstDatabaseLocked() {
        guard !hotEntries.isEmpty else { return }
        let keys = Array(hotEntries.keys)
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        guard let persisted = try? database.query(
            "SELECT path_key FROM analyses WHERE path_key IN (\(placeholders))",
            bindings: keys.map(SQLiteValue.text),
            map: { $0.string(at: 0) }
        ) else { return }
        let persistedKeys = Set(persisted.compactMap { $0 })
        hotEntries = hotEntries.filter { persistedKeys.contains($0.key) }
    }

    private static func failureCode(_ error: LoudnessAnalysisError) -> String {
        switch error {
        case .cancelled: return "cancelled"
        case .unreadableFile: return "unreadable"
        case .emptyFile: return "empty"
        case .unsupportedFormat: return "unsupported-format"
        case .unsupportedChannelLayout: return "unsupported-layout"
        case .invalidSample: return "invalid-sample"
        case .decodeFailed: return "decode-failed"
        }
    }

    private func loadLegacyImportStateLocked() -> LegacyImportState {
        guard let rows = try? database.query(
            "SELECT value FROM metadata WHERE key = ? LIMIT 1",
            bindings: [.text(Self.legacyMetadataKey)],
            map: { $0.string(at: 0) }
        ), let value = rows.first ?? nil else {
            return .notInspected
        }
        return LegacyImportState(encoded: value)
    }

    private func persistLegacyImportStateLocked(_ state: LegacyImportState) throws {
        try database.execute(
            """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            bindings: [.text(Self.legacyMetadataKey), .text(state.encoded)]
        )
        legacyImportState = state
    }

    private func inspectAndImportLegacyJSONLocked() {
        guard let legacyJSONURL,
              FileManager.default.fileExists(atPath: legacyJSONURL.path) else {
            try? persistLegacyImportStateLocked(.absent)
            return
        }
        guard let data = try? DerivedCacheFileIO.readBoundedRegularFile(
                at: legacyJSONURL,
                maximumBytes: Self.maximumLegacyJSONBytes
              ),
              let probe = try? JSONDecoder().decode(LegacyVersionProbe.self, from: data),
              let version = probe.version else {
            try? persistLegacyImportStateLocked(.protectedCache(.unknownLegacyJSON))
            return
        }

        if version > 4 {
            try? persistLegacyImportStateLocked(
                .protectedCache(.futureLegacyJSON(version: version))
            )
            return
        }
        if version == 2 || version == 3 {
            do {
                try persistLegacyImportStateLocked(.invalidated(version: version))
                try? FileManager.default.removeItem(at: legacyJSONURL)
            } catch {
                // The original cache remains available if the migration marker fails.
            }
            return
        }
        guard version == 4,
              let decoded = try? JSONDecoder().decode(LegacyV4File.self, from: data) else {
            try? persistLegacyImportStateLocked(.protectedCache(.unknownLegacyJSON))
            return
        }

        do {
            try database.transaction { connection in
                for (rawPath, entry) in decoded.entriesByPath {
                    let peak = entry.estimatedTruePeakDbTP ?? entry.truePeakDbTP
                    guard entry.algorithmIdentifier == LoudnessAlgorithm.identifier,
                          entry.algorithmVersion == LoudnessAlgorithm.version,
                          let peak,
                          peak.isFinite,
                          entry.samplePeakDbFS.isFinite,
                          entry.analyzedFrameCount > 0,
                          entry.sampleRate.isFinite,
                          entry.sampleRate > 0,
                          let fileSize = entry.fileSize,
                          let mtimeNs = entry.modificationTimeNanoseconds else { continue }
                    let measurement = LoudnessMeasurement(
                        integratedLoudnessLUFS: entry.integratedLoudnessLUFS,
                        estimatedTruePeakDbTP: peak,
                        samplePeakDbFS: entry.samplePeakDbFS,
                        estimatedTruePeakSource: entry.estimatedTruePeakSource ?? .samplePeakFallback,
                        analyzedFrameCount: entry.analyzedFrameCount,
                        sampleRate: entry.sampleRate,
                        algorithmIdentifier: LoudnessAlgorithm.identifier,
                        algorithmVersion: LoudnessAlgorithm.version
                    )
                    let snapshot = FileValidationSnapshot(
                        exists: true,
                        fileSize: fileSize,
                        mtimeNs: mtimeNs,
                        inode: entry.fileIdentifier.map { Int64(bitPattern: $0) }
                    )
                    try connection.execute(
                        Self.analysisMigrationUpsertSQL,
                        bindings: Self.analysisBindings(
                            pathKey: PathKey.canonical(path: rawPath),
                            measurement: measurement,
                            snapshot: snapshot,
                            updatedAt: entry.updatedAt,
                            lastUsedAt: entry.lastUsedAt ?? entry.updatedAt
                        )
                    )
                }
                try connection.execute(
                    """
                    INSERT INTO metadata(key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    bindings: [.text(Self.legacyMetadataKey), .text(LegacyImportState.imported.encoded)]
                )
                try Self.enforceAnalysisCapacity(
                    connection: connection,
                    capacity: analysisCapacity
                )
            }
            legacyImportState = .imported
            try? FileManager.default.removeItem(at: legacyJSONURL)
        } catch {
            // Keep the JSON untouched so a later launch can retry atomically.
        }
    }

    private func protectedCacheReasonLocked() -> ProtectedVolumeCacheReason? {
        if let legacyDatabaseProtectionReason {
            return legacyDatabaseProtectionReason
        }
        switch database.accessMode {
        case .writable:
            if case .protectedCache(let reason) = legacyImportState { return reason }
            return nil
        case .readOnlyFuture(let version):
            return .futureDatabase(version: version)
        case .readOnlyForeign(let applicationID):
            return .foreignDatabase(applicationID: applicationID)
        }
    }

    private func replaceProtectedDatabaseLocked() throws {
        database.close()
        try Self.removeDatabaseFamily(at: databaseURL)
        database = try Self.makeDatabase(at: databaseURL)
        legacyImportState = .absent
        legacyDatabaseProtectionReason = nil
        try persistLegacyImportStateLocked(.absent)
    }
}
