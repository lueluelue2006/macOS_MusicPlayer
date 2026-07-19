import AppKit
import Darwin
import Foundation

// Darwin exposes both `struct flock` and the BSD `flock(2)` function. Recent
// Swift SDK overlays resolve `Darwin.flock` to the struct, so bind the function
// symbol explicitly instead of falling back to process-scoped `fcntl` locks.
@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

protocol SingleInstanceNotificationTransport: AnyObject {
    @discardableResult
    func addObserver(
        forName name: Notification.Name,
        handler: @escaping ([AnyHashable: Any]?) -> Void
    ) -> NSObjectProtocol

    func removeObserver(_ observer: NSObjectProtocol)
    func post(name: Notification.Name, userInfo: [AnyHashable: Any])
}

final class DistributedSingleInstanceNotificationTransport: SingleInstanceNotificationTransport {
    private let center: DistributedNotificationCenter

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    @discardableResult
    func addObserver(
        forName name: Notification.Name,
        handler: @escaping ([AnyHashable: Any]?) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { notification in
            handler(notification.userInfo)
        }
    }

    func removeObserver(_ observer: NSObjectProtocol) {
        center.removeObserver(observer)
    }

    func post(name: Notification.Name, userInfo: [AnyHashable: Any]) {
        center.postNotificationName(
            name,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}

struct SingleInstanceCoordinatorError: Error, Equatable, LocalizedError {
    enum Operation: String, Equatable {
        case locateApplicationSupport
        case prepareDirectory
        case openLockFile
        case validateLockFile
        case acquireLock
        case prepareHandoff
    }

    let operation: Operation
    let code: Int32

    var errorDescription: String? {
        "Single-instance coordination failed during \(operation.rawValue) (code \(code))"
    }
}

/// Owns the process-wide advisory lock that makes one MusicPlayer process the
/// only persistence writer. Distributed notifications are deliberately limited
/// to activation and file-open handoff; persisted mutations continue to use the
/// authenticated IPC channel.
final class SingleInstanceCoordinator {
    enum Acquisition: Equatable {
        case primary
        case secondary
    }

    struct OpenRequest: Equatable {
        let id: String
        let urls: [URL]
    }

    struct ForwardedOpenRequest: Equatable {
        fileprivate let id: String
        let urls: [URL]
    }

    enum SecondaryLaunchResolution: Equatable {
        case becamePrimary(openURLs: [URL])
        case forwardedToPrimary
    }

    static let defaultNotificationName = Notification.Name(
        "io.github.lueluelue2006.macosmusicplayer.single-instance.open.v1"
    )

    private static let requestIDKey = "requestID"
    private static let pathsKey = "paths"
    private static let handoffTokenKey = "handoffToken"
    private static let maximumRememberedRequestIDs = 128
    private static let maximumPendingOpenRequests = 16
    private static let maximumPathsPerRequest = 128
    private static let maximumPathBytes = 16 * 1_024
    private static let maximumTotalPathBytes = 256 * 1_024
    private static let handoffTokenReadAttempts = 11
    private static let handoffTokenRetryDelayMicroseconds: useconds_t = 10_000
    private static let defaultTakeoverTimeout: TimeInterval = 1.25
    private static let maximumTakeoverTimeout: TimeInterval = 2.0
    private static let defaultTakeoverRetryInterval: TimeInterval = 0.02

    private enum State {
        case idle
        case primary
        case secondary
        case released
    }

    private let lockFileURL: URL
    private let transport: SingleInstanceNotificationTransport
    private let notificationName: Notification.Name
    private let activateCurrentApplication: () -> Void
    private let activateExistingApplication: () -> Void
    private let stateLock = NSLock()

    private var state: State = .idle
    private var lockFileDescriptor: Int32 = -1
    private var observer: NSObjectProtocol?
    private var pendingOpenRequests: [OpenRequest] = []
    private var openRequestHandler: (([URL]) -> Void)?
    private var rememberedRequestIDs: [String] = []
    private var rememberedRequestIDSet: Set<String> = []
    private var handoffToken: String?
    private var isTakeoverInProgress = false

    convenience init() throws {
        try self.init(lockFileURL: Self.defaultLockFileURL())
    }

    init(
        lockFileURL: URL,
        transport: SingleInstanceNotificationTransport = DistributedSingleInstanceNotificationTransport(),
        notificationName: Notification.Name = SingleInstanceCoordinator.defaultNotificationName,
        activateCurrentApplication: @escaping () -> Void = SingleInstanceCoordinator.activateCurrent,
        activateExistingApplication: @escaping () -> Void = SingleInstanceCoordinator.activateExisting
    ) {
        self.lockFileURL = lockFileURL
        self.transport = transport
        self.notificationName = notificationName
        self.activateCurrentApplication = activateCurrentApplication
        self.activateExistingApplication = activateExistingApplication
    }

    deinit {
        release()
    }

    func acquire() throws -> Acquisition {
        stateLock.lock()
        switch state {
        case .primary:
            stateLock.unlock()
            return .primary
        case .secondary:
            stateLock.unlock()
            return .secondary
        case .released:
            stateLock.unlock()
            throw SingleInstanceCoordinatorError(operation: .acquireLock, code: EINVAL)
        case .idle:
            break
        }
        stateLock.unlock()

        let directoryDescriptor = try Self.preparePrivateDirectory(
            lockFileURL.deletingLastPathComponent()
        )
        defer { Darwin.close(directoryDescriptor) }

        let lockFileName = lockFileURL.lastPathComponent
        guard !lockFileName.isEmpty, lockFileName != ".", lockFileName != ".." else {
            throw SingleInstanceCoordinatorError(operation: .openLockFile, code: EINVAL)
        }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            lockFileName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw SingleInstanceCoordinatorError(operation: .openLockFile, code: errno)
        }

        do {
            try Self.validateAndSecureLockFile(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        if systemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            let token = UUID().uuidString
            do {
                try Self.writeHandoffToken(token, to: descriptor)
            } catch {
                _ = systemFlock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
                throw error
            }
            stateLock.lock()
            lockFileDescriptor = descriptor
            handoffToken = token
            state = .primary
            stateLock.unlock()
            installObserver()
            return .primary
        }

        let lockError = errno
        let primaryToken = (lockError == EWOULDBLOCK || lockError == EAGAIN)
            ? Self.readHandoffTokenWithBoundedRetry(from: descriptor)
            : nil
        if lockError == EWOULDBLOCK || lockError == EAGAIN {
            stateLock.lock()
            lockFileDescriptor = descriptor
            handoffToken = primaryToken
            state = .secondary
            stateLock.unlock()
            return .secondary
        }
        Darwin.close(descriptor)
        throw SingleInstanceCoordinatorError(operation: .acquireLock, code: lockError)
    }

    /// Sends an activation/open request to the primary process. Empty URL lists
    /// are valid and mean activation only.
    @discardableResult
    func forwardOpenRequest(_ urls: [URL]) -> ForwardedOpenRequest {
        let request = makeForwardedOpenRequest(urls)
        postForwardedOpenRequest(request, refreshToken: false)
        // Reuse the same request ID so an established primary deduplicates the
        // retry. Re-read the token as well: a new primary may have held the
        // lock while its token was still empty, partial, or replacing a stale
        // token from the previous primary.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self, self.isSecondary else { return }
            self.postForwardedOpenRequest(request, refreshToken: true)
        }
        activateExistingApplication()
        return request
    }

    /// Resolves the launch race where the old primary owns the lock while it is
    /// already terminating. The request is forwarded immediately, then this
    /// secondary polls the same descriptor for a finite period. If the lock is
    /// released, exactly one contender can promote itself and the original
    /// request is queued locally for the handler installed during primary setup.
    ///
    /// This method is synchronous by design so a composition root can decide
    /// whether to build the primary object graph. Callers must not schedule the
    /// secondary's forced exit until it returns.
    func resolveSecondaryLaunch(
        openURLs: [URL],
        takeoverTimeout: TimeInterval = defaultTakeoverTimeout,
        retryInterval: TimeInterval = defaultTakeoverRetryInterval
    ) throws -> SecondaryLaunchResolution {
        let request = forwardOpenRequest(openURLs)
        let timeout = Self.sanitizedTakeoverTimeout(takeoverTimeout)
        let interval = Self.sanitizedTakeoverRetryInterval(retryInterval)
        let start = Self.monotonicNow()
        let deadline = start + timeout
        var didRefreshTokenSynchronously = false

        stateLock.lock()
        switch state {
        case .primary:
            stateLock.unlock()
            return .becamePrimary(openURLs: request.urls)
        case .secondary:
            guard !isTakeoverInProgress else {
                stateLock.unlock()
                throw SingleInstanceCoordinatorError(operation: .acquireLock, code: EALREADY)
            }
            isTakeoverInProgress = true
            stateLock.unlock()
        case .idle, .released:
            stateLock.unlock()
            throw SingleInstanceCoordinatorError(operation: .acquireLock, code: EINVAL)
        }

        while true {
            stateLock.lock()
            guard case .secondary = state,
                  isTakeoverInProgress,
                  lockFileDescriptor >= 0 else {
                let becamePrimary: Bool
                if case .primary = state {
                    becamePrimary = true
                } else {
                    becamePrimary = false
                }
                isTakeoverInProgress = false
                stateLock.unlock()
                return becamePrimary
                    ? .becamePrimary(openURLs: request.urls)
                    : .forwardedToPrimary
            }

            let descriptor = lockFileDescriptor
            if systemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                let token = UUID().uuidString
                do {
                    try Self.writeHandoffToken(token, to: descriptor)
                } catch {
                    _ = systemFlock(descriptor, LOCK_UN)
                    isTakeoverInProgress = false
                    stateLock.unlock()
                    throw error
                }

                handoffToken = token
                state = .primary
                isTakeoverInProgress = false
                rememberRequestIDLocked(request.id)
                let handler = openRequestHandler
                if handler == nil, !request.urls.isEmpty {
                    enqueuePendingOpenRequestLocked(
                        OpenRequest(id: request.id, urls: request.urls)
                    )
                }
                stateLock.unlock()

                installObserver()
                activateCurrentApplication()
                if !request.urls.isEmpty {
                    handler?(request.urls)
                }
                return .becamePrimary(openURLs: request.urls)
            }

            let lockError = errno
            stateLock.unlock()
            guard lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EINTR else {
                finishTakeoverAttemptIfSecondary()
                throw SingleInstanceCoordinatorError(operation: .acquireLock, code: lockError)
            }

            let now = Self.monotonicNow()
            if !didRefreshTokenSynchronously, now - start >= 0.10 {
                didRefreshTokenSynchronously = true
                postForwardedOpenRequest(request, refreshToken: true)
            }
            guard now < deadline else {
                finishTakeoverAttemptIfSecondary()
                return .forwardedToPrimary
            }

            let sleepDuration = min(interval, max(0, deadline - now))
            if sleepDuration > 0 {
                usleep(useconds_t((sleepDuration * 1_000_000).rounded()))
            }
        }
    }

