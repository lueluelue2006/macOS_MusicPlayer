import Darwin
import Foundation

/// Moves only positively identified files from abandoned persistence layouts
/// into a private, bounded quarantine. Unknown files and future schemas are
/// deliberately left in place.
struct LegacyPersistenceGovernor {
    enum SkipReason: Error, Equatable, Sendable {
        case unsafeFile
        case oversized
        case unrecognizedContent
        case directoryEntryLimitReached
        case quarantineCapacityReached
        case ioFailure
    }

    struct QuarantinedItem: Equatable, Sendable {
        let relativePath: String
        let quarantineFileName: String
        let byteCount: Int
    }

    struct SkippedItem: Equatable, Sendable {
        let relativePath: String
        let reason: SkipReason
    }

    struct Report: Equatable, Sendable {
        var quarantined: [QuarantinedItem] = []
        var skipped: [SkippedItem] = []
        var omittedItemCount = 0
    }

    private enum ContentRule {
        case legacyPlayback
        case legacyLibrary
        case obsoleteVolumeCache
        case legacyIPCPlainToken
        case legacyIPCTokenEnvelope
        case legacyIPCRegistration
        case lock
        case sandboxTemporary
    }

    private struct Candidate {
        let relativePath: String
        let maximumBytes: Int
        let rule: ContentRule
    }

