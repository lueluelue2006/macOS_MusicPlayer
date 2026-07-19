import Darwin
import Foundation

enum RecursiveImportScanner {

    // MARK: - Public API

    /// Resource ceilings keep a malformed or unexpectedly large folder from turning
    /// one import operation into an unbounded in-memory index of the filesystem.
    struct Limits: Equatable {
        static let production = Limits()

        let maximumRootURLs: Int
        let maximumDirectoryEntries: Int
        let maximumDiscoveredItems: Int
        let maximumScannedFiles: Int
        let maximumAcceptedFiles: Int
        let maximumTrackedFileIdentities: Int
        let maximumVisitedDirectories: Int
        let maximumPendingDirectories: Int
        let maximumSkippedItems: Int

        init(
            maximumRootURLs: Int = 4_096,
            maximumDirectoryEntries: Int = 50_000,
            maximumDiscoveredItems: Int = 200_000,
            maximumScannedFiles: Int = 100_000,
            maximumAcceptedFiles: Int = 50_000,
            maximumTrackedFileIdentities: Int = 100_000,
            maximumVisitedDirectories: Int = 20_000,
            maximumPendingDirectories: Int = 10_000,
            maximumSkippedItems: Int = 2_000
        ) {
            self.maximumRootURLs = max(1, maximumRootURLs)
            self.maximumDirectoryEntries = max(1, maximumDirectoryEntries)
            self.maximumDiscoveredItems = max(1, maximumDiscoveredItems)
            self.maximumScannedFiles = max(1, maximumScannedFiles)
            self.maximumAcceptedFiles = max(1, maximumAcceptedFiles)
            self.maximumTrackedFileIdentities = max(1, maximumTrackedFileIdentities)
            self.maximumVisitedDirectories = max(1, maximumVisitedDirectories)
            self.maximumPendingDirectories = max(1, maximumPendingDirectories)
            self.maximumSkippedItems = max(0, maximumSkippedItems)
        }
    }

    static func scan(
        urls: [URL],
        recursive: Bool,
        isCancelled: () -> Bool,
        limits: Limits = .production
    ) -> Result {
        var context = ScanContext(limits: limits)

        if isCancelled() {
            return context.buildResult(wasCancelled: true)
        }

        for (index, rootURL) in urls.enumerated() {
            if isCancelled() {
                return context.buildResult(wasCancelled: true)
            }
            guard index < limits.maximumRootURLs else {
                context.stop(with: .rootURLLimitReached(limit: limits.maximumRootURLs))
                break
            }

            switch scanRoot(
                rootURL,
                recursive: recursive,
                context: &context,
                isCancelled: isCancelled
            ) {
            case .finished:
                continue
            case .cancelled:
                return context.buildResult(wasCancelled: true)
            case .stopped:
                return context.buildResult(wasCancelled: false)
            }
        }

        return context.buildResult(wasCancelled: false)
    }

    // MARK: - Result Types

    struct Result {
        let files: [URL]
        let skipped: [SkippedItem]
        let unsupportedFormatCount: Int
        let totalScanned: Int
        let wasCancelled: Bool
        let stopReason: StopReason?
        let totalSkippedItemCount: Int
        let omittedSkippedItemCount: Int
        let totalDiscoveredItemCount: Int
        let trackedFileIdentityCount: Int
        let visitedDirectoryCount: Int
        let peakPendingDirectoryCount: Int

        var wasTruncated: Bool { stopReason != nil }
    }

    struct SkippedItem {
        let path: String
        let reason: SkipReason
    }

    enum SkipReason: Equatable {
        case symbolicLink
        case obviousNonAudio
        case unreadable
        case duplicate
        case hidden
        case package
    }

    enum StopReason: Equatable {
        case rootURLLimitReached(limit: Int)
        case directoryEntryLimitReached(path: String, limit: Int)
        case discoveredItemLimitReached(limit: Int)
        case scannedFileLimitReached(limit: Int)
        case acceptedFileLimitReached(limit: Int)
        case trackedFileIdentityLimitReached(limit: Int)
        case visitedDirectoryLimitReached(limit: Int)
        case pendingDirectoryLimitReached(limit: Int)
    }

