import Foundation
import XCTest
@testable import MusicPlayer

final class PersistenceEnvironmentTests: XCTestCase {
    func testInjectedEnvironmentPreservesValuesWithoutTouchingDisk() throws {
        try withTemporaryDirectory { root in
            let defaults = try makeDefaults()
            let applicationSupport = root.appendingPathComponent("not-created-app-support")
            let caches = root.appendingPathComponent("not-created-caches")
            let environment = PersistenceEnvironment(
                applicationSupportURL: applicationSupport,
                cachesURL: caches,
                userDefaults: defaults,
                isTesting: false
            )

            XCTAssertEqual(environment.applicationSupportURL, applicationSupport)
            XCTAssertEqual(environment.cachesURL, caches)
            XCTAssertTrue(environment.userDefaults === defaults)
            XCTAssertFalse(environment.isTesting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path))
        }
    }

    func testProductionFactoryFailsClosedToOnePerProcessRootUnderXCTest() throws {
        let first = try PersistenceEnvironment.production()
        let second = try PersistenceEnvironment.production()

        XCTAssertTrue(first.isTesting)
        XCTAssertTrue(second.isTesting)
        XCTAssertFalse(first.userDefaults === UserDefaults.standard)
        XCTAssertFalse(second.userDefaults === UserDefaults.standard)

        let firstRoot = isolatedRoot(of: first)
        let secondRoot = isolatedRoot(of: second)
        XCTAssertEqual(firstRoot, secondRoot)
        XCTAssertTrue(
            firstRoot.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path
            )
        )
        XCTAssertEqual(first.applicationSupportURL.lastPathComponent, "MusicPlayer")
        XCTAssertEqual(first.cachesURL.lastPathComponent, "MusicPlayer")

        let key = "persistence-environment-\(UUID().uuidString)"
        defer {
            first.userDefaults.removeObject(forKey: key)
            second.userDefaults.removeObject(forKey: key)
        }
        first.userDefaults.set("isolated", forKey: key)
        XCTAssertEqual(second.userDefaults.string(forKey: key), "isolated")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func testRuntimeDetectionCoversRegressionAndXCTestWithoutFalsePositive() {
        XCTAssertTrue(PersistenceEnvironment.isTestingRuntime(
            environment: ["MUSICPLAYER_RUN_REGRESSION_TESTS": "1"],
            processName: "MusicPlayer",
            hasXCTestRuntime: false
        ))
        XCTAssertTrue(PersistenceEnvironment.isTestingRuntime(
            environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
            processName: "MusicPlayer",
            hasXCTestRuntime: false
        ))
        XCTAssertTrue(PersistenceEnvironment.isTestingRuntime(
            environment: [:],
            processName: "MusicPlayerPackageTests.xctest",
            hasXCTestRuntime: false
        ))
        XCTAssertTrue(PersistenceEnvironment.isTestingRuntime(
            environment: [:],
            processName: "MusicPlayer",
            hasXCTestRuntime: true
        ))
        XCTAssertFalse(PersistenceEnvironment.isTestingRuntime(
            environment: ["MUSICPLAYER_RUN_REGRESSION_TESTS": "0"],
            processName: "MusicPlayer",
            hasXCTestRuntime: false
        ))
    }

    func testPrepareDirectoriesCreatesNestedPrivateDirectories() throws {
        try withTemporaryDirectory { root in
            let environment = PersistenceEnvironment(
                applicationSupportURL: root
                    .appendingPathComponent("Application Support")
                    .appendingPathComponent("MusicPlayer"),
                cachesURL: root
                    .appendingPathComponent("Caches")
                    .appendingPathComponent("MusicPlayer"),
                userDefaults: try makeDefaults(),
                isTesting: true
            )

            try environment.prepareDirectories()

            XCTAssertEqual(try posixMode(environment.applicationSupportURL), 0o700)
            XCTAssertEqual(try posixMode(environment.cachesURL), 0o700)
            XCTAssertEqual(
                try posixMode(environment.applicationSupportURL.deletingLastPathComponent()),
                0o700
            )
            XCTAssertEqual(
                try posixMode(environment.cachesURL.deletingLastPathComponent()),
                0o700
            )
        }
    }

    func testPrepareDirectoryTightensExistingPermissions() throws {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("existing", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )

            _ = try PersistenceEnvironment.ensureSecureDirectory(at: directory)

            XCTAssertEqual(try posixMode(directory), 0o700)
        }
    }

    func testPrepareDirectoryRejectsSymlinkWithoutChangingTarget() throws {
        try withTemporaryDirectory { root in
            let target = root.appendingPathComponent("target", isDirectory: true)
            let link = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: target.path
            )
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            XCTAssertThrowsError(try PersistenceEnvironment.ensureSecureDirectory(at: link)) {
                XCTAssertEqual($0 as? PersistenceEnvironmentError, .unsafeDirectory)
            }
            XCTAssertEqual(try posixMode(target), 0o755)
        }
    }

    func testPrepareDirectoryRejectsSymlinkedAncestorBeforeCreatingChild() throws {
        try withTemporaryDirectory { root in
            let target = root.appendingPathComponent("ancestor-target", isDirectory: true)
            let link = root.appendingPathComponent("ancestor-link", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let requested = link.appendingPathComponent("must-not-exist", isDirectory: true)

            XCTAssertThrowsError(try PersistenceEnvironment.ensureSecureDirectory(at: requested)) {
                XCTAssertEqual($0 as? PersistenceEnvironmentError, .unsafeDirectory)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: target.appendingPathComponent("must-not-exist").path
                )
            )
        }
    }

    func testPrepareDirectoryRejectsSymlinkedAncestorWithExistingDescendant() throws {
        try withTemporaryDirectory { root in
            let target = root.appendingPathComponent("existing-target", isDirectory: true)
            let descendant = target.appendingPathComponent("already-there", isDirectory: true)
            let link = root.appendingPathComponent("existing-link", isDirectory: true)
            try FileManager.default.createDirectory(
                at: descendant,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: descendant.path
            )
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            XCTAssertThrowsError(
                try PersistenceEnvironment.ensureSecureDirectory(
                    at: link.appendingPathComponent("already-there", isDirectory: true)
                )
            ) {
                XCTAssertEqual($0 as? PersistenceEnvironmentError, .unsafeDirectory)
            }
            XCTAssertNotEqual(try posixMode(descendant), 0o700)
        }
    }

    func testPrepareDirectoryRejectsRegularFile() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("not-a-directory")
            try Data("sentinel".utf8).write(to: file)

            XCTAssertThrowsError(try PersistenceEnvironment.ensureSecureDirectory(at: file)) {
                XCTAssertEqual($0 as? PersistenceEnvironmentError, .unsafeDirectory)
            }
            XCTAssertEqual(try Data(contentsOf: file), Data("sentinel".utf8))
        }
    }

    private func isolatedRoot(of environment: PersistenceEnvironment) -> URL {
        environment.applicationSupportURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "persistence-environment-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
            "musicplayer-persistence-environment-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