    private final class OwnedDirectory {
        let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            Darwin.close(descriptor)
        }
    }

    private final class ValidatedFile {
        let data: Data
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
        let byteCount: Int

        init(data: Data, descriptor: Int32, info: stat) {
            self.data = data
            self.descriptor = descriptor
            device = info.st_dev
            inode = info.st_ino
            byteCount = Int(info.st_size)
        }

        deinit {
            Darwin.close(descriptor)
        }
    }

    private struct CandidateLocation {
        let parent: OwnedDirectory
        let name: String
    }

    private struct DirectoryListing {
        let names: [String]
        let reachedLimit: Bool
    }

    private enum DirectoryOpenResult {
        case ready(OwnedDirectory)
        case missing
        case unsafe
        case failure
    }

    private enum CandidateLocationResult {
        case ready(CandidateLocation)
        case missing
        case unsafe
        case failure
    }

    private enum CandidateReadResult {
        case success(ValidatedFile)
        case missing
        case failure(SkipReason)
    }

    private enum CapacityResult {
        case available(entries: Int, bytes: Int)
        case full
        case failure
    }

    private static let maximumDirectoryEntries = 512
    private static let maximumReportItems = 256
    private static let maximumRelativePathBytes = 16 * 1_024
    private static let maximumConfiguredQuarantineEntries = 512
    private static let maximumConfiguredQuarantineBytes = 512 * 1_024 * 1_024

    private let baseDirectory: URL
    private let quarantineDirectory: URL
    private let maximumQuarantineEntries: Int
    private let maximumQuarantineBytes: Int

    init(
        baseDirectory: URL,
        quarantineDirectory: URL? = nil,
        maximumQuarantineEntries: Int = 32,
        maximumQuarantineBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.quarantineDirectory = (
            quarantineDirectory
                ?? baseDirectory.appendingPathComponent("LegacyQuarantine", isDirectory: true)
        ).standardizedFileURL
        self.maximumQuarantineEntries = min(
            max(1, maximumQuarantineEntries),
            Self.maximumConfiguredQuarantineEntries
        )
        self.maximumQuarantineBytes = min(
            max(1, maximumQuarantineBytes),
            Self.maximumConfiguredQuarantineBytes
        )
    }

    @discardableResult
    static func runDefault() -> Report {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return Report()
        }
        let base = applicationSupport.appendingPathComponent(
            "MusicPlayer",
            isDirectory: true
        )
        return LegacyPersistenceGovernor(baseDirectory: base).run()
    }

    @discardableResult
    func run() -> Report {
        var report = Report()
        let root: OwnedDirectory
        switch openBaseDirectory() {
        case .ready(let directory):
            root = directory
        case .missing:
            return report
        case .unsafe:
            appendSkipped(".", reason: .unsafeFile, report: &report)
            return logged(report)
        case .failure:
            appendSkipped(".", reason: .ioFailure, report: &report)
            return logged(report)
        }

        for candidate in candidates(root: root, report: &report)
            .sorted(by: { $0.relativePath < $1.relativePath }) {
            inspectAndQuarantine(candidate, root: root, report: &report)
        }
        return logged(report)
    }

    private func logged(_ report: Report) -> Report {
        if !report.quarantined.isEmpty
            || !report.skipped.isEmpty
            || report.omittedItemCount > 0 {
            PersistenceLogger.log(
                "旧持久化治理完成：隔离 \(report.quarantined.count) 项，跳过 \(report.skipped.count) 项，省略 \(report.omittedItemCount) 项"
            )
        }
        return report
    }

    private func candidates(root: OwnedDirectory, report: inout Report) -> [Candidate] {
        var result = [
            Candidate(
                relativePath: "playback.json",
                maximumBytes: 2 * 1_024 * 1_024,
                rule: .legacyPlayback
            ),
            Candidate(
                relativePath: "playback.json.bak",
                maximumBytes: 2 * 1_024 * 1_024,
                rule: .legacyPlayback
            ),
            Candidate(
                relativePath: "State/library-v1.json",
                maximumBytes: 8 * 1_024 * 1_024,
                rule: .legacyLibrary
            ),
            Candidate(
                relativePath: "state-writer.lock",
                maximumBytes: 4_096,
                rule: .lock
            ),
            Candidate(
                relativePath: "volume-cache.json",
                maximumBytes: 16 * 1_024 * 1_024,
                rule: .obsoleteVolumeCache
            ),
            Candidate(
                relativePath: "IPC/token",
                maximumBytes: 4_096,
                rule: .legacyIPCPlainToken
            ),
            Candidate(
                relativePath: "IPC/token.json",
                maximumBytes: 64 * 1_024,
                rule: .legacyIPCTokenEnvelope
            ),
            Candidate(
                relativePath: "IPC/lock",
                maximumBytes: 4_096,
                rule: .lock
            ),
        ]

        if let listing = directoryListing(
            root: root,
            relativeDirectory: "",
            reportPath: ".",
            report: &report
        ) {
            result.append(contentsOf: listing.names.compactMap { name in
                guard name.hasPrefix("user-playlists.json.sb-"),
                      !name.dropFirst("user-playlists.json.sb-".count).isEmpty else {
                    return nil
                }
                return Candidate(
                    relativePath: name,
                    maximumBytes: 8 * 1_024 * 1_024,
                    rule: .sandboxTemporary
                )
            })
        }

        for relativeDirectory in ["IPC/registrations", "IPC/Instances"] {
            guard let listing = directoryListing(
                root: root,
                relativeDirectory: relativeDirectory,
                reportPath: relativeDirectory,
                report: &report
            ) else { continue }
            result.append(contentsOf: listing.names.compactMap { name in
                guard !name.hasPrefix("."),
                      URL(fileURLWithPath: name).pathExtension.lowercased() == "json" else {
                    return nil
                }
                return Candidate(
                    relativePath: "\(relativeDirectory)/\(name)",
                    maximumBytes: 128 * 1_024,
                    rule: .legacyIPCRegistration
                )
            })
        }
        return result
    }

    private func directoryListing(
        root: OwnedDirectory,
        relativeDirectory: String,
        reportPath: String,
        report: inout Report
    ) -> DirectoryListing? {
        let openResult: DirectoryOpenResult
        if relativeDirectory.isEmpty {
            openResult = duplicateDirectory(root)
        } else {
            openResult = openOwnedDirectory(relativePath: relativeDirectory, root: root)
        }

        switch openResult {
        case .ready(let directory):
            guard let listing = enumerate(directory, limit: Self.maximumDirectoryEntries) else {
                appendSkipped(reportPath, reason: .ioFailure, report: &report)
                return nil
            }
            if listing.reachedLimit {
                appendSkipped(
                    reportPath,
                    reason: .directoryEntryLimitReached,
                    report: &report
                )
            }
            return listing
        case .missing:
            return nil
        case .unsafe:
            appendSkipped(reportPath, reason: .unsafeFile, report: &report)
            return nil
        case .failure:
            appendSkipped(reportPath, reason: .ioFailure, report: &report)
            return nil
        }
    }

    private func inspectAndQuarantine(
        _ candidate: Candidate,
        root: OwnedDirectory,
        report: inout Report
    ) {
        let location: CandidateLocation
        switch candidateLocation(for: candidate.relativePath, root: root) {
        case .ready(let value):
            location = value
        case .missing:
            return
        case .unsafe:
            appendSkipped(candidate.relativePath, reason: .unsafeFile, report: &report)
            return
        case .failure:
            appendSkipped(candidate.relativePath, reason: .ioFailure, report: &report)
            return
        }

        let validated: ValidatedFile
        switch validateAndRead(
            parent: location.parent,
            name: location.name,
            maximumBytes: candidate.maximumBytes
        ) {
        case .success(let file):
            validated = file
        case .missing:
            return
        case .failure(let reason):
            appendSkipped(candidate.relativePath, reason: reason, report: &report)
            return
        }

        guard recognizes(validated.data, as: candidate.rule) else {
            appendSkipped(
                candidate.relativePath,
                reason: .unrecognizedContent,
                report: &report
            )
            return
        }

        let quarantine: OwnedDirectory
        switch prepareQuarantineDirectory(root: root) {
        case .ready(let directory):
            quarantine = directory
        case .unsafe:
            appendSkipped(candidate.relativePath, reason: .unsafeFile, report: &report)
            return
        case .missing, .failure:
            appendSkipped(candidate.relativePath, reason: .ioFailure, report: &report)
            return
        }

        switch quarantineCapacity(in: quarantine) {
        case .available(let entries, let bytes):
            guard entries < maximumQuarantineEntries,
                  validated.byteCount <= maximumQuarantineBytes - bytes else {
                appendSkipped(
                    candidate.relativePath,
                    reason: .quarantineCapacityReached,
                    report: &report
                )
                return
            }
        case .full:
            appendSkipped(
                candidate.relativePath,
                reason: .quarantineCapacityReached,
                report: &report
            )
            return
        case .failure:
            appendSkipped(candidate.relativePath, reason: .ioFailure, report: &report)
            return
        }

        guard sourceStillMatches(validated, at: location) else {
            appendSkipped(candidate.relativePath, reason: .unsafeFile, report: &report)
            return
        }

        guard let destinationName = unusedQuarantineName(
            for: candidate.relativePath,
            in: quarantine
        ) else {
            appendSkipped(candidate.relativePath, reason: .ioFailure, report: &report)
            return
        }

        let renameSucceeded = location.name.withCString { sourceName in
            destinationName.withCString { destinationName in
                renameatx_np(
                    location.parent.descriptor,
                    sourceName,
                    quarantine.descriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                ) == 0
            }
        }
        guard renameSucceeded else {
            appendSkipped(candidate.relativePath, reason: .ioFailure, report: &report)
            return
        }

        let modeUpdated = fchmod(validated.descriptor, mode_t(0o600)) == 0
        let fileSynchronized = fsync(validated.descriptor) == 0
        let quarantineSynchronized = synchronizeDirectory(quarantine)
        let sourceSynchronized = synchronizeDirectory(location.parent)
        let finalized = modeUpdated
            && fileSynchronized
            && quarantineSynchronized
            && sourceSynchronized

        guard finalized else {
            if rollbackRename(
                sourceName: location.name,
                sourceParent: location.parent,
                destinationName: destinationName,
                quarantine: quarantine
            ) {
                appendSkipped(candidate.relativePath, reason: .ioFailure, report: &report)
            } else {
                appendQuarantined(
                    candidate.relativePath,
                    destinationName: destinationName,
                    byteCount: validated.byteCount,
                    report: &report
                )
            }
            return
        }

        appendQuarantined(
            candidate.relativePath,
            destinationName: destinationName,
            byteCount: validated.byteCount,
            report: &report
        )
    }

    private func validateAndRead(
        parent: OwnedDirectory,
        name: String,
        maximumBytes: Int
    ) -> CandidateReadResult {
        let descriptor = name.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .missing }
            if isUnsafePathError(errno) { return .failure(.unsafeFile) }
            return .failure(.ioFailure)
        }

        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0 else {
            return .failure(.unsafeFile)
        }
        guard info.st_size <= maximumBytes else { return .failure(.oversized) }

        let byteCount = Int(info.st_size)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var offset = 0
        while offset < byteCount {
            let readCount = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    byteCount - offset
                )
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return .failure(.ioFailure)
            }
            guard readCount > 0 else { return .failure(.ioFailure) }
            offset += readCount
        }

        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              afterRead.st_dev == info.st_dev,
              afterRead.st_ino == info.st_ino,
              afterRead.st_size == info.st_size,
              (afterRead.st_mode & S_IFMT) == S_IFREG,
              afterRead.st_uid == geteuid(),
              afterRead.st_nlink == 1 else {
            return .failure(.unsafeFile)
        }

        shouldClose = false
        return .success(ValidatedFile(
            data: Data(bytes),
            descriptor: descriptor,
            info: afterRead
        ))
    }

    private func recognizes(_ data: Data, as rule: ContentRule) -> Bool {
        switch rule {
        case .lock, .sandboxTemporary:
            return true

        case .legacyIPCPlainToken:
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  (32...512).contains(text.utf8.count) else { return false }
            return Data(base64Encoded: text) != nil

        case .legacyPlayback:
            guard let object = jsonDictionary(data) else { return false }
            return object["formatID"] as? String == "musicplayer.playback"
                && integer(object["schemaVersion"]) == 1
                && object["payload"] is [String: Any]

        case .legacyLibrary:
            guard let object = jsonDictionary(data) else { return false }
            return object["playback"] is [String: Any]
                && object["playlists"] is [Any]
                && object["preferences"] is [String: Any]

        case .obsoleteVolumeCache:
            guard let object = jsonDictionary(data),
                  let version = integer(object["version"]) else { return false }
            // v4 is still consumed transactionally by VolumeAnalysisStore; a
            // future version must remain byte-for-byte in place.
            return version == 2 || version == 3

        case .legacyIPCTokenEnvelope:
            guard let object = jsonDictionary(data) else { return false }
            return integer(object["schemaVersion"]) == 1
                && object["createdAt"] is String
                && object["token"] is String

        case .legacyIPCRegistration:
            guard let object = jsonDictionary(data) else { return false }
            return integer(object["schemaVersion"]) == 1
                && object["instanceId"] is String
                && object["socketPath"] is String
                && integer(object["pid"]) != nil
        }
    }

    private func jsonDictionary(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return Int(number.doubleValue)
    }

    private func quarantineCapacity(in directory: OwnedDirectory) -> CapacityResult {
        guard let listing = enumerate(
            directory,
            limit: min(Self.maximumDirectoryEntries, maximumQuarantineEntries)
        ) else { return .failure }
        guard !listing.reachedLimit else { return .full }

        var totalBytes = 0
        var totalEntries = 0
        for name in listing.names {
            var info = stat()
            let inspected = name.withCString {
                fstatat(directory.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) == 0
            }
            guard inspected,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  info.st_size >= 0,
                  info.st_size <= Int64(Int.max) else {
                return .full
            }
            totalEntries += 1
            let size = Int(info.st_size)
            guard size <= maximumQuarantineBytes - totalBytes else { return .full }
            totalBytes += size
        }
        return .available(entries: totalEntries, bytes: totalBytes)
    }

    private func prepareQuarantineDirectory(root: OwnedDirectory) -> DirectoryOpenResult {
        guard let relativePath = relativePathInsideBase(for: quarantineDirectory),
              let components = safeRelativeComponents(relativePath),
              !components.isEmpty else {
            return .unsafe
        }

        guard case .ready(let duplicatedRoot) = duplicateDirectory(root) else {
            return .failure
        }
        var current = duplicatedRoot

        for component in components {
            var created = false
            var descriptor = component.withCString {
                Darwin.openat(
                    current.descriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                )
            }
            if descriptor < 0, errno == ENOENT {
                let made = component.withCString {
                    mkdirat(current.descriptor, $0, mode_t(0o700)) == 0
                }
                guard made, synchronizeDirectory(current) else { return .failure }
                created = true
                descriptor = component.withCString {
                    Darwin.openat(
                        current.descriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
            }
            guard descriptor >= 0 else {
                return isUnsafePathError(errno) ? .unsafe : .failure
            }

            let next = OwnedDirectory(descriptor: descriptor)
            guard isSafeOwnedDirectory(next) else { return .unsafe }
            if created, !synchronizeDirectory(next) { return .failure }
            current = next
        }

        guard fchmod(current.descriptor, mode_t(0o700)) == 0,
              synchronizeDirectory(current) else { return .failure }
        return .ready(current)
    }

    private func sourceStillMatches(
        _ validated: ValidatedFile,
        at location: CandidateLocation
    ) -> Bool {
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(validated.descriptor, &descriptorInfo) == 0 else { return false }
        let inspected = location.name.withCString {
            fstatat(
                location.parent.descriptor,
                $0,
                &pathInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }
        return inspected
            && descriptorInfo.st_dev == validated.device
            && descriptorInfo.st_ino == validated.inode
            && pathInfo.st_dev == validated.device
            && pathInfo.st_ino == validated.inode
            && (pathInfo.st_mode & S_IFMT) == S_IFREG
            && pathInfo.st_uid == geteuid()
            && pathInfo.st_nlink == 1
            && pathInfo.st_size == validated.byteCount
    }

    private func rollbackRename(
        sourceName: String,
        sourceParent: OwnedDirectory,
        destinationName: String,
        quarantine: OwnedDirectory
    ) -> Bool {
        let restored = destinationName.withCString { destinationName in
            sourceName.withCString { sourceName in
                renameatx_np(
                    quarantine.descriptor,
                    destinationName,
                    sourceParent.descriptor,
                    sourceName,
                    UInt32(RENAME_EXCL)
                ) == 0
            }
        }
        guard restored else { return false }
        let sourceSynchronized = synchronizeDirectory(sourceParent)
        let quarantineSynchronized = synchronizeDirectory(quarantine)
        return sourceSynchronized && quarantineSynchronized
    }

    private func unusedQuarantineName(
        for relativePath: String,
        in directory: OwnedDirectory
    ) -> String? {
        for _ in 0..<8 {
            let name = quarantineName(for: relativePath)
            var info = stat()
            let result = name.withCString {
                fstatat(directory.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0, errno == ENOENT { return name }
        }
        return nil
    }

    private func openBaseDirectory() -> DirectoryOpenResult {
        var cursor = baseDirectory
        var ownedComponents: [String] = []

        while true {
            var info = stat()
            guard lstat(cursor.path, &info) == 0 else {
                return errno == ENOENT ? .missing : .unsafe
            }

            if info.st_uid == geteuid() {
                guard (info.st_mode & S_IFMT) == S_IFDIR,
                      cursor.path != "/",
                      isSafePathComponent(cursor.lastPathComponent) else {
                    return .unsafe
                }
                ownedComponents.insert(cursor.lastPathComponent, at: 0)
                cursor.deleteLastPathComponent()
                continue
            }

            guard info.st_uid == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  !ownedComponents.isEmpty else {
                return .unsafe
            }

            let anchorDescriptor = Darwin.open(
                cursor.path,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
            guard anchorDescriptor >= 0 else { return .unsafe }
            var anchorInfo = stat()
            guard fstat(anchorDescriptor, &anchorInfo) == 0,
                  (anchorInfo.st_mode & S_IFMT) == S_IFDIR,
                  anchorInfo.st_uid == 0,
                  anchorInfo.st_dev == info.st_dev,
                  anchorInfo.st_ino == info.st_ino else {
                Darwin.close(anchorDescriptor)
                return .unsafe
            }

            var current = OwnedDirectory(descriptor: anchorDescriptor)
            for component in ownedComponents {
                let descriptor = component.withCString {
                    Darwin.openat(
                        current.descriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                guard descriptor >= 0 else {
                    return errno == ENOENT ? .missing : .unsafe
                }
                let next = OwnedDirectory(descriptor: descriptor)
                guard isSafeOwnedDirectory(next) else { return .unsafe }
                current = next
            }
            return .ready(current)
        }
    }

    private func candidateLocation(
        for relativePath: String,
        root: OwnedDirectory
    ) -> CandidateLocationResult {
        guard let components = safeRelativeComponents(relativePath),
              let name = components.last else { return .unsafe }
        let parentComponents = components.dropLast()
        if parentComponents.isEmpty {
            guard case .ready(let parent) = duplicateDirectory(root) else {
                return .failure
            }
            return .ready(CandidateLocation(parent: parent, name: name))
        }

        switch openOwnedDirectory(
            components: Array(parentComponents),
            root: root
        ) {
        case .ready(let parent):
            return .ready(CandidateLocation(parent: parent, name: name))
        case .missing:
            return .missing
        case .unsafe:
            return .unsafe
        case .failure:
            return .failure
        }
    }

    private func openOwnedDirectory(
        relativePath: String,
        root: OwnedDirectory
    ) -> DirectoryOpenResult {
        guard let components = safeRelativeComponents(relativePath) else { return .unsafe }
        return openOwnedDirectory(components: components, root: root)
    }

    private func openOwnedDirectory(
        components: [String],
        root: OwnedDirectory
    ) -> DirectoryOpenResult {
        guard case .ready(let duplicatedRoot) = duplicateDirectory(root) else {
            return .failure
        }
        var current = duplicatedRoot
        for component in components {
            let descriptor = component.withCString {
                Darwin.openat(
                    current.descriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else {
                if errno == ENOENT { return .missing }
                if isUnsafePathError(errno) { return .unsafe }
                return .failure
            }
            let next = OwnedDirectory(descriptor: descriptor)
            guard isSafeOwnedDirectory(next) else { return .unsafe }
            current = next
        }
        return .ready(current)
    }

    private func duplicateDirectory(_ directory: OwnedDirectory) -> DirectoryOpenResult {
        let descriptor = Darwin.dup(directory.descriptor)
        guard descriptor >= 0 else { return .failure }
        let duplicate = OwnedDirectory(descriptor: descriptor)
        guard isSafeOwnedDirectory(duplicate) else { return .unsafe }
        return .ready(duplicate)
    }

    private func isSafeOwnedDirectory(_ directory: OwnedDirectory) -> Bool {
        var info = stat()
        return fstat(directory.descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
    }

    private func enumerate(_ directory: OwnedDirectory, limit: Int) -> DirectoryListing? {
        let duplicatedDescriptor = Darwin.dup(directory.descriptor)
        guard duplicatedDescriptor >= 0 else { return nil }
        guard let stream = fdopendir(duplicatedDescriptor) else {
            Darwin.close(duplicatedDescriptor)
            return nil
        }
        defer { closedir(stream) }

        let boundedLimit = min(max(1, limit), Self.maximumDirectoryEntries)
        var names: [String] = []
        names.reserveCapacity(min(64, boundedLimit))
        var observedEntryCount = 0
        var reachedLimit = false

        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { return nil }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            observedEntryCount += 1
            if observedEntryCount > boundedLimit {
                reachedLimit = true
                break
            }
            guard isSafePathComponent(name) else { continue }
            names.append(name)
        }

        return DirectoryListing(names: names.sorted(), reachedLimit: reachedLimit)
    }

    private func safeRelativeComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath.utf8.count <= Self.maximumRelativePathBytes,
              !relativePath.utf8.contains(0) else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy(isSafePathComponent) else { return nil }
        return components
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.utf8.contains(0)
            && component.utf8.count <= Int(NAME_MAX)
    }

    private func relativePathInsideBase(for url: URL) -> String? {
        let basePath = baseDirectory.path
        let candidatePath = url.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        return String(candidatePath.dropFirst(prefix.count))
    }

    private func synchronizeDirectory(_ directory: OwnedDirectory) -> Bool {
        fsync(directory.descriptor) == 0
    }

    private func isUnsafePathError(_ value: Int32) -> Bool {
        value == ELOOP || value == ENOTDIR || value == EACCES || value == EPERM
    }

    private func appendQuarantined(
        _ relativePath: String,
        destinationName: String,
        byteCount: Int,
        report: inout Report
    ) {
        guard report.quarantined.count + report.skipped.count < Self.maximumReportItems else {
            incrementOmittedCount(in: &report)
            return
        }
        report.quarantined.append(.init(
            relativePath: relativePath,
            quarantineFileName: destinationName,
            byteCount: byteCount
        ))
    }

    private func appendSkipped(
        _ relativePath: String,
        reason: SkipReason,
        report: inout Report
    ) {
        guard report.quarantined.count + report.skipped.count < Self.maximumReportItems else {
            incrementOmittedCount(in: &report)
            return
        }
        report.skipped.append(.init(relativePath: relativePath, reason: reason))
    }

    private func incrementOmittedCount(in report: inout Report) {
        if report.omittedItemCount < Int.max {
            report.omittedItemCount += 1
        }
    }

    private func quarantineName(for relativePath: String) -> String {
        var safePath = ""
        for scalar in relativePath.unicodeScalars {
            let allowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "-"
                || scalar == "_"
            let piece = allowed ? String(scalar) : "_"
            guard safePath.utf8.count + piece.utf8.count <= 128 else { break }
            safePath += piece
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        return "\(timestamp)-\(safePath)-\(UUID().uuidString).legacy"
    }
}
