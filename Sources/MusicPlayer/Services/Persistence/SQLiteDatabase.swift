import Foundation
import SQLite3
import Darwin

enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLitePersistenceError: Error, Equatable, LocalizedError, Sendable {
    enum Kind: String, Equatable, Sendable {
        case open
        case closed
        case readOnly
        case foreignDatabase
        case prepare
        case bind
        case step
        case busy
        case transaction
        case rollback
        case migration
        case futureVersion
        case configuration
        case integrity
    }

    let kind: Kind
    let code: Int32
    let operation: String
    let detail: String

    var errorDescription: String? {
        "SQLite \(operation) failed (\(kind.rawValue), code \(code)): \(detail)"
    }
}

struct SQLiteConfiguration: Equatable, Sendable {
    enum Durability: String, Equatable, Sendable {
        case full = "FULL"
        case normal = "NORMAL"
    }

    enum JournalMode: String, Equatable, Sendable {
        case wal = "WAL"
        case delete = "DELETE"
    }

    var busyTimeoutMilliseconds = 1_500
    var pageCacheKiB = 2_048
    var journalSizeLimitBytes = 1_048_576
    var walAutoCheckpointPages = 256
    var durability: Durability = .normal
    var journalMode: JournalMode = .wal
    var keepsTemporaryTablesInMemory = false
    var secureFilePermissions = true
    /// Authoritative stores may opt into a bounded structural and foreign-key
    /// check before an existing writable database is reopened. Derived caches
    /// leave this disabled so startup never scans reconstructable data.
    var validatesIntegrityOnOpen = false

    static let production = SQLiteConfiguration()
}

struct SQLiteMigration {
    let fromVersion: Int
    let toVersion: Int
    let apply: (SQLiteConnection) throws -> Void

    init(
        fromVersion: Int,
        toVersion: Int,
        apply: @escaping (SQLiteConnection) throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.apply = apply
    }
}

struct SQLiteSchema {
    let applicationID: Int32
    let version: Int
    let migrations: [SQLiteMigration]

    init(applicationID: Int32, version: Int, migrations: [SQLiteMigration]) {
        self.applicationID = applicationID
        self.version = version
        self.migrations = migrations
    }

    static let unversioned = SQLiteSchema(applicationID: 0, version: 0, migrations: [])
}

enum SQLiteIntegrityCheckMode: Equatable, Sendable {
    case quick
    case full
}

struct SQLiteIntegrityCheckReport: Equatable, Sendable {
    let mode: SQLiteIntegrityCheckMode
    let messages: [String]

    var isHealthy: Bool {
        messages.count == 1 && messages[0].caseInsensitiveCompare("ok") == .orderedSame
    }
}

/// A copied SQLite row. Values remain valid after the prepared statement is finalized.
struct SQLiteRow: Equatable, Sendable {
    private let columns: [SQLiteValue]
    private let indexByName: [String: Int]