    /// Installs the primary-process consumer and drains requests that arrived
    /// before AppDelegate finished configuring its audio/open-file pipeline.
    func setOpenRequestHandler(_ handler: @escaping ([URL]) -> Void) {
        stateLock.lock()
        openRequestHandler = handler
        let pending = pendingOpenRequests
        pendingOpenRequests.removeAll(keepingCapacity: false)
        stateLock.unlock()

        for request in pending {
            handler(request.urls)
        }
    }

    func release() {
        stateLock.lock()
        let shouldUnlockDescriptor: Bool
        if case .primary = state {
            shouldUnlockDescriptor = true
        } else {
            shouldUnlockDescriptor = false
        }
        let observer = self.observer
        self.observer = nil
        let descriptor = lockFileDescriptor
        lockFileDescriptor = -1
        if case .released = state {
            stateLock.unlock()
            return
        }
        state = .released
        handoffToken = nil
        isTakeoverInProgress = false
        pendingOpenRequests.removeAll(keepingCapacity: false)
        openRequestHandler = nil
        stateLock.unlock()

        if let observer {
            transport.removeObserver(observer)
        }
        if descriptor >= 0 {
            if shouldUnlockDescriptor {
                _ = systemFlock(descriptor, LOCK_UN)
            }
            Darwin.close(descriptor)
        }
    }

