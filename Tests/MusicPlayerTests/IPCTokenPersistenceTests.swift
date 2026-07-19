import Foundation
import XCTest
@testable import MusicPlayer
import MusicPlayerIPC

final class IPCTokenPersistenceTests: XCTestCase {
    func testTokenCreationIsOwnerOnlyAndStable() throws {
        try withTemporaryDirectory { directory in
            let privateDirectory = directory.appendingPathComponent("ipc", isDirectory: true)
            let tokenURL = privateDirectory.appendingPathComponent("ipc-auth-token")
            let firstToken = UUID().uuidString + UUID().uuidString
            let secondToken = UUID().uuidString + UUID().uuidString

            XCTAssertEqual(
                try IPCServer.loadOrCreateAuthToken(at: tokenURL, generatedToken: firstToken),
                firstToken
            )
            XCTAssertEqual(
                try IPCServer.loadOrCreateAuthToken(at: tokenURL, generatedToken: secondToken),
                firstToken
            )
            XCTAssertEqual(try posixMode(at: privateDirectory), 0o700)
            XCTAssertEqual(try posixMode(at: tokenURL), 0o600)
            XCTAssertEqual(try String(contentsOf: tokenURL, encoding: .utf8), firstToken)
        }
    }

    func testTwoCreatorsConvergeOnOneToken() throws {
        try withTemporaryDirectory { directory in
            let tokenURL = directory.appendingPathComponent("ipc-auth-token")
            let candidates = [
                UUID().uuidString + UUID().uuidString,
                UUID().uuidString + UUID().uuidString
            ]
            let queue = DispatchQueue(label: "ipc-token-race", attributes: .concurrent)
            let group = DispatchGroup()
            let resultLock = NSLock()
            var results: [Result<String, Error>] = []

            for candidate in candidates {
                group.enter()
                queue.async {
                    let result = Result {
                        try IPCServer.loadOrCreateAuthToken(
                            at: tokenURL,
                            generatedToken: candidate
                        )
                    }
                    resultLock.lock()
                    results.append(result)
                    resultLock.unlock()
                    group.leave()
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

            let tokens = try results.map { try $0.get() }
            XCTAssertEqual(tokens.count, 2)
            XCTAssertEqual(Set(tokens).count, 1)
            XCTAssertTrue(candidates.contains(try XCTUnwrap(tokens.first)))
            XCTAssertEqual(try posixMode(at: tokenURL), 0o600)
        }
    }

    func testExistingTokenPermissionsAreTightenedWithoutReplacement() throws {
        try withTemporaryDirectory { directory in
            let tokenURL = directory.appendingPathComponent("ipc-auth-token")
            let existing = UUID().uuidString + UUID().uuidString
            try existing.write(to: tokenURL, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: tokenURL.path
            )

            let loaded = try IPCServer.loadOrCreateAuthToken(
                at: tokenURL,
                generatedToken: UUID().uuidString + UUID().uuidString
            )

            XCTAssertEqual(loaded, existing)
            XCTAssertEqual(try posixMode(at: tokenURL), 0o600)
            XCTAssertEqual(try String(contentsOf: tokenURL, encoding: .utf8), existing)
        }
    }

    func testSymlinkTokenIsRejectedWithoutChangingTarget() throws {
        try withTemporaryDirectory { directory in
            let targetURL = directory.appendingPathComponent("target")
            let tokenURL = directory.appendingPathComponent("ipc-auth-token")
            let original = UUID().uuidString + UUID().uuidString
            try original.write(to: targetURL, atomically: false, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: tokenURL,
                withDestinationURL: targetURL
            )

            XCTAssertThrowsError(
                try IPCServer.loadOrCreateAuthToken(
                    at: tokenURL,
                    generatedToken: UUID().uuidString + UUID().uuidString
                )
            )
            XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), original)
        }
    }

    func testInvalidExistingTokenIsPreserved() throws {
        try withTemporaryDirectory { directory in
            let tokenURL = directory.appendingPathComponent("ipc-auth-token")
            let invalid = "invalid"
            try invalid.write(to: tokenURL, atomically: false, encoding: .utf8)

            XCTAssertThrowsError(
                try IPCServer.loadOrCreateAuthToken(
                    at: tokenURL,
                    generatedToken: UUID().uuidString + UUID().uuidString
                )
            )
            XCTAssertEqual(try String(contentsOf: tokenURL, encoding: .utf8), invalid)
        }
    }