    fileprivate init(copying statement: OpaquePointer) {
        let count = Int(sqlite3_column_count(statement))
        var values: [SQLiteValue] = []
        var names: [String: Int] = [:]
        values.reserveCapacity(count)
        names.reserveCapacity(count)

        for index in 0..<count {
            let column = Int32(index)
            if let rawName = sqlite3_column_name(statement, column) {
                names[String(cString: rawName)] = index
            }
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(statement, column)))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(statement, column)))
            case SQLITE_TEXT:
                let byteCount = Int(sqlite3_column_bytes(statement, column))
                guard let bytes = sqlite3_column_text(statement, column) else {
                    values.append(.null)
                    continue
                }
                let buffer = UnsafeBufferPointer(start: bytes, count: max(0, byteCount))
                values.append(.text(String(decoding: buffer, as: UTF8.self)))
            case SQLITE_BLOB:
                let byteCount = Int(sqlite3_column_bytes(statement, column))
                guard byteCount > 0, let bytes = sqlite3_column_blob(statement, column) else {
                    values.append(.blob(Data()))
                    continue
                }
                values.append(.blob(Data(bytes: bytes, count: byteCount)))
            default:
                values.append(.null)
            }
        }

        columns = values
        indexByName = names
    }

    var columnCount: Int { columns.count }

    func columnIndex(named name: String) -> Int? { indexByName[name] }

    func value(at index: Int) -> SQLiteValue {
        guard columns.indices.contains(index) else { return .null }
        return columns[index]
    }

    func int64(at index: Int) -> Int64? {
        if case .integer(let value) = value(at: index) { return value }
        return nil
    }

    func double(at index: Int) -> Double? {
        switch value(at: index) {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    func string(at index: Int) -> String? {
        if case .text(let value) = value(at: index) { return value }
        return nil
    }

    func data(at index: Int) -> Data? {
        if case .blob(let value) = value(at: index) { return value }
        return nil
    }
}

struct SQLiteConnection {
    fileprivate let handle: OpaquePointer

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, operation: "prepare execute")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw makeSQLiteError(result, operation: "execute", handle: handle)
            }
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, operation: "prepare query")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                try output.append(map(SQLiteRow(copying: statement)))
            case SQLITE_DONE:
                return output
            default:
                throw makeSQLiteError(result, operation: "query", handle: handle)
            }
        }
    }

    /// Visits copied rows one at a time without first accumulating the result set.
    /// Return `true` to continue or `false` to stop immediately. The return value
    /// is the number of rows delivered to `body`, including the row that stopped
    /// iteration. A thrown body error is propagated after finalizing the statement.
    @discardableResult
    func forEachRow(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        _ body: (SQLiteRow) throws -> Bool
    ) throws -> Int {
        let statement = try prepare(sql, operation: "prepare streaming query")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var visitedRowCount = 0
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                visitedRowCount += 1
                guard try body(SQLiteRow(copying: statement)) else {
                    return visitedRowCount
                }
            case SQLITE_DONE:
                return visitedRowCount
            default:
                throw makeSQLiteError(result, operation: "streaming query", handle: handle)
            }
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64? {
        let values = try query(sql, bindings: bindings) { $0.int64(at: 0) }
        return values.first ?? nil
    }

    /// Number of rows affected by the most recently completed statement on this
    /// connection. Call while the owning database lock/transaction is held.
    func changes() -> Int64 {
        sqlite3_changes64(handle)
    }

    func userVersion() throws -> Int {
        Int(try scalarInt("PRAGMA user_version") ?? 0)
    }

    func applicationID() throws -> Int32 {
        Int32(clamping: try scalarInt("PRAGMA application_id") ?? 0)
    }

    fileprivate func setUserVersion(_ version: Int) throws {
        guard version >= 0 else {
            throw SQLitePersistenceError(
                kind: .migration,
                code: SQLITE_MISUSE,
                operation: "set user_version",
                detail: "Version must be non-negative"
            )
        }
        try execute("PRAGMA user_version = \(version)")
    }

    fileprivate func setApplicationID(_ applicationID: Int32) throws {
        guard applicationID >= 0 else {
            throw SQLitePersistenceError(
                kind: .configuration,
                code: SQLITE_MISUSE,
                operation: "set application_id",
                detail: "Application ID must be non-negative"
            )
        }
        try execute("PRAGMA application_id = \(applicationID)")
    }

    private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
        guard !sql.utf8.contains(0) else {
            throw SQLitePersistenceError(
                kind: .prepare,
                code: SQLITE_MISUSE,
                operation: operation,
                detail: "SQL contains an embedded NUL"
            )
        }

        var statement: OpaquePointer?
        var remainingSQL = ""
        let result: Int32 = sql.withCString { sqlPointer in
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(handle, sqlPointer, -1, &statement, &tail)
            if let tail {
                remainingSQL = String(cString: tail)
            }
            return result
        }
        guard result == SQLITE_OK, let statement else {
            throw makeSQLiteError(result, operation: operation, handle: handle)
        }

        guard remainingSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sqlite3_finalize(statement)
            throw SQLitePersistenceError(
                kind: .prepare,
                code: SQLITE_MISUSE,
                operation: operation,
                detail: "Only one SQL statement is allowed per call"
            )
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        guard Int(sqlite3_bind_parameter_count(statement)) == bindings.count else {
            throw SQLitePersistenceError(
                kind: .bind,
                code: SQLITE_RANGE,
                operation: "bind",
                detail: "Binding count does not match statement parameters"
            )
        }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .real(let real):
                result = sqlite3_bind_double(statement, index, real)
            case .text(let text):
                var utf8 = Array(text.utf8)
                utf8.append(0)
                result = utf8.withUnsafeBytes { buffer in
                    sqlite3_bind_text64(
                        statement,
                        index,
                        buffer.bindMemory(to: CChar.self).baseAddress,
                        UInt64(utf8.count - 1),
                        sqliteTransient,
                        UInt8(SQLITE_UTF8)
                    )
                }
            case .blob(let data) where data.isEmpty:
                result = sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(
                        statement,
                        index,
                        buffer.baseAddress,
                        UInt64(buffer.count),
                        sqliteTransient
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw makeSQLiteError(result, operation: "bind", handle: handle)
            }
        }
    }
}

