import Darwin
import Foundation

enum PersistenceEnvironmentError: Error, Equatable, LocalizedError, Sendable {
    case applicationSupportDirectoryUnavailable
    case cachesDirectoryUnavailable
    case isolatedUserDefaultsUnavailable
    case invalidDirectoryURL
    case unsafeDirectory
    case directoryCreationFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "Application Support directory is unavailable"
        case .cachesDirectoryUnavailable:
            return "Caches directory is unavailable"
        case .isolatedUserDefaultsUnavailable:
            return "An isolated UserDefaults suite could not be created"
        case .invalidDirectoryURL:
            return "The persistence directory must be an absolute file URL"
        case .unsafeDirectory:
            return "The persistence directory is not a safe, user-owned directory"
        case .directoryCreationFailed(let code):
            return "The persistence directory could not be created (errno \(code))"
        }
    }
}

/// Explicit roots and preferences domain for every persistent store.
///
/// Construct this value and inject it; do not hide it behind a process-wide
/// store singleton. `production()` is runtime-aware: XCTest and the built-in
/// regression harness receive one isolated temporary root and UserDefaults
/// suite for the lifetime of the process.
struct PersistenceEnvironment: @unchecked Sendable {
    static let applicationDirectoryName = "MusicPlayer"

    let applicationSupportURL: URL
    let cachesURL: URL
    let userDefaults: UserDefaults
    let isTesting: Bool

    init(
        applicationSupportURL: URL,
        cachesURL: URL,
        userDefaults: UserDefaults,
        isTesting: Bool
    ) {
        self.applicationSupportURL = applicationSupportURL.standardizedFileURL
        self.cachesURL = cachesURL.standardizedFileURL
        self.userDefaults = userDefaults
        self.isTesting = isTesting
    }

    /// Resolves the real per-user directories in production. Under XCTest or
    /// the opt-in regression harness it fails closed to a process-isolated
    /// temporary hierarchy and never returns the production preferences domain.
    static func production(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) throws -> PersistenceEnvironment {
        let testing = isTestingRuntime(
            environment: processInfo.environment,
            processName: processInfo.processName,
            hasXCTestRuntime: hasLoadedXCTestRuntime
        )

        if testing {
            // The system temporary URL commonly starts with `/var`, which is a
            // compatibility symlink on macOS. Resolve that trusted system URL
            // before appending any product-controlled component; subsequent
            // preparation rejects every symlink it encounters.
            let root = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "MusicPlayer-Persistence-\(processInfo.processIdentifier)-\(isolatedProcessID.uuidString)",
                    isDirectory: true
                )
            guard let defaults = UserDefaults(suiteName: isolatedDefaultsSuiteName(
                processIdentifier: processInfo.processIdentifier
            )) else {
                throw PersistenceEnvironmentError.isolatedUserDefaultsUnavailable
            }
            return PersistenceEnvironment(
                applicationSupportURL: root
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent(applicationDirectoryName, isDirectory: true),
                cachesURL: root
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent(applicationDirectoryName, isDirectory: true),
                userDefaults: defaults,
                isTesting: true
            )
        }