    static func commandLineOpenURLs(
        arguments: [String],
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> [URL] {
        let urls: [URL] = arguments.dropFirst().compactMap { argument -> URL? in
            guard !argument.isEmpty, !argument.hasPrefix("-") else { return nil }
            let expanded = (argument as NSString).expandingTildeInPath
            if let url = URL(string: expanded), url.isFileURL {
                return url.standardizedFileURL
            }
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
            return currentDirectoryURL.appendingPathComponent(expanded).standardizedFileURL
        }
        return sanitizedPaths(urls.map(\.path)).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    private func installObserver() {
        let token = transport.addObserver(forName: notificationName) { [weak self] userInfo in
            self?.receive(userInfo: userInfo)
        }
        stateLock.lock()
        guard case .primary = state, observer == nil else {
            stateLock.unlock()
            transport.removeObserver(token)
            return
        }
        observer = token
        stateLock.unlock()
    }

    private func receive(userInfo: [AnyHashable: Any]?) {
        guard let requestID = userInfo?[Self.requestIDKey] as? String,
              requestID.utf8.count <= 64,
              UUID(uuidString: requestID) != nil,
              let paths = userInfo?[Self.pathsKey] as? [String],
              let suppliedToken = userInfo?[Self.handoffTokenKey] as? String
        else { return }

        stateLock.lock()
        guard case .primary = state,
              let handoffToken,
              suppliedToken == handoffToken else {
            stateLock.unlock()
            return
        }
        let sanitizedPaths = Self.sanitizedPaths(paths)
        guard sanitizedPaths.count == paths.count else {
            stateLock.unlock()
            return
        }
        guard rememberRequestIDLocked(requestID) else {
            stateLock.unlock()
            return
        }

        let urls = sanitizedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let handler = openRequestHandler
        if handler == nil, !urls.isEmpty {
            enqueuePendingOpenRequestLocked(OpenRequest(id: requestID, urls: urls))
        }
        stateLock.unlock()

        activateCurrentApplication()
        if !urls.isEmpty {
            handler?(urls)
        }
    }

    private var isSecondary: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .secondary = state { return true }
        return false
    }

    private func makeForwardedOpenRequest(_ urls: [URL]) -> ForwardedOpenRequest {
        let paths = Self.sanitizedPaths(urls.map { $0.standardizedFileURL.path })
        return ForwardedOpenRequest(
            id: UUID().uuidString,
            urls: paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        )
    }

    private func postForwardedOpenRequest(
        _ request: ForwardedOpenRequest,
        refreshToken: Bool
    ) {
        guard let token = currentHandoffToken(
            refreshFromDescriptor: refreshToken
        ) else { return }
        transport.post(
            name: notificationName,
            userInfo: Self.openRequestPayload(
                requestID: request.id,
                paths: request.urls.map(\.path),
                token: token
            )
        )
    }

    /// Must be called with `stateLock` held.
    @discardableResult
    private func rememberRequestIDLocked(_ requestID: String) -> Bool {
        guard rememberedRequestIDSet.insert(requestID).inserted else { return false }
        rememberedRequestIDs.append(requestID)
        if rememberedRequestIDs.count > Self.maximumRememberedRequestIDs {
            let removed = rememberedRequestIDs.removeFirst()
            rememberedRequestIDSet.remove(removed)
        }
        return true
    }

    /// Must be called with `stateLock` held.
    private func enqueuePendingOpenRequestLocked(_ request: OpenRequest) {
        if pendingOpenRequests.count >= Self.maximumPendingOpenRequests {
            pendingOpenRequests.removeFirst()
        }
        pendingOpenRequests.append(request)
    }

    private func finishTakeoverAttemptIfSecondary() {
        stateLock.lock()
        if case .secondary = state {
            isTakeoverInProgress = false
        }
        stateLock.unlock()
    }

    private func currentHandoffToken(refreshFromDescriptor: Bool) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .secondary = state else { return handoffToken }
        if refreshFromDescriptor, lockFileDescriptor >= 0,
           let refreshed = Self.readHandoffToken(from: lockFileDescriptor) {
            handoffToken = refreshed
        }
        return handoffToken
    }

