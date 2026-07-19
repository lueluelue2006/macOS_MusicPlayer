import Foundation
import XCTest
@testable import MusicPlayer

final class PersistenceDatabaseTests: XCTestCase {
    private enum TestFailure: Error {
        case expected
    }

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicPlayer-SQLite-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testRoundTripsAllBoundValueTypesAndCopiedRows() throws {
        let database = try makeDatabase()
        defer { database.close() }

        let embeddedNUL = "左\0右"
        try database.execute(
            "INSERT INTO records(id, integer_value, real_value, text_value, blob_value, optional_value) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [
                .integer(1),
                .integer(42),
                .real(3.25),
                .text(embeddedNUL),
                .blob(Data()),
                .null
            ]
        )

        let rows = try database.query("SELECT * FROM records WHERE id = 1") { $0 }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.int64(at: try XCTUnwrap(row.columnIndex(named: "integer_value"))), 42)
        XCTAssertEqual(row.double(at: try XCTUnwrap(row.columnIndex(named: "real_value"))), 3.25)
        XCTAssertEqual(row.string(at: try XCTUnwrap(row.columnIndex(named: "text_value"))), embeddedNUL)
        XCTAssertEqual(row.data(at: try XCTUnwrap(row.columnIndex(named: "blob_value"))), Data())
        XCTAssertEqual(row.value(at: try XCTUnwrap(row.columnIndex(named: "optional_value"))), .null)
    }

    func testTransactionCommitsAndRollbackRestoresAutocommit() throws {
        let database = try makeDatabase()
        defer { database.close() }

        try database.transaction { connection in
            try connection.execute(
                "INSERT INTO records(id, integer_value) VALUES (?, ?)",
                bindings: [.integer(1), .integer(10)]
            )
        }
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM records"), 1)

        XCTAssertThrowsError(
            try database.transaction { connection in
                try connection.execute(
                    "INSERT INTO records(id, integer_value) VALUES (?, ?)",
                    bindings: [.integer(2), .integer(20)]
                )
                throw TestFailure.expected
            }
        )
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM records"), 1)

        try database.transaction { connection in
            try connection.execute(
                "INSERT INTO records(id, integer_value) VALUES (?, ?)",
                bindings: [.integer(3), .integer(30)]
            )
        }
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM records"), 2)
    }

    func testReadTransactionHoldsOneSnapshotAcrossStatements() throws {
        let url = databaseURL()
        let reader = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        defer { reader.close() }
        try reader.execute(
            "INSERT INTO records(id, integer_value) VALUES(1, 10)"
        )
        let writer = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        defer { writer.close() }

        let values = try reader.readTransaction { connection -> [Int64?] in
            let first = try connection.scalarInt(
                "SELECT integer_value FROM records WHERE id = 1"
            )
            try writer.execute("UPDATE records SET integer_value = 20 WHERE id = 1")
            let second = try connection.scalarInt(
                "SELECT integer_value FROM records WHERE id = 1"
            )
            return [first, second]
        }

        XCTAssertEqual(values.compactMap { $0 }, [10, 10])
        XCTAssertEqual(
            try reader.scalarInt("SELECT integer_value FROM records WHERE id = 1"),
            20
        )
    }

    func testStreamingRowsStopsEarlyWithoutMaterializingRemainingRows() throws {
        let database = try makeDatabase()
        defer { database.close() }

        var values: [Int64] = []
        let visited = try database.forEachRow(
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < ?
            )
            SELECT value FROM sequence
            """,
            bindings: [.integer(100_000)]
        ) { row in
            values.append(row.int64(at: 0) ?? -1)
            return values.count < 3
        }

        XCTAssertEqual(visited, 3)
        XCTAssertEqual(values, [1, 2, 3])
    }

    func testStreamingBodyErrorFinalizesStatementAndKeepsConnectionUsable() throws {
        let database = try makeDatabase()
        defer { database.close() }

        var visited = 0
        XCTAssertThrowsError(
            try database.forEachRow(
                "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3"
            ) { _ in
                visited += 1
                if visited == 2 { throw TestFailure.expected }
                return true
            }
        ) { error in
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertEqual(visited, 2)

        try database.execute(
            "INSERT INTO records(id, integer_value) VALUES (?, ?)",
            bindings: [.integer(1), .integer(42)]
        )
        XCTAssertEqual(try database.scalarInt("SELECT integer_value FROM records WHERE id = 1"), 42)
    }

    func testStreamingLargeResultSetKeepsOnlyCallerState() throws {
        let database = try makeDatabase()
        defer { database.close() }

        var sum: Int64 = 0
        let visited = try database.forEachRow(
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 50000
            )
            SELECT value FROM sequence
            """
        ) { row in
            sum += row.int64(at: 0) ?? 0
            return true
        }

        XCTAssertEqual(visited, 50_000)
        XCTAssertEqual(sum, 1_250_025_000)
    }

    func testConfigurationSupportsDeleteAndWALJournalModes() throws {
        let url = databaseURL()
        var deleteConfiguration = SQLiteConfiguration.production
        deleteConfiguration.journalMode = .delete
        let deleteDatabase = try SQLiteDatabase(
            fileURL: url,
            schema: schema(version: 1),
            configuration: deleteConfiguration
        )
        XCTAssertEqual(try journalMode(of: deleteDatabase), "delete")
        deleteDatabase.close()

        var walConfiguration = SQLiteConfiguration.production
        walConfiguration.journalMode = .wal
        let walDatabase = try SQLiteDatabase(
            fileURL: url,
            schema: schema(version: 1),
            configuration: walConfiguration
        )
        defer { walDatabase.close() }
        XCTAssertEqual(try journalMode(of: walDatabase), "wal")
    }

    func testQuickAndFullIntegrityChecksReportHealthyDatabase() throws {
        let database = try makeDatabase()
        defer { database.close() }

        try database.execute(
            "INSERT INTO records(id, integer_value) VALUES (?, ?)",
            bindings: [.integer(1), .integer(42)]
        )

        let quick = try database.integrityCheck(.quick, maximumErrors: 1)
        XCTAssertEqual(quick.mode, .quick)
        XCTAssertEqual(quick.messages, ["ok"])
        XCTAssertTrue(quick.isHealthy)

        let full = try database.integrityCheck(.full, maximumErrors: 1)
        XCTAssertEqual(full.mode, .full)
        XCTAssertEqual(full.messages, ["ok"])
        XCTAssertTrue(full.isHealthy)
    }

    func testMigrationIsAtomicAndIdempotent() throws {
        let url = databaseURL()
        let database = try SQLiteDatabase(fileURL: url, schema: schema(version: 2))
        XCTAssertEqual(try database.userVersion(), 2)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM records"), 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM migration_marker"), 1)
        database.close()

        let reopened = try SQLiteDatabase(fileURL: url, schema: schema(version: 2))
        defer { reopened.close() }
        XCTAssertEqual(try reopened.userVersion(), 2)
        XCTAssertEqual(try reopened.scalarInt("SELECT COUNT(*) FROM migration_marker"), 1)
    }

    func testFailedMigrationRollsBackDDLDataVersionAndApplicationID() throws {
        let url = databaseURL()
        let failingSchema = SQLiteSchema(
            applicationID: testApplicationID,
            version: 1,
            migrations: [
                SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                    try connection.execute("CREATE TABLE should_not_exist(id INTEGER PRIMARY KEY)")
                    try connection.execute("INSERT INTO should_not_exist(id) VALUES (1)")
                    throw TestFailure.expected
                }
            ]
        )

        XCTAssertThrowsError(try SQLiteDatabase(fileURL: url, schema: failingSchema))

        let inspection = try SQLiteDatabase(fileURL: url)
        defer { inspection.close() }
        XCTAssertEqual(try inspection.userVersion(), 0)
        XCTAssertEqual(try inspection.scalarInt("PRAGMA application_id"), 0)
        XCTAssertEqual(
            try inspection.scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'should_not_exist'"
            ),
            0
        )
        inspection.close()

        let retried = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        defer { retried.close() }
        XCTAssertEqual(retried.accessMode, .writable)
        XCTAssertEqual(try retried.userVersion(), 1)
        XCTAssertEqual(try retried.scalarInt("PRAGMA application_id"), Int64(testApplicationID))
    }

    func testValidatedOpenRejectsForeignKeyViolation() throws {
        let url = databaseURL()
        let seed = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        try seed.execute("CREATE TABLE parents(id INTEGER PRIMARY KEY)")
        try seed.execute(
            """
            CREATE TABLE children(
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL REFERENCES parents(id)
            )
            """
        )
        try seed.execute("PRAGMA foreign_keys = OFF")
        try seed.execute("INSERT INTO children(id, parent_id) VALUES(1, 999)")
        try seed.checkpoint()
        seed.close()

        var configuration = SQLiteConfiguration.production
        configuration.validatesIntegrityOnOpen = true
        XCTAssertThrowsError(
            try SQLiteDatabase(
                fileURL: url,
                schema: schema(version: 1),
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .integrity)
        }
    }

    func testFutureSchemaReopensPhysicallyReadOnlyAndPreservesMainFileBytes() throws {
        let url = databaseURL()
        let current = try SQLiteDatabase(fileURL: url, schema: schema(version: 2))
        try current.execute(
            "INSERT INTO records(id, integer_value) VALUES (?, ?)",
            bindings: [.integer(1), .integer(10)]
        )
        try current.checkpoint()
        current.close()
        let before = try Data(contentsOf: url)

        let older = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        XCTAssertEqual(older.accessMode, .readOnlyFuture(schemaVersion: 2))
        XCTAssertEqual(try older.scalarInt("SELECT COUNT(*) FROM records"), 1)
        XCTAssertThrowsError(try older.execute("DELETE FROM records")) { error in
            XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .readOnly)
        }
        older.close()

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testForeignApplicationIDIsReadOnly() throws {
        let url = databaseURL()
        let first = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        first.close()

        let foreignSchema = SQLiteSchema(
            applicationID: testApplicationID + 1,
            version: 1,
            migrations: schema(version: 1).migrations
        )
        let foreign = try SQLiteDatabase(fileURL: url, schema: foreignSchema)
        defer { foreign.close() }
        XCTAssertEqual(foreign.accessMode, .readOnlyForeign(applicationID: testApplicationID))
        XCTAssertThrowsError(try foreign.execute("DELETE FROM records"))
    }

    func testRejectsMultipleStatementsAndNestedTransactions() throws {
        let database = try makeDatabase()
        defer { database.close() }

        XCTAssertThrowsError(
            try database.execute("CREATE TABLE first(id INTEGER); CREATE TABLE second(id INTEGER)")
        ) { error in
            XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .prepare)
        }

        XCTAssertThrowsError(
            try database.transaction { _ in
                try database.transaction { _ in () }
            }
        ) { error in
            XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .transaction)
        }
    }

    func testBusyTimeoutReturnsBoundedErrorWithoutHanging() throws {
        var configuration = SQLiteConfiguration.production
        configuration.busyTimeoutMilliseconds = 100
        let url = databaseURL()
        let first = try SQLiteDatabase(fileURL: url, schema: schema(version: 1), configuration: configuration)
        let second = try SQLiteDatabase(fileURL: url, schema: schema(version: 1), configuration: configuration)
        defer {
            second.close()
            first.close()
        }

        let start = ContinuousClock.now
        try first.transaction { connection in
            try connection.execute(
                "INSERT INTO records(id, integer_value) VALUES (?, ?)",
                bindings: [.integer(1), .integer(1)]
            )
            XCTAssertThrowsError(
                try second.execute(
                    "INSERT INTO records(id, integer_value) VALUES (?, ?)",
                    bindings: [.integer(2), .integer(2)]
                )
            ) { error in
                XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .busy)
            }
        }
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testDatabaseAndDirectoryUsePrivatePermissions() throws {
        let database = try makeDatabase()
        defer { database.close() }

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: tempDirectory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: database.fileURL.path)
        let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber).intValue
        let fileMode = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testRejectsSymbolicLinkInsidePrivateParentPath() throws {
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        let realParent = tempDirectory.appendingPathComponent("real-parent", isDirectory: true)
        let linkedParent = tempDirectory.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)

        let databaseURL = linkedParent
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("persistence.sqlite3")
        XCTAssertThrowsError(try SQLiteDatabase(fileURL: databaseURL, schema: schema(version: 1))) {
            XCTAssertEqual(($0 as? SQLitePersistenceError)?.kind, .open)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: realParent.appendingPathComponent("nested").path))
    }

    func testRejectsDatabaseSymbolicLinkAndHardLinkWithoutTouchingTargets() throws {
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = self.databaseURL()

        let symbolicTarget = tempDirectory.appendingPathComponent("symbolic-target")
        let symbolicBytes = Data("symbolic-target-sentinel".utf8)
        try symbolicBytes.write(to: symbolicTarget)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: symbolicTarget)
        XCTAssertThrowsError(try SQLiteDatabase(fileURL: databaseURL, schema: schema(version: 1))) {
            XCTAssertEqual(($0 as? SQLitePersistenceError)?.kind, .open)
        }
        XCTAssertEqual(try Data(contentsOf: symbolicTarget), symbolicBytes)

        try FileManager.default.removeItem(at: databaseURL)
        let hardLinkTarget = tempDirectory.appendingPathComponent("hard-link-target")
        let hardLinkBytes = Data("hard-link-target-sentinel".utf8)
        try hardLinkBytes.write(to: hardLinkTarget)
        try FileManager.default.linkItem(at: hardLinkTarget, to: databaseURL)
        XCTAssertThrowsError(try SQLiteDatabase(fileURL: databaseURL, schema: schema(version: 1))) {
            XCTAssertEqual(($0 as? SQLitePersistenceError)?.kind, .open)
        }
        XCTAssertEqual(try Data(contentsOf: hardLinkTarget), hardLinkBytes)
    }

    func testRejectsUnsafeWALAndSHMSidecarsWithoutFollowingThem() throws {
        let databaseURL = self.databaseURL()
        let database = try SQLiteDatabase(fileURL: databaseURL, schema: schema(version: 1))
        try database.checkpoint()
        database.close()

        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            try? FileManager.default.removeItem(at: sidecarURL)

            let symbolicTarget = tempDirectory.appendingPathComponent("symbolic-target\(suffix)")
            let symbolicBytes = Data("symbolic-sidecar-sentinel\(suffix)".utf8)
            try symbolicBytes.write(to: symbolicTarget)
            try FileManager.default.createSymbolicLink(at: sidecarURL, withDestinationURL: symbolicTarget)
            XCTAssertThrowsError(try SQLiteDatabase(fileURL: databaseURL, schema: schema(version: 1))) {
                XCTAssertEqual(($0 as? SQLitePersistenceError)?.kind, .open)
            }
            XCTAssertEqual(try Data(contentsOf: symbolicTarget), symbolicBytes)

            try FileManager.default.removeItem(at: sidecarURL)
            let hardLinkTarget = tempDirectory.appendingPathComponent("hard-link-target\(suffix)")
            let hardLinkBytes = Data("hard-link-sidecar-sentinel\(suffix)".utf8)
            try hardLinkBytes.write(to: hardLinkTarget)
            try FileManager.default.linkItem(at: hardLinkTarget, to: sidecarURL)
            XCTAssertThrowsError(try SQLiteDatabase(fileURL: databaseURL, schema: schema(version: 1))) {
                XCTAssertEqual(($0 as? SQLitePersistenceError)?.kind, .open)
            }
            XCTAssertEqual(try Data(contentsOf: hardLinkTarget), hardLinkBytes)
            try FileManager.default.removeItem(at: sidecarURL)
        }
    }

    func testExistingNonEmptyApplicationIDZeroDatabaseIsProtectedWithoutMigration() throws {
        let url = databaseURL()
        let seed = try SQLiteDatabase(fileURL: url)
        try seed.execute("CREATE TABLE foreign_records(value TEXT NOT NULL)")
        try seed.execute("INSERT INTO foreign_records(value) VALUES ('preserve-me')")
        try seed.checkpoint()
        seed.close()
        let before = try Data(contentsOf: url)

        let protected = try SQLiteDatabase(fileURL: url, schema: schema(version: 1))
        XCTAssertEqual(protected.accessMode, .readOnlyForeign(applicationID: 0))
        XCTAssertEqual(
            try protected.query("SELECT value FROM foreign_records") { $0.string(at: 0) },
            ["preserve-me"]
        )
        XCTAssertThrowsError(try protected.execute("DELETE FROM foreign_records")) {
            XCTAssertEqual(($0 as? SQLitePersistenceError)?.kind, .readOnly)
        }
        protected.close()

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAccessAfterCloseFailsDeterministically() throws {
        let database = try makeDatabase()
        database.close()
        XCTAssertThrowsError(try database.scalarInt("SELECT 1")) { error in
            XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .closed)
        }
        XCTAssertThrowsError(try database.execute("CREATE TABLE nope(id INTEGER)")) { error in
            XCTAssertEqual((error as? SQLitePersistenceError)?.kind, .closed)
        }
    }

    private let testApplicationID: Int32 = 0x4D50_5443

    private func makeDatabase() throws -> SQLiteDatabase {
        try SQLiteDatabase(fileURL: databaseURL(), schema: schema(version: 1))
    }

    private func databaseURL() -> URL {
        tempDirectory.appendingPathComponent("persistence.sqlite3", isDirectory: false)
    }

    private func journalMode(of database: SQLiteDatabase) throws -> String? {
        try database.query("PRAGMA journal_mode") { $0.string(at: 0) }.first ?? nil
    }

    private func schema(version: Int) -> SQLiteSchema {
        var migrations = [
            SQLiteMigration(fromVersion: 0, toVersion: 1) { connection in
                try connection.execute(
                    """
                    CREATE TABLE records(
                        id INTEGER PRIMARY KEY,
                        integer_value INTEGER,
                        real_value REAL,
                        text_value TEXT,
                        blob_value BLOB,
                        optional_value TEXT
                    )
                    """
                )
            }
        ]
        if version >= 2 {
            migrations.append(
                SQLiteMigration(fromVersion: 1, toVersion: 2) { connection in
                    try connection.execute("CREATE TABLE migration_marker(id INTEGER PRIMARY KEY)")
                    try connection.execute("INSERT INTO migration_marker(id) VALUES (1)")
                }
            )
        }
        return SQLiteSchema(
            applicationID: testApplicationID,
            version: version,
            migrations: migrations
        )
    }
}