    // MARK: - Private Implementation

    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"
    ]

    private enum ScanControl {
        case finished
        case cancelled
        case stopped
    }

    private enum DirectoryReadResult {
        case names([String])
        case cancelled
        case entryLimitReached
        case unreadable
    }

    private struct ScanContext {
        let limits: Limits
        var filesByCanonicalPath: [String: URL] = [:]
        var seenFilePaths: Set<String> = []
        var skippedItems: [SkippedItem] = []
        var unsupportedFormatCount = 0
        var totalScanned = 0
        var totalSkippedItemCount = 0
        var totalDiscoveredItemCount = 0
        var visitedDirectories: Set<String> = []
        var peakPendingDirectoryCount = 0
        var stopReason: StopReason?

        mutating func stop(with reason: StopReason) {
            if stopReason == nil {
                stopReason = reason
            }
        }

        mutating func recordSkipped(path: String, reason: SkipReason) {
            totalSkippedItemCount += 1
            guard skippedItems.count < limits.maximumSkippedItems else { return }
            skippedItems.append(SkippedItem(path: path, reason: reason))
        }

        mutating func markDirectoryVisited(_ url: URL) -> Bool {
            let canonical = PathKey.canonical(for: url)
            if visitedDirectories.contains(canonical) {
                return false
            }
            guard visitedDirectories.count < limits.maximumVisitedDirectories else {
                stop(with: .visitedDirectoryLimitReached(limit: limits.maximumVisitedDirectories))
                return false
            }
            visitedDirectories.insert(canonical)
            return true
        }

        func buildResult(wasCancelled: Bool) -> Result {
            // Accepted files are capped, so this final ordering pass is bounded.
            let sortedFiles = filesByCanonicalPath.keys.sorted().compactMap { filesByCanonicalPath[$0] }
            return Result(
                files: sortedFiles,
                skipped: skippedItems,
                unsupportedFormatCount: unsupportedFormatCount,
                totalScanned: totalScanned,
                wasCancelled: wasCancelled,
                stopReason: stopReason,
                totalSkippedItemCount: totalSkippedItemCount,
                omittedSkippedItemCount: totalSkippedItemCount - skippedItems.count,
                totalDiscoveredItemCount: totalDiscoveredItemCount,
                trackedFileIdentityCount: seenFilePaths.count,
                visitedDirectoryCount: visitedDirectories.count,
                peakPendingDirectoryCount: peakPendingDirectoryCount
            )
        }
    }

    /// A compacting FIFO releases processed URLs instead of retaining every
    /// discovered subdirectory for the lifetime of a large scan.
    private struct DirectoryQueue {
        private var storage: [URL?] = []
        private var head = 0

        var count: Int { storage.count - head }

        mutating func append(_ url: URL, limit: Int) -> Bool {
            guard count < limit else { return false }
            storage.append(url)
            return true
        }

        mutating func popFirst() -> URL? {
            guard head < storage.count else { return nil }
            let result = storage[head]
            storage[head] = nil
            head += 1

            if head >= 512, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return result
        }
    }

    private static func scanRoot(
        _ url: URL,
        recursive: Bool,
        context: inout ScanContext,
        isCancelled: () -> Bool
    ) -> ScanControl {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            context.recordSkipped(path: url.path, reason: .unreadable)
            return .finished
        }

        guard let resourceValues = try? url.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isPackageKey, .isHiddenKey
        ]) else {
            context.recordSkipped(path: url.path, reason: .unreadable)
            return .finished
        }

        if resourceValues.isSymbolicLink == true {
            context.recordSkipped(path: url.path, reason: .symbolicLink)
            return .finished
        }
        if resourceValues.isPackage == true {
            context.recordSkipped(path: url.path, reason: .package)
            return .finished
        }
        if resourceValues.isHidden == true {
            context.recordSkipped(path: url.path, reason: .hidden)
            return .finished
        }

        if isDirectory.boolValue {
            return scanDirectoryTree(
                url,
                recursive: recursive,
                context: &context,
                isCancelled: isCancelled
            )
        }
        return processFile(url, context: &context)
    }

    private static func scanDirectoryTree(
        _ rootURL: URL,
        recursive: Bool,
        context: inout ScanContext,
        isCancelled: () -> Bool
    ) -> ScanControl {
        var pending = DirectoryQueue()
        guard pending.append(rootURL, limit: context.limits.maximumPendingDirectories) else {
            context.stop(with: .pendingDirectoryLimitReached(limit: context.limits.maximumPendingDirectories))
            return .stopped
        }
        context.peakPendingDirectoryCount = 1

        while let directoryURL = pending.popFirst() {
            if isCancelled() { return .cancelled }

            let canonical = PathKey.canonical(for: directoryURL)
            if context.visitedDirectories.contains(canonical) {
                context.recordSkipped(path: directoryURL.path, reason: .duplicate)
                continue
            }
            guard context.markDirectoryVisited(directoryURL) else {
                return context.stopReason == nil ? .finished : .stopped
            }

            switch readSortedChildNames(
                at: directoryURL,
                maximumEntries: context.limits.maximumDirectoryEntries,
                isCancelled: isCancelled
            ) {
            case let .names(childNames):
                for childName in childNames {
                    if isCancelled() { return .cancelled }
                    guard context.totalDiscoveredItemCount < context.limits.maximumDiscoveredItems else {
                        context.stop(with: .discoveredItemLimitReached(limit: context.limits.maximumDiscoveredItems))
                        return .stopped
                    }
                    context.totalDiscoveredItemCount += 1

                    let url = directoryURL.appendingPathComponent(childName, isDirectory: false)
                    guard let values = try? url.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey
                    ]) else {
                        context.recordSkipped(path: url.path, reason: .unreadable)
                        continue
                    }

                    if values.isSymbolicLink == true {
                        context.recordSkipped(path: url.path, reason: .symbolicLink)
                        continue
                    }
                    if values.isPackage == true {
                        context.recordSkipped(path: url.path, reason: .package)
                        continue
                    }
                    if values.isHidden == true {
                        context.recordSkipped(path: url.path, reason: .hidden)
                        continue
                    }

                    if values.isDirectory == true {
                        guard recursive else { continue }
                        guard pending.append(url, limit: context.limits.maximumPendingDirectories) else {
                            context.stop(with: .pendingDirectoryLimitReached(limit: context.limits.maximumPendingDirectories))
                            return .stopped
                        }
                        context.peakPendingDirectoryCount = max(context.peakPendingDirectoryCount, pending.count)
                        continue
                    }

                    switch processFile(url, context: &context) {
                    case .finished:
                        continue
                    case .cancelled:
                        return .cancelled
                    case .stopped:
                        return .stopped
                    }
                }

            case .cancelled:
                return .cancelled
            case .entryLimitReached:
                context.stop(with: .directoryEntryLimitReached(
                    path: directoryURL.path,
                    limit: context.limits.maximumDirectoryEntries
                ))
                return .stopped
            case .unreadable:
                context.recordSkipped(path: directoryURL.path, reason: .unreadable)
            }
        }

        return .finished
    }

    /// Uses `readdir` rather than `contentsOfDirectory`, so the OS does not first
    /// materialize an unbounded array. The bounded name buffer is sorted in place
    /// to retain deterministic traversal and lexical URL identity.
    private static func readSortedChildNames(
        at directoryURL: URL,
        maximumEntries: Int,
        isCancelled: () -> Bool
    ) -> DirectoryReadResult {
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return .unreadable }

        guard let directory = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return .unreadable
        }
        defer { closedir(directory) }

        var names: [String] = []
        names.reserveCapacity(min(maximumEntries, 512))
        var entriesRead = 0

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { return .unreadable }
                break
            }

            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            entriesRead += 1
            if entriesRead.isMultiple(of: 64), isCancelled() {
                return .cancelled
            }
            guard names.count < maximumEntries else {
                return .entryLimitReached
            }
            names.append(name)
        }

        names.sort()
        return .names(names)
    }

    private static func processFile(_ url: URL, context: inout ScanContext) -> ScanControl {
        guard context.totalScanned < context.limits.maximumScannedFiles else {
            context.stop(with: .scannedFileLimitReached(limit: context.limits.maximumScannedFiles))
            return .stopped
        }
        context.totalScanned += 1

        let canonical = PathKey.canonical(for: url)
        if context.seenFilePaths.contains(canonical) {
            context.recordSkipped(path: url.path, reason: .duplicate)
            return .finished
        }
        guard context.seenFilePaths.count < context.limits.maximumTrackedFileIdentities else {
            context.stop(with: .trackedFileIdentityLimitReached(
                limit: context.limits.maximumTrackedFileIdentities
            ))
            return .stopped
        }
        context.seenFilePaths.insert(canonical)

        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            context.unsupportedFormatCount += 1
            return .finished
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            context.recordSkipped(path: url.path, reason: .unreadable)
            return .finished
        }

        if AudioFileSniffer.nonAudioReasonIfClearlyText(at: url) != nil {
            context.recordSkipped(path: url.path, reason: .obviousNonAudio)
            return .finished
        }

        guard context.filesByCanonicalPath.count < context.limits.maximumAcceptedFiles else {
            context.stop(with: .acceptedFileLimitReached(limit: context.limits.maximumAcceptedFiles))
            return .stopped
        }
        context.filesByCanonicalPath[canonical] = url
        return .finished
    }
}
