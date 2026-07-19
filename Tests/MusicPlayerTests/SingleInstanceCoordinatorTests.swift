import Darwin
import Foundation
import XCTest
@testable import MusicPlayer

@_silgen_name("flock")
private func testSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class SingleInstanceCoordinatorTests: XCTestCase {
    func testOnlyOneCoordinatorAcquiresTheAdvisoryLock() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)

            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            primary.release()
            let replacement = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try replacement.acquire(), .primary)
            replacement.release()
        }
    }

    func testReleasingSecondaryDoesNotReleasePrimaryLock() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            secondary.release()
            let contender = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try contender.acquire(), .secondary)

            contender.release()
            primary.release()
        }
    }

    func testLockFileAndDirectoryAreOwnerOnly() throws {
        try withTemporaryDirectory { root in
            let privateDirectory = root.appendingPathComponent("private", isDirectory: true)
            let lockURL = privateDirectory.appendingPathComponent("single-writer.lock")
            let coordinator = makeCoordinator(
                lockURL: lockURL,
                transport: FakeSingleInstanceTransport(),
                name: Notification.Name("single-instance-test-\(UUID().uuidString)")
            )

            XCTAssertEqual(try coordinator.acquire(), .primary)

            let directoryMode = try posixMode(at: privateDirectory)
            let fileMode = try posixMode(at: lockURL)
            XCTAssertEqual(directoryMode, 0o700)
            XCTAssertEqual(fileMode, 0o600)
            coordinator.release()
        }
    }

    func testSecondaryRereadsTokenDuringPrimaryPublicationWindow() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
            let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer {
                _ = testSystemFlock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            XCTAssertEqual(testSystemFlock(descriptor, LOCK_EX | LOCK_NB), 0)

            let publishedToken = UUID().uuidString
            let publicationFinished = expectation(description: "primary publishes token")
            DispatchQueue.global(qos: .userInitiated).async {
                usleep(15_000)
                _ = ftruncate(descriptor, 0)
                _ = writeAll(Array(publishedToken.utf8), to: descriptor)
                _ = fsync(descriptor)
                publicationFinished.fulfill()
            }

            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try secondary.acquire(), .secondary)
            secondary.forwardOpenRequest([directory.appendingPathComponent("song.mp3")])
            wait(for: [publicationFinished], timeout: 1)

            let payload = try XCTUnwrap(transport.postedPayloads(for: name).first)
            XCTAssertEqual(payload["handoffToken"] as? String, publishedToken)
            secondary.release()
        }
    }

    func testSecondaryTokenRereadIsBoundedWhenPublicationNeverCompletes() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
            let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer {
                _ = testSystemFlock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            XCTAssertEqual(testSystemFlock(descriptor, LOCK_EX | LOCK_NB), 0)

            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let startedAt = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try secondary.acquire(), .secondary)
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

            XCTAssertLessThan(elapsed, 1.0)
            secondary.forwardOpenRequest([directory.appendingPathComponent("song.mp3")])
            XCTAssertTrue(transport.postedPayloads(for: name).isEmpty)
            secondary.release()
        }
    }

    func testForwardRetryRefreshesStaleTokenAfterPrimaryReplacement() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let staleToken = UUID().uuidString
            let currentToken = UUID().uuidString
            try Data(staleToken.utf8).write(to: lockURL)
            let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer {
                _ = testSystemFlock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            XCTAssertEqual(testSystemFlock(descriptor, LOCK_EX | LOCK_NB), 0)

            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            let publicationFinished = expectation(description: "replacement token published")
            DispatchQueue.global(qos: .userInitiated).async {
                usleep(30_000)
                _ = ftruncate(descriptor, 0)
                _ = writeAll(Array(currentToken.utf8), to: descriptor)
                _ = fsync(descriptor)
                publicationFinished.fulfill()
            }
            secondary.forwardOpenRequest([directory.appendingPathComponent("song.mp3")])
            wait(for: [publicationFinished], timeout: 1)
            let retrySettled = expectation(description: "retry reads replacement token")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                retrySettled.fulfill()
            }
            wait(for: [retrySettled], timeout: 1)

            let payloads = transport.postedPayloads(for: name)
            XCTAssertEqual(payloads.count, 2)
            XCTAssertEqual(payloads[0]["handoffToken"] as? String, staleToken)
            XCTAssertEqual(payloads[1]["handoffToken"] as? String, currentToken)
            XCTAssertEqual(
                payloads[0]["requestID"] as? String,
                payloads[1]["requestID"] as? String
            )
            secondary.release()
        }
    }

    func testHardLinkedLockFileIsRejectedWithoutChangingTarget() throws {
        try withTemporaryDirectory { root in
            let privateDirectory = root.appendingPathComponent("private", isDirectory: true)
            try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false)
            let target = root.appendingPathComponent("target.txt")
            let lockURL = privateDirectory.appendingPathComponent("single-writer.lock")
            let originalData = Data("do-not-touch".utf8)
            XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: originalData))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: target.path
            )
            try FileManager.default.linkItem(at: target, to: lockURL)
            let originalMode = try posixMode(at: target)

            let coordinator = makeCoordinator(
                lockURL: lockURL,
                transport: FakeSingleInstanceTransport(),
                name: Notification.Name("single-instance-test-\(UUID().uuidString)")
            )
            XCTAssertThrowsError(try coordinator.acquire()) { error in
                XCTAssertEqual(
                    (error as? SingleInstanceCoordinatorError)?.operation,
                    .validateLockFile
                )
            }
            XCTAssertEqual(try Data(contentsOf: target), originalData)
            XCTAssertEqual(try posixMode(at: target), originalMode)
        }
    }

    func testSymlinkedLockFileDoesNotChangeOrTruncateTarget() throws {
        try withTemporaryDirectory { root in
            let privateDirectory = root.appendingPathComponent("private", isDirectory: true)
            try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false)
            let target = root.appendingPathComponent("target.txt")
            let lockURL = privateDirectory.appendingPathComponent("single-writer.lock")
            let originalData = Data("do-not-touch".utf8)
            XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: originalData))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: target.path
            )
            try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
            let originalMode = try posixMode(at: target)

            let coordinator = makeCoordinator(
                lockURL: lockURL,
                transport: FakeSingleInstanceTransport(),
                name: Notification.Name("single-instance-test-\(UUID().uuidString)")
            )
            XCTAssertThrowsError(try coordinator.acquire())
            XCTAssertEqual(try Data(contentsOf: target), originalData)
            XCTAssertEqual(try posixMode(at: target), originalMode)
        }
    }

    func testSymlinkedParentDoesNotChangeTargetDirectoryOrCreateLock() throws {
        try withTemporaryDirectory { root in
            let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: targetDirectory.path
            )
            let originalMode = try posixMode(at: targetDirectory)
            let linkedDirectory = root.appendingPathComponent("private", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory,
                withDestinationURL: targetDirectory
            )
            let lockURL = linkedDirectory.appendingPathComponent("single-writer.lock")

            let coordinator = makeCoordinator(
                lockURL: lockURL,
                transport: FakeSingleInstanceTransport(),
                name: Notification.Name("single-instance-test-\(UUID().uuidString)")
            )
            XCTAssertThrowsError(try coordinator.acquire()) { error in
                XCTAssertEqual(
                    (error as? SingleInstanceCoordinatorError)?.operation,
                    .prepareDirectory
                )
            }
            XCTAssertEqual(try posixMode(at: targetDirectory), originalMode)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: targetDirectory.appendingPathComponent("single-writer.lock").path
                )
            )
        }
    }

    func testOpenRequestQueuesUntilPrimaryInstallsHandler() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            var primaryActivationCount = 0
            var existingActivationCount = 0
            let primary = SingleInstanceCoordinator(
                lockFileURL: lockURL,
                transport: transport,
                notificationName: name,
                activateCurrentApplication: { primaryActivationCount += 1 },
                activateExistingApplication: {}
            )
            let secondary = SingleInstanceCoordinator(
                lockFileURL: lockURL,
                transport: transport,
                notificationName: name,
                activateCurrentApplication: {},
                activateExistingApplication: { existingActivationCount += 1 }
            )
            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            let requestedURLs = [
                directory.appendingPathComponent("First Song.mp3"),
                directory.appendingPathComponent("Second Song.flac")
            ]
            secondary.forwardOpenRequest(requestedURLs)

            XCTAssertEqual(primaryActivationCount, 1)
            XCTAssertEqual(existingActivationCount, 1)

            var received: [[URL]] = []
            primary.setOpenRequestHandler { received.append($0) }
            XCTAssertEqual(received, [requestedURLs.map(\.standardizedFileURL)])

            primary.release()
        }
    }

    func testHandlerReceivesLaterRequestsImmediatelyAndInOrder() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            var received: [[URL]] = []
            primary.setOpenRequestHandler { received.append($0) }
            let first = directory.appendingPathComponent("one.mp3")
            let second = directory.appendingPathComponent("two.m4a")
            secondary.forwardOpenRequest([first])
            secondary.forwardOpenRequest([second])

            XCTAssertEqual(
                received,
                [[first.standardizedFileURL], [second.standardizedFileURL]]
            )
            primary.release()
        }
    }

    func testForwardRetryReusesRequestIDAndIsDeliveredOnlyOnce() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            let firstDelivery = expectation(description: "first delivery")
            let receivedLock = NSLock()
            var receivedCount = 0
            primary.setOpenRequestHandler { _ in
                receivedLock.lock()
                receivedCount += 1
                let isFirst = receivedCount == 1
                receivedLock.unlock()
                if isFirst { firstDelivery.fulfill() }
            }

            secondary.forwardOpenRequest([directory.appendingPathComponent("song.mp3")])
            wait(for: [firstDelivery], timeout: 1)
            let retrySettled = expectation(description: "100 ms retry posted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                retrySettled.fulfill()
            }
            wait(for: [retrySettled], timeout: 1)

            receivedLock.lock()
            let finalReceivedCount = receivedCount
            receivedLock.unlock()
            XCTAssertEqual(finalReceivedCount, 1)
            let payloads = transport.postedPayloads(for: name)
            XCTAssertEqual(payloads.count, 2)
            let requestIDs = try payloads.map {
                try XCTUnwrap($0["requestID"] as? String)
            }
            XCTAssertEqual(Set(requestIDs).count, 1)
            primary.release()
            secondary.release()
        }
    }

    func testSecondaryTakeoverPreservesOpenRequestAfterPrimaryReleasesLock() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            let oldToken = try handoffToken(at: lockURL)
            XCTAssertEqual(try secondary.acquire(), .secondary)
            let requestedURL = directory.appendingPathComponent("takeover.mp3")

            let released = expectation(description: "old primary releases writer lock")
            DispatchQueue.global(qos: .userInitiated).async {
                usleep(40_000)
                primary.release()
                released.fulfill()
            }

            let resolution = try secondary.resolveSecondaryLaunch(
                openURLs: [requestedURL],
                takeoverTimeout: 0.50,
                retryInterval: 0.005
            )
            wait(for: [released], timeout: 1)

            XCTAssertEqual(
                resolution,
                .becamePrimary(openURLs: [requestedURL.standardizedFileURL])
            )
            let newToken = try handoffToken(at: lockURL)
            XCTAssertNotEqual(newToken, oldToken)
            var received: [[URL]] = []
            secondary.setOpenRequestHandler { received.append($0) }
            XCTAssertEqual(received, [[requestedURL.standardizedFileURL]])
            secondary.release()
        }
    }

    func testSecondaryTakeoverTimeoutIsFiniteWhilePrimaryRemainsHealthy() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondary.acquire(), .secondary)

            let startedAt = ProcessInfo.processInfo.systemUptime
            let resolution = try secondary.resolveSecondaryLaunch(
                openURLs: [],
                takeoverTimeout: 0.03,
                retryInterval: 0.005
            )
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

            XCTAssertEqual(resolution, .forwardedToPrimary)
            XCTAssertGreaterThanOrEqual(elapsed, 0.02)
            XCTAssertLessThan(elapsed, 0.20)
            let contender = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try contender.acquire(), .secondary)
            contender.release()
            secondary.release()
            primary.release()
        }
    }

    func testOnlyOneSecondaryWinsConcurrentTakeover() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondaryA = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            let secondaryB = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            XCTAssertEqual(try secondaryA.acquire(), .secondary)
            XCTAssertEqual(try secondaryB.acquire(), .secondary)

            let resultsLock = NSLock()
            var results: [(String, SingleInstanceCoordinator.SecondaryLaunchResolution)] = []
            let group = DispatchGroup()
            for (label, coordinator) in [("a", secondaryA), ("b", secondaryB)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    let url = directory.appendingPathComponent("\(label).mp3")
                    guard let result = try? coordinator.resolveSecondaryLaunch(
                        openURLs: [url],
                        takeoverTimeout: 0.35,
                        retryInterval: 0.005
                    ) else { return }
                    resultsLock.lock()
                    results.append((label, result))
                    resultsLock.unlock()
                }
            }
            usleep(40_000)
            primary.release()
            XCTAssertEqual(group.wait(timeout: .now() + 1), .success)

            resultsLock.lock()
            let snapshot = results
            resultsLock.unlock()
            let winners = snapshot.filter {
                if case .becamePrimary = $0.1 { return true }
                return false
            }
            XCTAssertEqual(snapshot.count, 2)
            XCTAssertEqual(winners.count, 1)
            XCTAssertEqual(snapshot.filter { $0.1 == .forwardedToPrimary }.count, 1)
            secondaryA.release()
            secondaryB.release()
        }
    }

    func testAuthenticatedRequestAccepts128PathsAndRejects129() throws {
        try withTemporaryDirectory { directory in
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            let token = try handoffToken(at: lockURL)
            var received: [[URL]] = []
            primary.setOpenRequestHandler { received.append($0) }

            let paths = (0..<128).map { "/tmp/musicplayer-path-\($0).mp3" }
            postAuthenticatedRequest(paths: paths, token: token, name: name, transport: transport)
            XCTAssertEqual(received.count, 1)
            XCTAssertEqual(received.first?.count, 128)

            postAuthenticatedRequest(
                paths: paths + ["/tmp/too-many.mp3"],
                token: token,
                name: name,
                transport: transport
            )
            XCTAssertEqual(received.count, 1)
            primary.release()
        }
    }

    func testAuthenticatedRequestEnforcesTotalPathByteLimit() throws {
        try withTemporaryDirectory { directory in
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            let token = try handoffToken(at: lockURL)
            var received: [[URL]] = []
            primary.setOpenRequestHandler { received.append($0) }

            let exactLimit = (0..<16).map { absolutePath(byteCount: 16 * 1_024, marker: $0) }
            XCTAssertEqual(exactLimit.reduce(0) { $0 + $1.utf8.count }, 256 * 1_024)
            postAuthenticatedRequest(
                paths: exactLimit,
                token: token,
                name: name,
                transport: transport
            )
            XCTAssertEqual(received.count, 1)
            XCTAssertEqual(received.first?.count, 16)

            postAuthenticatedRequest(
                paths: exactLimit + ["/x"],
                token: token,
                name: name,
                transport: transport
            )
            XCTAssertEqual(received.count, 1)
            primary.release()
        }
    }

    func testAuthenticatedRequestRejectsRelativePath() throws {
        try withTemporaryDirectory { directory in
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            let token = try handoffToken(at: lockURL)
            var received = 0
            primary.setOpenRequestHandler { _ in received += 1 }

            postAuthenticatedRequest(
                paths: ["relative/song.mp3"],
                token: token,
                name: name,
                transport: transport
            )
            XCTAssertEqual(received, 0)
            primary.release()
        }
    }

    func testRequestWithWrongTokenIsRejected() throws {
        try withTemporaryDirectory { directory in
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let lockURL = directory.appendingPathComponent("single-writer.lock")
            let primary = makeCoordinator(lockURL: lockURL, transport: transport, name: name)
            XCTAssertEqual(try primary.acquire(), .primary)
            let validToken = try handoffToken(at: lockURL)
            let wrongToken = UUID().uuidString
            XCTAssertNotEqual(wrongToken, validToken)
            var received = 0
            primary.setOpenRequestHandler { _ in received += 1 }

            postAuthenticatedRequest(
                paths: ["/tmp/song.mp3"],
                token: wrongToken,
                name: name,
                transport: transport
            )
            XCTAssertEqual(received, 0)
            primary.release()
        }
    }

    func testMalformedNotificationIsIgnored() throws {
        try withTemporaryDirectory { directory in
            let transport = FakeSingleInstanceTransport()
            let name = Notification.Name("single-instance-test-\(UUID().uuidString)")
            let primary = makeCoordinator(
                lockURL: directory.appendingPathComponent("single-writer.lock"),
                transport: transport,
                name: name
            )
            XCTAssertEqual(try primary.acquire(), .primary)
            var received = 0
            primary.setOpenRequestHandler { _ in received += 1 }

            transport.post(name: name, userInfo: ["paths": ["/tmp/example.mp3"]])
            transport.post(name: name, userInfo: ["requestID": UUID().uuidString])
            transport.post(
                name: name,
                userInfo: ["requestID": UUID().uuidString, "paths": "not-an-array"]
            )

            XCTAssertEqual(received, 0)
            primary.release()
        }
    }

    func testCommandLineOpenURLParsingSkipsFlagsAndResolvesRelativePaths() {
        let currentDirectory = URL(fileURLWithPath: "/tmp/musicplayer-tests", isDirectory: true)
        let urls = SingleInstanceCoordinator.commandLineOpenURLs(
            arguments: [
                "/Applications/MusicPlayer.app/Contents/MacOS/MusicPlayer",
                "--debug",
                "relative.mp3",
                "/tmp/absolute.flac",
                "file:///tmp/url.m4a"
            ],
            currentDirectoryURL: currentDirectory
        )

        XCTAssertEqual(
            urls,
            [
                currentDirectory.appendingPathComponent("relative.mp3").standardizedFileURL,
                URL(fileURLWithPath: "/tmp/absolute.flac").standardizedFileURL,
                URL(fileURLWithPath: "/tmp/url.m4a").standardizedFileURL
            ]
        )
    }

    private func makeCoordinator(
        lockURL: URL,
        transport: FakeSingleInstanceTransport,
        name: Notification.Name
    ) -> SingleInstanceCoordinator {
        SingleInstanceCoordinator(
            lockFileURL: lockURL,
            transport: transport,
            notificationName: name,
            activateCurrentApplication: {},
            activateExistingApplication: {}
        )
    }

    private func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func handoffToken(at lockURL: URL) throws -> String {
        let token = try String(contentsOf: lockURL, encoding: .utf8)
        XCTAssertNotNil(UUID(uuidString: token))
        return token
    }

    private func postAuthenticatedRequest(
        paths: [String],
        token: String,
        name: Notification.Name,
        transport: FakeSingleInstanceTransport
    ) {
        transport.post(
            name: name,
            userInfo: [
                "requestID": UUID().uuidString,
                "paths": paths,
                "handoffToken": token,
            ]
        )
    }

    private func absolutePath(byteCount: Int, marker: Int) -> String {
        let prefix = "/p\(marker)-"
        precondition(prefix.utf8.count <= byteCount)
        return prefix + String(repeating: "a", count: byteCount - prefix.utf8.count)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-single-instance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class FakeSingleInstanceTransport: SingleInstanceNotificationTransport {
    private final class Token: NSObject {
        let id = UUID()
    }

    private let lock = NSLock()
    private var observers: [UUID: (Notification.Name, ([AnyHashable: Any]?) -> Void)] = [:]
    private var posts: [(Notification.Name, [AnyHashable: Any])] = []

    @discardableResult
    func addObserver(
        forName name: Notification.Name,
        handler: @escaping ([AnyHashable: Any]?) -> Void
    ) -> NSObjectProtocol {
        let token = Token()
        lock.lock()
        observers[token.id] = (name, handler)
        lock.unlock()
        return token
    }

    func removeObserver(_ observer: NSObjectProtocol) {
        guard let token = observer as? Token else { return }
        lock.lock()
        observers.removeValue(forKey: token.id)
        lock.unlock()
    }

    func post(name: Notification.Name, userInfo: [AnyHashable: Any]) {
        lock.lock()
        posts.append((name, userInfo))
        let handlers = observers.values.filter { $0.0 == name }.map(\.1)
        lock.unlock()
        for handler in handlers {
            handler(userInfo)
        }
    }

    func postedPayloads(for name: Notification.Name) -> [[AnyHashable: Any]] {
        lock.lock()
        let payloads = posts.filter { $0.0 == name }.map(\.1)
        lock.unlock()
        return payloads
    }
}

@discardableResult
private func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { rawBuffer in
            pwrite(
                descriptor,
                rawBuffer.baseAddress?.advanced(by: offset),
                rawBuffer.count - offset,
                off_t(offset)
            )
        }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
    }
    return true
}