        guard let applicationSupportBase = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PersistenceEnvironmentError.applicationSupportDirectoryUnavailable
        }
        guard let cachesBase = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw PersistenceEnvironmentError.cachesDirectoryUnavailable
        }
        return PersistenceEnvironment(
            applicationSupportURL: applicationSupportBase.appendingPathComponent(
                applicationDirectoryName,
                isDirectory: true
            ),
            cachesURL: cachesBase.appendingPathComponent(
                applicationDirectoryName,
                isDirectory: true
            ),
            userDefaults: .standard,
            isTesting: false
        )
    }

    @discardableResult
    func prepareApplicationSupportDirectory() throws -> URL {
        try Self.ensureSecureDirectory(at: applicationSupportURL)
    }

    @discardableResult
    func prepareCachesDirectory() throws -> URL {
        try Self.ensureSecureDirectory(at: cachesURL)
    }

    func prepareDirectories() throws {
        _ = try prepareApplicationSupportDirectory()
        _ = try prepareCachesDirectory()
    }

    /// Walks from the trusted filesystem root one component at a time. Every
    /// lookup uses `openat(O_NOFOLLOW)`, so a symlink in any ancestor is
    /// rejected rather than followed by a whole-path `open(2)`.
    @discardableResult
    static func ensureSecureDirectory(at suppliedURL: URL) throws -> URL {
        let directory = suppliedURL.standardizedFileURL
        guard suppliedURL.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path != "/",
              !directory.path.utf8.contains(0) else {
            throw PersistenceEnvironmentError.invalidDirectoryURL
        }

        // Foundation intentionally preserves macOS' public `/var` spelling,
        // even after `resolvingSymlinksInPath()`.  Traversing that spelling
        // with O_NOFOLLOW correctly rejects its compatibility symlink, which
        // also made every XCTest temporary directory unusable.  Translate only
        // this OS-owned compatibility prefix before opening from `/`; the
        // resulting `/private/var` path is still checked component-by-component
        // with O_NOFOLLOW below, so product-controlled ancestors remain strict.
        let traversalPath = trustedPhysicalTraversalPath(for: directory.path)
        let components = Array(
            URL(fileURLWithPath: traversalPath, isDirectory: true)
                .pathComponents
                .dropFirst()
        )
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0)
              }) else {
            throw PersistenceEnvironmentError.invalidDirectoryURL
        }

        var currentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw PersistenceEnvironmentError.unsafeDirectory
        }
        defer { Darwin.close(currentDescriptor) }

        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            var wasCreated = false
            var childDescriptor = openDirectory(
                relativeTo: currentDescriptor,
                component: component
            )
            if childDescriptor < 0 {
                guard errno == ENOENT else {
                    throw PersistenceEnvironmentError.unsafeDirectory
                }
                try requireOwnedDirectoryDescriptor(currentDescriptor)
                if mkdirat(currentDescriptor, component, mode_t(0o700)) != 0 {
                    guard errno == EEXIST else {
                        throw PersistenceEnvironmentError.directoryCreationFailed(code: errno)
                    }
                } else {
                    wasCreated = true
                }
                childDescriptor = openDirectory(
                    relativeTo: currentDescriptor,
                    component: component
                )
                guard childDescriptor >= 0 else {
                    throw PersistenceEnvironmentError.unsafeDirectory
                }
            }

            do {
                try validateTraversedDirectoryDescriptor(
                    childDescriptor,
                    requiresCurrentUserOwnership: isFinal || wasCreated
                )
                if isFinal {
                    guard fchmod(childDescriptor, mode_t(0o700)) == 0,
                          fsync(childDescriptor) == 0 else {
                        throw PersistenceEnvironmentError.directoryCreationFailed(code: errno)
                    }
                }
                if wasCreated, fsync(currentDescriptor) != 0 {
                    throw PersistenceEnvironmentError.directoryCreationFailed(code: errno)
                }
            } catch {
                Darwin.close(childDescriptor)
                throw error
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = childDescriptor
        }

        return directory
    }

    /// `/var` is the documented macOS compatibility alias for `/private/var`.
    /// Do not generalize this to arbitrary symlink resolution: callers must
    /// still be rejected when any non-system ancestor is a symlink.
    private static func trustedPhysicalTraversalPath(for path: String) -> String {
        if path == "/var" {
            return "/private/var"
        }
        if path.hasPrefix("/var/") {
            return "/private" + path
        }
        return path
    }

    static func isTestingRuntime(
        environment: [String: String],
        processName: String,
        hasXCTestRuntime: Bool
    ) -> Bool {
        if environment["MUSICPLAYER_RUN_REGRESSION_TESTS"] == "1" {
            return true
        }
        if let configuration = environment["XCTestConfigurationFilePath"],
           !configuration.isEmpty {
            return true
        }
        if hasXCTestRuntime {
            return true
        }
        return processName.localizedCaseInsensitiveContains("xctest")
    }

    private static let isolatedProcessID = UUID()

    private static var hasLoadedXCTestRuntime: Bool {
        NSClassFromString("XCTest.XCTestCase") != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func isolatedDefaultsSuiteName(processIdentifier: Int32) -> String {
        "io.github.lueluelue2006.macosmusicplayer.tests.\(processIdentifier).\(isolatedProcessID.uuidString)"
    }

    private static func openDirectory(
        relativeTo parentDescriptor: Int32,
        component: String
    ) -> Int32 {
        component.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
        }
    }

    private static func validateTraversedDirectoryDescriptor(
        _ descriptor: Int32,
        requiresCurrentUserOwnership: Bool
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() || (!requiresCurrentUserOwnership && info.st_uid == 0) else {
            throw PersistenceEnvironmentError.unsafeDirectory
        }
    }

    private static func requireOwnedDirectoryDescriptor(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw PersistenceEnvironmentError.unsafeDirectory
        }
    }
}
