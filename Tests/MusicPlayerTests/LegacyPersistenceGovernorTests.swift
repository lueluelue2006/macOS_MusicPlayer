import Darwin
import XCTest
@testable import MusicPlayer

final class LegacyPersistenceGovernorTests: XCTestCase {
    func testMovesOnlyRecognizedLegacyFilesAndLeavesUnknownFiles() throws {
        let root = try makeDirectory()
        try writeJSON([
            "formatID": "musicplayer.playback",
            "schemaVersion": 1,
            "payload": ["position": 0],
        ], to: root.appendingPathComponent("playback.json"))
        try Data().write(to: root.appendingPathComponent("user-playlists.json.sb-test"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("unknown-file.json"))

        let report = LegacyPersistenceGovernor(baseDirectory: root).run()

        XCTAssertEqual(
            Set(report.quarantined.map(\.relativePath)),
            ["playback.json", "user-playlists.json.sb-test"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("playback.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("unknown-file.json").path))
        let quarantine = root.appendingPathComponent("LegacyQuarantine", isDirectory: true)
        XCTAssertEqual(try posixMode(quarantine), 0o700)
        for item in report.quarantined {
            XCTAssertEqual(try posixMode(quarantine.appendingPathComponent(item.quarantineFileName)), 0o600)
        }
    }

    func testFutureAndCurrentVolumeCacheRemainWhileObsoleteVersionMoves() throws {
        let root = try makeDirectory()
        let volume = root.appendingPathComponent("volume-cache.json")
        let future = try JSONSerialization.data(withJSONObject: ["version": 99, "future": true])
        try future.write(to: volume)

        let futureReport = LegacyPersistenceGovernor(baseDirectory: root).run()
        XCTAssertTrue(futureReport.quarantined.isEmpty)
        XCTAssertEqual(try Data(contentsOf: volume), future)

        let current = try JSONSerialization.data(withJSONObject: ["version": 4, "entriesByPath": [:]])
        try current.write(to: volume)
        _ = LegacyPersistenceGovernor(baseDirectory: root).run()
        XCTAssertEqual(try Data(contentsOf: volume), current)

        try writeJSON(["version": 3, "entriesByPath": [:]], to: volume)
        let obsoleteReport = LegacyPersistenceGovernor(baseDirectory: root).run()
        XCTAssertEqual(obsoleteReport.quarantined.map(\.relativePath), ["volume-cache.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.path))
    }

    func testSymlinkAtKnownPathIsNeverFollowedOrMoved() throws {
        let root = try makeDirectory()
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("outside".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("state-writer.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let report = LegacyPersistenceGovernor(baseDirectory: root).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(
            report.skipped.first(where: { $0.relativePath == "state-writer.lock" })?.reason,
            .unsafeFile
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testSymlinkedCandidateAncestorIsNeverTraversed() throws {
        let root = try makeDirectory()
        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "outside-state-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let library = outside.appendingPathComponent("library-v1.json")
        let original = try JSONSerialization.data(withJSONObject: [
            "playback": [:],
            "playlists": [],
            "preferences": [:],
        ])
        try original.write(to: library)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("State", isDirectory: true),
            withDestinationURL: outside
        )

        let report = LegacyPersistenceGovernor(baseDirectory: root).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(
            report.skipped.first(where: { $0.relativePath == "State/library-v1.json" })?.reason,
            .unsafeFile
        )
        XCTAssertEqual(try Data(contentsOf: library), original)
    }

    func testSymlinkedBaseDirectoryIsRejectedWithoutTraversingTarget() throws {
        let target = try makeDirectory()
        let source = target.appendingPathComponent("state-writer.lock")
        let original = Data("outside-lock".utf8)
        try original.write(to: source)
        let link = target.deletingLastPathComponent().appendingPathComponent(
            "legacy-governor-base-link-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        let report = LegacyPersistenceGovernor(baseDirectory: link).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(report.skipped, [.init(relativePath: ".", reason: .unsafeFile)])
        XCTAssertEqual(try Data(contentsOf: source), original)
        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testSymlinkAboveBaseDirectoryIsRejectedComponentByComponent() throws {
        let targetParent = try makeDirectory()
        let targetBase = targetParent.appendingPathComponent("MusicPlayer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetBase,
            withIntermediateDirectories: false
        )
        let source = targetBase.appendingPathComponent("state-writer.lock")
        let original = Data("outside-lock".utf8)
        try original.write(to: source)
        let parentLink = targetParent.deletingLastPathComponent().appendingPathComponent(
            "legacy-governor-parent-link-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: targetParent)
        addTeardownBlock { try? FileManager.default.removeItem(at: parentLink) }

        let report = LegacyPersistenceGovernor(
            baseDirectory: parentLink.appendingPathComponent("MusicPlayer", isDirectory: true)
        ).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(report.skipped, [.init(relativePath: ".", reason: .unsafeFile)])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testQuarantineOutsideBaseIsRejectedWithoutTouchingEitherLocation() throws {
        let root = try makeDirectory()
        let source = root.appendingPathComponent("state-writer.lock")
        try Data("legacy-lock".utf8).write(to: source)
        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "outside-quarantine-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let report = LegacyPersistenceGovernor(
            baseDirectory: root,
            quarantineDirectory: outside
        ).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(
            report.skipped.first(where: { $0.relativePath == "state-writer.lock" })?.reason,
            .unsafeFile
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("legacy-lock".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSymlinkedQuarantineDirectoryIsRejectedAndOutsideTargetRemainsEmpty() throws {
        let root = try makeDirectory()
        let source = root.appendingPathComponent("state-writer.lock")
        try Data("legacy-lock".utf8).write(to: source)
        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "outside-quarantine-target-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("LegacyQuarantine", isDirectory: true),
            withDestinationURL: outside
        )

        let report = LegacyPersistenceGovernor(baseDirectory: root).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(
            report.skipped.first(where: { $0.relativePath == "state-writer.lock" })?.reason,
            .unsafeFile
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("legacy-lock".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testHardLinkedCandidateIsRejectedWithoutMovingEitherLink() throws {
        let root = try makeDirectory()
        let original = root.deletingLastPathComponent().appendingPathComponent(
            "outside-lock-\(UUID().uuidString)"
        )
        try Data("legacy-lock".utf8).write(to: original)
        addTeardownBlock { try? FileManager.default.removeItem(at: original) }
        let candidate = root.appendingPathComponent("state-writer.lock")
        XCTAssertEqual(link(original.path, candidate.path), 0)

        let report = LegacyPersistenceGovernor(baseDirectory: root).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(
            report.skipped.first(where: { $0.relativePath == "state-writer.lock" })?.reason,
            .unsafeFile
        )
        XCTAssertEqual(try Data(contentsOf: original), Data("legacy-lock".utf8))
        XCTAssertEqual(try Data(contentsOf: candidate), Data("legacy-lock".utf8))
    }

    func testOversizedKnownFileRemainsByteForByteInPlace() throws {
        let root = try makeDirectory()
        let source = root.appendingPathComponent("state-writer.lock")
        let original = Data(repeating: 0xA5, count: 4_097)
        try original.write(to: source)

        let report = LegacyPersistenceGovernor(baseDirectory: root).run()

        XCTAssertTrue(report.quarantined.isEmpty)
        XCTAssertEqual(
            report.skipped.first(where: { $0.relativePath == "state-writer.lock" })?.reason,
            .oversized
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDirectoryEnumerationAndReportHaveHardBounds() throws {
        let root = try makeDirectory()
        for index in 0..<520 {
            try Data().write(to: root.appendingPathComponent(
                "user-playlists.json.sb-\(String(format: "%04d", index))"
            ))
        }

        let report = LegacyPersistenceGovernor(
            baseDirectory: root,
            maximumQuarantineEntries: 1,
            maximumQuarantineBytes: 1_024
        ).run()

        XCTAssertEqual(report.quarantined.count + report.skipped.count, 256)
        XCTAssertGreaterThan(report.omittedItemCount, 0)
        XCTAssertTrue(report.skipped.contains {
            $0.relativePath == "." && $0.reason == .directoryEntryLimitReached
        })
        XCTAssertGreaterThan(
            try FileManager.default.contentsOfDirectory(atPath: root.path).count,
            1
        )
    }

    func testQuarantineCapacityStopsGrowthWithoutDeletingExistingItems() throws {
        let root = try makeDirectory()
        try Data().write(to: root.appendingPathComponent("state-writer.lock"))
        try Data().write(to: root.appendingPathComponent("user-playlists.json.sb-capacity"))
        let governor = LegacyPersistenceGovernor(
            baseDirectory: root,
            maximumQuarantineEntries: 1,
            maximumQuarantineBytes: 1_024
        )

        let report = governor.run()

        XCTAssertEqual(report.quarantined.count, 1)
        XCTAssertTrue(report.skipped.contains { $0.reason == .quarantineCapacityReached })
        let quarantine = root.appendingPathComponent("LegacyQuarantine", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 1)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "legacy-governor-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