    private static func sanitizedTakeoverTimeout(_ timeout: TimeInterval) -> TimeInterval {
        if timeout.isNaN || timeout == -.infinity { return 0 }
        if timeout == .infinity { return maximumTakeoverTimeout }
        return min(max(0, timeout), maximumTakeoverTimeout)
    }

    private static func sanitizedTakeoverRetryInterval(
        _ interval: TimeInterval
    ) -> TimeInterval {
        guard interval.isFinite, interval > 0 else {
            return defaultTakeoverRetryInterval
        }
        return min(max(0.001, interval), 0.10)
    }

    private static func monotonicNow() -> TimeInterval {
        let value = ProcessInfo.processInfo.systemUptime
        return value.isFinite ? value : 0
    }

    private static func openRequestPayload(
        requestID: String,
        paths: [String],
        token: String
    ) -> [AnyHashable: Any] {
        [
            requestIDKey: requestID,
            pathsKey: paths,
            handoffTokenKey: token,
        ]
    }

    private static func defaultLockFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SingleInstanceCoordinatorError(
                operation: .locateApplicationSupport,
                code: ENOENT
            )
        }
        return base
            .appendingPathComponent("MusicPlayer", isDirectory: true)
            .appendingPathComponent("single-writer.lock", isDirectory: false)
    }

    private static func preparePrivateDirectory(_ directory: URL) throws -> Int32 {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let descriptor = Darwin.open(
                directory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw SingleInstanceCoordinatorError(
                    operation: .prepareDirectory,
                    code: errno
                )
            }

            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                let failure = errno == 0 ? EINVAL : errno
                Darwin.close(descriptor)
                throw SingleInstanceCoordinatorError(
                    operation: .prepareDirectory,
                    code: failure
                )
            }
            guard fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
                let failure = errno
                Darwin.close(descriptor)
                throw SingleInstanceCoordinatorError(
                    operation: .prepareDirectory,
                    code: failure
                )
            }
            return descriptor
        } catch let error as SingleInstanceCoordinatorError {
            throw error
        } catch {
            throw SingleInstanceCoordinatorError(
                operation: .prepareDirectory,
                code: Int32((error as NSError).code)
            )
        }
    }

    private static func validateAndSecureLockFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            throw SingleInstanceCoordinatorError(
                operation: .validateLockFile,
                code: errno == 0 ? EINVAL : errno
            )
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SingleInstanceCoordinatorError(operation: .validateLockFile, code: errno)
        }
    }

    private static func writeHandoffToken(_ token: String, to descriptor: Int32) throws {
        let bytes = Array(token.utf8)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              !bytes.isEmpty, bytes.count <= 64,
              ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw SingleInstanceCoordinatorError(operation: .prepareHandoff, code: errno)
        }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { rawBuffer in
                Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SingleInstanceCoordinatorError(operation: .prepareHandoff, code: errno)
            }
            offset += count
        }
        guard fsync(descriptor) == 0 else {
            throw SingleInstanceCoordinatorError(operation: .prepareHandoff, code: errno)
        }
    }

    private static func readHandoffToken(from descriptor: Int32) -> String? {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= 64 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                pread(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += count
        }
        guard let token = String(bytes: bytes, encoding: .utf8),
              UUID(uuidString: token) != nil else { return nil }
        return token
    }

    /// A secondary can observe the lock after the primary has acquired it but
    /// while the new token is between truncate and fsync. Retry for at most
    /// 100 ms so launch-time file opens survive that publication window without
    /// turning application startup into an unbounded wait.
    private static func readHandoffTokenWithBoundedRetry(from descriptor: Int32) -> String? {
        for attempt in 0..<handoffTokenReadAttempts {
            if let token = readHandoffToken(from: descriptor) {
                return token
            }
            guard attempt + 1 < handoffTokenReadAttempts else { break }
            usleep(handoffTokenRetryDelayMicroseconds)
        }
        return nil
    }

    private static func sanitizedPaths(_ paths: [String]) -> [String] {
        var totalBytes = 0
        var result: [String] = []
        result.reserveCapacity(min(paths.count, maximumPathsPerRequest))
        for path in paths.prefix(maximumPathsPerRequest) {
            let originalByteCount = path.utf8.count
            guard path.hasPrefix("/"),
                  !path.utf8.contains(0),
                  originalByteCount > 0,
                  originalByteCount <= maximumPathBytes,
                  totalBytes <= maximumTotalPathBytes - originalByteCount else { continue }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let byteCount = standardized.utf8.count
            guard standardized.hasPrefix("/"),
                  byteCount > 0,
                  byteCount <= maximumPathBytes else { continue }
            totalBytes += originalByteCount
            result.append(standardized)
        }
        return result
    }

    private static func activateCurrent() {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func activateExisting() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != currentPID
        }
        _ = existing?.activate(options: [.activateAllWindows])
    }
}