final class SQLiteDatabase: @unchecked Sendable {
    enum TransactionMode: String, Sendable {
        case deferred = "DEFERRED"
        case immediate = "IMMEDIATE"
        case exclusive = "EXCLUSIVE"
    }

    enum AccessMode: Equatable, Sendable {
        case writable
        case readOnlyFuture(schemaVersion: Int)
        case readOnlyForeign(applicationID: Int32)
    }

    let fileURL: URL
    private(set) var accessMode: AccessMode

    private let configuration: SQLiteConfiguration
    private let databaseFileName: String
    private var parentDirectoryFileDescriptor: Int32?
    // Recursive only so a transaction closure that accidentally calls the public
    // transaction API can be rejected deterministically instead of deadlocking.
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var transactionIsActive = false

    init(
        fileURL: URL,
        schema: SQLiteSchema = .unversioned,
        configuration: SQLiteConfiguration = .production
    ) throws {
        guard schema.version >= 0, schema.applicationID >= 0 else {
            throw SQLitePersistenceError(
                kind: .configuration,
                code: SQLITE_MISUSE,
                operation: "validate schema",
                detail: "Schema version and application ID must be non-negative"
            )
        }

        let preparedDirectory = try Self.prepareParentDirectory(
            for: fileURL,
            secure: configuration.secureFilePermissions
        )
        let databaseFileName = fileURL.lastPathComponent
        let resolvedFileURL = preparedDirectory.url.appendingPathComponent(
            databaseFileName,
            isDirectory: false
        )
        let preparedFile: PreparedFile
        do {
            preparedFile = try Self.prepareDatabaseFile(
                in: preparedDirectory.fileDescriptor,
                name: databaseFileName,
                secure: configuration.secureFilePermissions
            )
            try Self.validateAuxiliaryFiles(
                in: preparedDirectory.fileDescriptor,
                databaseFileName: databaseFileName,
                secure: configuration.secureFilePermissions
            )
        } catch {
            Darwin.close(preparedDirectory.fileDescriptor)
            throw error
        }
        self.fileURL = resolvedFileURL
        self.configuration = configuration
        self.databaseFileName = databaseFileName
        parentDirectoryFileDescriptor = preparedDirectory.fileDescriptor
        accessMode = .writable

        do {
            if preparedFile.wasExistingAndNonEmpty {
                let inspectionHandle = try Self.openHandle(
                    at: resolvedFileURL,
                    flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
                    configuration: configuration
                )
                handle = inspectionHandle
                try applySecurePermissionsIfNeeded()

                let inspectionConnection = SQLiteConnection(handle: inspectionHandle)
                let diskApplicationID = try inspectionConnection.applicationID()
                let diskVersion = try inspectionConnection.userVersion()

                let mayInitializeUnmarkedDatabase: Bool
                if diskApplicationID == 0, diskVersion == 0 {
                    mayInitializeUnmarkedDatabase = try Self.hasNoUserSchemaObjects(
                        inspectionConnection
                    )
                } else {
                    mayInitializeUnmarkedDatabase = false
                }
                if schema.applicationID != 0,
                   diskApplicationID != schema.applicationID,
                   !mayInitializeUnmarkedDatabase {
                    accessMode = .readOnlyForeign(applicationID: diskApplicationID)
                    try inspectionConnection.execute("PRAGMA query_only = ON")
                    return
                }

                if diskVersion > schema.version {
                    accessMode = .readOnlyFuture(schemaVersion: diskVersion)
                    try inspectionConnection.execute("PRAGMA query_only = ON")
                    return
                }

                if configuration.validatesIntegrityOnOpen,
                   diskApplicationID == schema.applicationID {
                    try Self.validateExistingDatabase(inspectionConnection)
                }

                sqlite3_close_v2(inspectionHandle)
                handle = nil
                try Self.validateDatabaseFiles(
                    in: preparedDirectory.fileDescriptor,
                    databaseFileName: databaseFileName,
                    secure: configuration.secureFilePermissions
                )
            }

            let writableHandle = try Self.openHandle(
                at: resolvedFileURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
                configuration: configuration
            )
            handle = writableHandle
            try applySecurePermissionsIfNeeded()

            let connection = SQLiteConnection(handle: writableHandle)
            let diskApplicationID = try connection.applicationID()
            let diskVersion = try connection.userVersion()

            if diskApplicationID != 0,
               schema.applicationID != 0,
               diskApplicationID != schema.applicationID {
                sqlite3_close_v2(writableHandle)
                let readOnlyHandle = try Self.openHandle(
                    at: resolvedFileURL,
                    flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
                    configuration: configuration
                )
                handle = readOnlyHandle
                accessMode = .readOnlyForeign(applicationID: diskApplicationID)
                try SQLiteConnection(handle: readOnlyHandle).execute("PRAGMA query_only = ON")
                return
            }

            if diskVersion > schema.version {
                sqlite3_close_v2(writableHandle)
                let readOnlyHandle = try Self.openHandle(
                    at: resolvedFileURL,
                    flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
                    configuration: configuration
                )
                handle = readOnlyHandle
                accessMode = .readOnlyFuture(schemaVersion: diskVersion)
                try SQLiteConnection(handle: readOnlyHandle).execute("PRAGMA query_only = ON")
                return
            }

            try Self.configureWritableConnection(
                connection,
                configuration: configuration
            )
            try applySecurePermissionsIfNeeded()
            try migrateLocked(
                to: schema.version,
                applicationID: schema.applicationID,
                migrations: schema.migrations
            )
        } catch {
            if let handle {
                sqlite3_close_v2(handle)
                self.handle = nil
            }
            if let parentDirectoryFileDescriptor {
                Darwin.close(parentDirectoryFileDescriptor)
                self.parentDirectoryFileDescriptor = nil
            }
            throw error
        }
    }