    func testRegistryPersistenceIsAtomicAndOwnerOnly() throws {
        try withTemporaryDirectory { directory in
            let registryDirectory = directory.appendingPathComponent("ipc-instances", isDirectory: true)
            let registrationURL = registryDirectory.appendingPathComponent("instance.json")
            let payload = Data("{\"pid\":123}".utf8)

            try IPCServer.persistRegistrationData(payload, to: registrationURL)

            XCTAssertEqual(try Data(contentsOf: registrationURL), payload)
            XCTAssertEqual(try posixMode(at: registryDirectory), 0o700)
            XCTAssertEqual(try posixMode(at: registrationURL), 0o600)
        }
    }

    func testWeightMutationReplyRequiresDurableFlush() {
        let requestID = UUID().uuidString
        let durable = PlaybackWeights.PersistenceFlushResult(
            outcome: .persisted,
            attemptedGeneration: 4,
            durableGeneration: 4,
            hasPendingChanges: false
        )
        let success = IPCServer.makeWeightPersistenceReply(
            requestID: requestID,
            successMessage: "saved",
            data: ["level": "2"],
            flushResult: durable
        )
        XCTAssertTrue(success.ok)
        XCTAssertEqual(success.message, "saved")
        XCTAssertEqual(success.data?["level"], "2")

        let failed = PlaybackWeights.PersistenceFlushResult(
            outcome: .failed(.writeFailed),
            attemptedGeneration: 5,
            durableGeneration: 4,
            hasPendingChanges: true
        )
        let failure = IPCServer.makeWeightPersistenceReply(
            requestID: requestID,
            successMessage: nil,
            data: nil,
            flushResult: failed
        )
        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.message, "weight persistence failed: write failed")
        XCTAssertEqual(failure.data?["acceptedInMemory"], "true")
        XCTAssertEqual(failure.data?["hasPendingChanges"], "true")
        XCTAssertEqual(failure.data?["durableGeneration"], "4")
    }

    func testRegistryCleanupExaminesAtMost256Entries() throws {
        try withTemporaryDirectory { directory in
            let registryDirectory = directory.appendingPathComponent("ipc-instances", isDirectory: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)

            for index in 0..<300 {
                let registration = makeRegistration(
                    instanceID: UUID().uuidString,
                    pid: Int32(index + 1)
                )
                let data = try JSONEncoder().encode(registration)
                try data.write(
                    to: registryDirectory.appendingPathComponent("\(registration.instanceID).json")
                )
            }

            let report = IPCServer.cleanupStaleRegistrations(
                at: registryDirectory,
                maximumEntries: 256,
                processValidator: { _ in false }
            )

            XCTAssertEqual(report.examined, 256)
            XCTAssertEqual(report.removed, 256)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: registryDirectory.path)
            XCTAssertEqual(remaining.count, 44)
        }
    }

    func testRegistryCleanupUnlinksSymlinkWithoutTouchingTarget() throws {
        try withTemporaryDirectory { directory in
            let registryDirectory = directory.appendingPathComponent("ipc-instances", isDirectory: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            let targetURL = directory.appendingPathComponent("registry-target")
            let original = Data("do-not-touch".utf8)
            try original.write(to: targetURL)

            let instanceID = UUID().uuidString
            let symlinkURL = registryDirectory.appendingPathComponent("\(instanceID).json")
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

            let report = IPCServer.cleanupStaleRegistrations(
                at: registryDirectory,
                processValidator: { _ in true }
            )

            XCTAssertEqual(report.removed, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
            XCTAssertEqual(try Data(contentsOf: targetURL), original)
        }
    }

    func testRegistryCleanupKeepsStructurallyValidLiveEntry() throws {
        try withTemporaryDirectory { directory in
            let registryDirectory = directory.appendingPathComponent("ipc-instances", isDirectory: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            let registration = makeRegistration(instanceID: UUID().uuidString, pid: 123)
            let registrationURL = registryDirectory.appendingPathComponent("\(registration.instanceID).json")
            try JSONEncoder().encode(registration).write(to: registrationURL)

            let report = IPCServer.cleanupStaleRegistrations(
                at: registryDirectory,
                processValidator: { $0.pid == 123 }
            )

            XCTAssertEqual(report.examined, 1)
            XCTAssertEqual(report.removed, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: registrationURL.path))
        }
    }

    private func makeRegistration(instanceID: String, pid: Int32) -> IPCInstanceRegistration {
        IPCInstanceRegistration(
            instanceID: instanceID,
            pid: pid,
            startedAt: 1,
            bundlePath: "/Applications/MusicPlayer.app",
            requestNotificationName: MusicPlayerIPC.requestNotification(for: instanceID).rawValue,
            replyNotificationName: MusicPlayerIPC.replyNotification(for: instanceID).rawValue
        )
    }

    private func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-ipc-persistence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