    deinit { close() }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try withWritableConnection { try $0.execute(sql, bindings: bindings) }
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        try withConnection { try $0.query(sql, bindings: bindings, map: map) }
    }

    /// Streams copied rows through `body` without retaining an intermediate row
    /// array. Return `true` to continue or `false` to stop immediately.
    @discardableResult
    func forEachRow(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        _ body: (SQLiteRow) throws -> Bool
    ) throws -> Int {
        try withConnection {
            try $0.forEachRow(sql, bindings: bindings, body)
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64? {
        try withConnection { try $0.scalarInt(sql, bindings: bindings) }
    }

    func userVersion() throws -> Int {
        try withConnection { try $0.userVersion() }
    }

    /// Runs SQLite's bounded on-disk consistency check. `maximumErrors` is
    /// clamped so a damaged database cannot cause an unbounded diagnostic array.
    func integrityCheck(
        _ mode: SQLiteIntegrityCheckMode = .quick,
        maximumErrors: Int = 100
    ) throws -> SQLiteIntegrityCheckReport {
        let boundedMaximumErrors = min(max(1, maximumErrors), 1_000)
        let pragma: String
        switch mode {
        case .quick:
            pragma = "quick_check"
        case .full:
            pragma = "integrity_check"
        }

        var messages: [String] = []
        messages.reserveCapacity(min(boundedMaximumErrors, 16))
        try forEachRow("PRAGMA \(pragma)(\(boundedMaximumErrors))") { row in
            if let message = row.string(at: 0) {
                messages.append(message)
            }
            return messages.count < boundedMaximumErrors
        }
        return SQLiteIntegrityCheckReport(mode: mode, messages: messages)
    }

    @discardableResult
    func transaction<T>(
        _ mode: TransactionMode = .immediate,
        body: (SQLiteConnection) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let connection = try writableConnectionLocked(operation: "begin transaction")
        return try runTransactionLocked(connection, mode: mode, body: body)
    }

    /// Holds one SQLite read snapshot across every statement in `body`. Unlike
    /// the write transaction API, this remains available for future/foreign
    /// databases because BEGIN DEFERRED does not mutate their contents.
    @discardableResult
    func readTransaction<T>(
        body: (SQLiteConnection) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw closedError(operation: "begin read transaction") }
        return try runTransactionLocked(
            SQLiteConnection(handle: handle),
            mode: .deferred,
            body: body
        )
    }

    func checkpoint() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try writableConnectionLocked(operation: "checkpoint")
        guard let handle else { throw closedError(operation: "checkpoint") }

        try applySecurePermissionsIfNeeded()
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            handle,
            nil,
            SQLITE_CHECKPOINT_PASSIVE,
            &logFrames,
            &checkpointedFrames
        )
        guard result == SQLITE_OK else {
            throw makeSQLiteError(result, operation: "checkpoint", handle: handle)
        }
        try? applySecurePermissionsIfNeeded()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func migrateLocked(
        to targetVersion: Int,
        applicationID: Int32,
        migrations: [SQLiteMigration]
    ) throws {
        guard let handle else { throw closedError(operation: "migrate") }
        let connection = SQLiteConnection(handle: handle)
        let currentVersion = try connection.userVersion()
        let currentApplicationID = try connection.applicationID()
        guard currentVersion <= targetVersion else {
            throw SQLitePersistenceError(
                kind: .futureVersion,
                code: SQLITE_READONLY,
                operation: "migrate",
                detail: "Database schema \(currentVersion) is newer than supported \(targetVersion)"
            )
        }
        let shouldSetApplicationID = currentApplicationID == 0 && applicationID != 0
        guard currentVersion < targetVersion || shouldSetApplicationID else { return }

        var migrationsByStart: [Int: SQLiteMigration] = [:]
        for migration in migrations {
            guard migration.toVersion > migration.fromVersion,
                  migrationsByStart[migration.fromVersion] == nil else {
                throw SQLitePersistenceError(
                    kind: .migration,
                    code: SQLITE_MISUSE,
                    operation: "validate migrations",
                    detail: "Migration chain is invalid or ambiguous"
                )
            }
            migrationsByStart[migration.fromVersion] = migration
        }

        var planned: [SQLiteMigration] = []
        var cursor = currentVersion
        while cursor < targetVersion {
            guard let migration = migrationsByStart[cursor], migration.toVersion <= targetVersion else {
                throw SQLitePersistenceError(
                    kind: .migration,
                    code: SQLITE_NOTFOUND,
                    operation: "validate migrations",
                    detail: "No contiguous migration from schema \(cursor)"
                )
            }
            planned.append(migration)
            cursor = migration.toVersion
        }

        try runTransactionLocked(connection, mode: .immediate) { transaction in
            if shouldSetApplicationID {
                try transaction.setApplicationID(applicationID)
            }
            for migration in planned {
                try migration.apply(transaction)
                try transaction.setUserVersion(migration.toVersion)
            }
        }
    }

    private func runTransactionLocked<T>(
        _ connection: SQLiteConnection,
        mode: TransactionMode,
        body: (SQLiteConnection) throws -> T
    ) throws -> T {
        guard !transactionIsActive else {
            throw SQLitePersistenceError(
                kind: .transaction,
                code: SQLITE_MISUSE,
                operation: "begin transaction",
                detail: "Nested transactions are not supported"
            )
        }

        try connection.execute("BEGIN \(mode.rawValue) TRANSACTION")
        transactionIsActive = true
        do {
            let value = try body(connection)
            try connection.execute("COMMIT")
            transactionIsActive = false
            return value
        } catch {
            let originalError = error
            let rollbackResult = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            let autocommitRestored = handle.map { sqlite3_get_autocommit($0) != 0 } ?? false
            transactionIsActive = false
            guard rollbackResult == SQLITE_OK, autocommitRestored else {
                let rollbackCode = rollbackResult == SQLITE_OK ? SQLITE_ABORT : rollbackResult
                closeLocked()
                throw SQLitePersistenceError(
                    kind: .rollback,
                    code: rollbackCode,
                    operation: "rollback transaction",
                    detail: "The transaction failed and the connection could not be safely recovered: \(String(describing: originalError))"
                )
            }
            throw originalError
        }
    }

    private func withConnection<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw closedError(operation: "access") }
        return try body(SQLiteConnection(handle: handle))
    }

    private func withWritableConnection<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(try writableConnectionLocked(operation: "write"))
    }

    private func writableConnectionLocked(operation: String) throws -> SQLiteConnection {
        guard let handle else { throw closedError(operation: operation) }
        guard accessMode == .writable else {
            throw SQLitePersistenceError(
                kind: .readOnly,
                code: SQLITE_READONLY,
                operation: operation,
                detail: "Database is protected because its schema or application ID is not writable by this version"
            )
        }
        return SQLiteConnection(handle: handle)
    }

    private func closeLocked() {
        if let handle {
            if transactionIsActive {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                transactionIsActive = false
            }
            sqlite3_close_v2(handle)
            self.handle = nil
        }
        if let parentDirectoryFileDescriptor {
            Darwin.close(parentDirectoryFileDescriptor)
            self.parentDirectoryFileDescriptor = nil
        }
    }

    private func applySecurePermissionsIfNeeded() throws {
        guard configuration.secureFilePermissions else { return }
        guard let parentDirectoryFileDescriptor else {
            throw closedError(operation: "set file permissions")
        }
        try Self.validateDatabaseFiles(
            in: parentDirectoryFileDescriptor,
            databaseFileName: databaseFileName,
            secure: true
        )
    }

    private static func configureWritableConnection(
        _ connection: SQLiteConnection,
        configuration: SQLiteConfiguration
    ) throws {
        try connection.execute("PRAGMA foreign_keys = ON")
        let journalModeRows = try connection.query(
            "PRAGMA journal_mode = \(configuration.journalMode.rawValue)"
        ) { $0.string(at: 0) }
        let appliedJournalMode = journalModeRows.first ?? nil
        guard appliedJournalMode?.caseInsensitiveCompare(configuration.journalMode.rawValue)
                == .orderedSame else {
            throw SQLitePersistenceError(
                kind: .configuration,
                code: SQLITE_ERROR,
                operation: "configure journal mode",
                detail: "SQLite did not apply the requested journal mode"
            )
        }
        try connection.execute("PRAGMA synchronous = \(configuration.durability.rawValue)")
        try connection.execute(
            "PRAGMA temp_store = \(configuration.keepsTemporaryTablesInMemory ? "MEMORY" : "FILE")"
        )
        try connection.execute("PRAGMA cache_size = -\(max(256, configuration.pageCacheKiB))")
        try connection.execute("PRAGMA mmap_size = 0")
        try connection.execute("PRAGMA journal_size_limit = \(max(0, configuration.journalSizeLimitBytes))")
        try connection.execute(
            "PRAGMA wal_autocheckpoint = \(max(1, configuration.walAutoCheckpointPages))"
        )
    }

    private static func hasNoUserSchemaObjects(_ connection: SQLiteConnection) throws -> Bool {
        try connection.scalarInt(
            "SELECT COUNT(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"
        ) == 0
    }

    private static func validateExistingDatabase(_ connection: SQLiteConnection) throws {
        var quickCheckMessage: String?
        let quickCheckRows = try connection.forEachRow("PRAGMA quick_check(1)") { row in
            quickCheckMessage = row.string(at: 0)
            return false
        }
        guard quickCheckRows == 1, quickCheckMessage == "ok" else {
            throw SQLitePersistenceError(
                kind: .integrity,
                code: SQLITE_CORRUPT,
                operation: "quick check existing database",
                detail: quickCheckMessage ?? "Database returned no integrity result"
            )
        }

        var foreignKeyViolation: String?
        _ = try connection.forEachRow("PRAGMA foreign_key_check") { row in
            let table = row.string(at: 0) ?? "unknown"
            let rowID = row.int64(at: 1).map(String.init) ?? "unknown"
            foreignKeyViolation = "Foreign-key violation in \(table), rowid \(rowID)"
            return false
        }
        if let foreignKeyViolation {
            throw SQLitePersistenceError(
                kind: .integrity,
                code: SQLITE_CONSTRAINT,
                operation: "foreign key check existing database",
                detail: foreignKeyViolation
            )
        }
    }

    private static func openHandle(
        at fileURL: URL,
        flags: Int32,
        configuration: SQLiteConfiguration
    ) throws -> OpaquePointer {
        var openedHandle: OpaquePointer?
        let result = sqlite3_open_v2(fileURL.path, &openedHandle, flags, nil)
        guard result == SQLITE_OK, let openedHandle else {
            let detail = openedHandle.flatMap { String(cString: sqlite3_errmsg($0)) }
                ?? "Database could not be opened"
            if let openedHandle { sqlite3_close_v2(openedHandle) }
            throw SQLitePersistenceError(kind: .open, code: result, operation: "open", detail: detail)
        }
        sqlite3_extended_result_codes(openedHandle, 1)
        sqlite3_busy_timeout(openedHandle, Int32(max(0, configuration.busyTimeoutMilliseconds)))
        return openedHandle
    }

    private struct PreparedDirectory {
        let url: URL
        let fileDescriptor: Int32
    }

    private struct PreparedFile {
        let wasExistingAndNonEmpty: Bool
    }

    private static func prepareParentDirectory(for fileURL: URL, secure: Bool) throws -> PreparedDirectory {
        let standardizedURL = fileURL.standardizedFileURL
        let databaseFileName = standardizedURL.lastPathComponent
        guard standardizedURL.isFileURL,
              standardizedURL.path.hasPrefix("/"),
              !databaseFileName.isEmpty,
              databaseFileName != ".",
              databaseFileName != ".." else {
            throw pathError(operation: "validate database path", detail: "Database path is invalid")
        }

        var components = Array(standardizedURL.deletingLastPathComponent().pathComponents.dropFirst())
        var canonicalComponents: [String] = []
        var enteredPrivateOwnershipBoundary = false
        var symlinkResolutionCount = 0
        var directoryDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw pathError(operation: "open root directory", detail: "Database directory could not be opened")
        }

        var index = 0
        while index < components.count {
            let component = components[index]
            guard !component.isEmpty, component != ".", component != ".." else {
                Darwin.close(directoryDescriptor)
                throw pathError(operation: "validate database directory", detail: "Database directory is invalid")
            }

            var entryStatus = stat()
            let statusResult = component.withCString {
                fstatat(directoryDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
            }

            if statusResult == 0, fileType(entryStatus.st_mode) == S_IFLNK {
                guard !enteredPrivateOwnershipBoundary, entryStatus.st_uid == 0 else {
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "validate database directory",
                        detail: "Database directory contains an untrusted symbolic link"
                    )
                }

                symlinkResolutionCount += 1
                guard symlinkResolutionCount <= 8 else {
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "resolve database directory",
                        detail: "Database directory contains too many symbolic links"
                    )
                }

                let prefix = "/" + (canonicalComponents + [component]).joined(separator: "/")
                guard let resolvedPointer = realpath(prefix, nil) else {
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "resolve database directory",
                        detail: "Database directory symbolic link could not be resolved"
                    )
                }
                let resolvedPrefix = String(cString: resolvedPointer)
                free(resolvedPointer)
                let remaining = Array(components.dropFirst(index + 1))
                components = Array(URL(fileURLWithPath: resolvedPrefix).pathComponents.dropFirst()) + remaining
                canonicalComponents.removeAll(keepingCapacity: true)
                enteredPrivateOwnershipBoundary = false
                index = 0
                Darwin.close(directoryDescriptor)
                directoryDescriptor = Darwin.open(
                    "/",
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard directoryDescriptor >= 0 else {
                    throw pathError(
                        operation: "open root directory",
                        detail: "Database directory could not be opened"
                    )
                }
                continue
            }

            if statusResult != 0 {
                guard errno == ENOENT else {
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "inspect database directory",
                        detail: "Database directory could not be inspected"
                    )
                }
                let creationMode: mode_t = secure ? 0o700 : 0o755
                let createResult = component.withCString {
                    mkdirat(directoryDescriptor, $0, creationMode)
                }
                guard createResult == 0 || errno == EEXIST else {
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "create database directory",
                        detail: "Database directory could not be created"
                    )
                }
            }

            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(directoryDescriptor)
                throw pathError(
                    operation: "open database directory",
                    detail: "Database directory is not a trusted directory"
                )
            }

            var openedStatus = stat()
            guard fstat(nextDescriptor, &openedStatus) == 0,
                  fileType(openedStatus.st_mode) == S_IFDIR else {
                Darwin.close(nextDescriptor)
                Darwin.close(directoryDescriptor)
                throw pathError(
                    operation: "validate database directory",
                    detail: "Database parent path contains a non-directory entry"
                )
            }

            if secure {
                let effectiveUserID = geteuid()
                if enteredPrivateOwnershipBoundary, openedStatus.st_uid != effectiveUserID {
                    Darwin.close(nextDescriptor)
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "validate database directory owner",
                        detail: "Database directory ownership changes inside the private path"
                    )
                }
                if openedStatus.st_uid == effectiveUserID {
                    enteredPrivateOwnershipBoundary = true
                } else if openedStatus.st_uid != 0 {
                    Darwin.close(nextDescriptor)
                    Darwin.close(directoryDescriptor)
                    throw pathError(
                        operation: "validate database directory owner",
                        detail: "Database directory has an unexpected owner"
                    )
                }
            }

            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
            canonicalComponents.append(component)
            index += 1
        }

        var finalStatus = stat()
        guard fstat(directoryDescriptor, &finalStatus) == 0,
              fileType(finalStatus.st_mode) == S_IFDIR,
              !secure || finalStatus.st_uid == geteuid() else {
            Darwin.close(directoryDescriptor)
            throw pathError(
                operation: "validate database directory owner",
                detail: "Database parent directory is not private to the current user"
            )
        }
        if secure, fchmod(directoryDescriptor, 0o700) != 0 {
            Darwin.close(directoryDescriptor)
            throw pathError(
                operation: "secure database directory",
                detail: "Database directory permissions could not be secured"
            )
        }

        let canonicalPath = "/" + canonicalComponents.joined(separator: "/")
        return PreparedDirectory(
            url: URL(fileURLWithPath: canonicalPath, isDirectory: true),
            fileDescriptor: directoryDescriptor
        )
    }

    private static func prepareDatabaseFile(
        in directoryFileDescriptor: Int32,
        name: String,
        secure: Bool
    ) throws -> PreparedFile {
        var entryStatus = stat()
        let statusResult = name.withCString {
            fstatat(directoryFileDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0, errno != ENOENT {
            throw pathError(operation: "inspect database file", detail: "Database file could not be inspected")
        }

        let existed = statusResult == 0
        if existed {
            try validateRegularFileStatus(entryStatus, operation: "validate database file")
        }

        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (existed ? 0 : O_CREAT | O_EXCL)
        let descriptor = name.withCString {
            openat(directoryFileDescriptor, $0, flags, 0o600)
        }
        if descriptor < 0, !existed, errno == EEXIST {
            return try prepareDatabaseFile(
                in: directoryFileDescriptor,
                name: name,
                secure: secure
            )
        }
        guard descriptor >= 0 else {
            throw pathError(operation: "open database file", detail: "Database file could not be opened safely")
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw pathError(operation: "inspect database file", detail: "Database file could not be inspected")
        }
        try validateRegularFileStatus(openedStatus, operation: "validate database file")
        if secure, fchmod(descriptor, 0o600) != 0 {
            throw pathError(operation: "secure database file", detail: "Database file permissions could not be secured")
        }
        return PreparedFile(wasExistingAndNonEmpty: existed && openedStatus.st_size > 0)
    }

    private static func validateAuxiliaryFiles(
        in directoryFileDescriptor: Int32,
        databaseFileName: String,
        secure: Bool
    ) throws {
        for suffix in ["-wal", "-shm"] {
            try validateAndSecureFileIfPresent(
                in: directoryFileDescriptor,
                name: databaseFileName + suffix,
                secure: secure
            )
        }
    }

    private static func validateDatabaseFiles(
        in directoryFileDescriptor: Int32,
        databaseFileName: String,
        secure: Bool
    ) throws {
        try validateAndSecureFileIfPresent(
            in: directoryFileDescriptor,
            name: databaseFileName,
            secure: secure
        )
        try validateAuxiliaryFiles(
            in: directoryFileDescriptor,
            databaseFileName: databaseFileName,
            secure: secure
        )
    }

    private static func validateAndSecureFileIfPresent(
        in directoryFileDescriptor: Int32,
        name: String,
        secure: Bool
    ) throws {
        var entryStatus = stat()
        let statusResult = name.withCString {
            fstatat(directoryFileDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0 else {
            if errno == ENOENT { return }
            throw pathError(operation: "inspect database sidecar", detail: "Database file could not be inspected")
        }
        try validateRegularFileStatus(entryStatus, operation: "validate database sidecar")

        let descriptor = name.withCString {
            openat(directoryFileDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw pathError(operation: "open database sidecar", detail: "Database file could not be opened safely")
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw pathError(operation: "inspect database sidecar", detail: "Database file could not be inspected")
        }
        try validateRegularFileStatus(openedStatus, operation: "validate database sidecar")
        if secure, fchmod(descriptor, 0o600) != 0 {
            throw pathError(operation: "secure database sidecar", detail: "Database file permissions could not be secured")
        }
    }

    private static func validateRegularFileStatus(_ status: stat, operation: String) throws {
        guard fileType(status.st_mode) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw pathError(
                operation: operation,
                detail: "Database files must be owner-only regular files with a single link"
            )
        }
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & S_IFMT
    }

    private static func pathError(operation: String, detail: String) -> SQLitePersistenceError {
        SQLitePersistenceError(
            kind: .open,
            code: SQLITE_CANTOPEN,
            operation: operation,
            detail: detail
        )
    }

    private func closedError(operation: String) -> SQLitePersistenceError {
        SQLitePersistenceError(
            kind: .closed,
            code: SQLITE_MISUSE,
            operation: operation,
            detail: "Database connection is closed"
        )
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func makeSQLiteError(
    _ code: Int32,
    operation: String,
    handle: OpaquePointer?
) -> SQLitePersistenceError {
    let primaryCode = code & 0xFF
    let kind: SQLitePersistenceError.Kind
    switch primaryCode {
    case SQLITE_BUSY, SQLITE_LOCKED:
        kind = .busy
    case SQLITE_CANTOPEN:
        kind = .open
    case SQLITE_READONLY:
        kind = .readOnly
    case SQLITE_MISUSE:
        kind = .closed
    default:
        kind = operation.contains("prepare") ? .prepare : .step
    }
    let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    return SQLitePersistenceError(kind: kind, code: code, operation: operation, detail: detail)
}
