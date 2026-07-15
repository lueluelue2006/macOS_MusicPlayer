import Foundation

enum RecursiveImportScanner {

    // MARK: - Public API

    static func scan(
        urls: [URL],
        recursive: Bool,
        isCancelled: () -> Bool
    ) -> Result {
        var context = ScanContext()

        // Early cancellation check
        if isCancelled() {
            return context.buildResult(wasCancelled: true)
        }

        // Scan each root in order
        for rootURL in urls {
            let cancelled = scanRoot(rootURL, recursive: recursive, context: &context, isCancelled: isCancelled)
            if cancelled {
                return context.buildResult(wasCancelled: true)
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

    // MARK: - Private Implementation

    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"
    ]

    private struct ScanContext {
        var filesByCanonicalPath: [String: URL] = [:]
        var allSeenFilePaths: Set<String> = []
        var skippedItems: [SkippedItem] = []
        var unsupportedFormatCount: Int = 0
        var totalScanned: Int = 0
        var visitedDirectories: Set<String> = []

        mutating func recordFile(_ url: URL) {
            let canonical = PathKey.canonical(for: url)
            if filesByCanonicalPath[canonical] == nil {
                filesByCanonicalPath[canonical] = url
            }
        }

        mutating func recordSkipped(path: String, reason: SkipReason) {
            skippedItems.append(SkippedItem(path: path, reason: reason))
        }

        mutating func recordUnsupportedFormat() {
            unsupportedFormatCount += 1
        }

        mutating func incrementScanned() {
            totalScanned += 1
        }

        mutating func markDirectoryVisited(_ url: URL) {
            let canonical = PathKey.canonical(for: url)
            visitedDirectories.insert(canonical)
        }

        func isDirectoryVisited(_ url: URL) -> Bool {
            let canonical = PathKey.canonical(for: url)
            return visitedDirectories.contains(canonical)
        }

        mutating func markFileSeenIfNeeded(_ url: URL) -> Bool {
            let canonical = PathKey.canonical(for: url)
            if allSeenFilePaths.contains(canonical) {
                return true // Already seen
            }
            allSeenFilePaths.insert(canonical)
            return false
        }

        func buildResult(wasCancelled: Bool) -> Result {
            // Sort files by canonical path for stable ordering
            let sortedFiles = filesByCanonicalPath.keys.sorted().compactMap { filesByCanonicalPath[$0] }

            return Result(
                files: sortedFiles,
                skipped: skippedItems,
                unsupportedFormatCount: unsupportedFormatCount,
                totalScanned: totalScanned,
                wasCancelled: wasCancelled
            )
        }
    }

    /// Returns true if cancelled
    private static func scanRoot(
        _ url: URL,
        recursive: Bool,
        context: inout ScanContext,
        isCancelled: () -> Bool
    ) -> Bool {
        if isCancelled() {
            return true
        }

        let fileManager = FileManager.default

        // Check if URL exists and get its type
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            context.recordSkipped(path: url.path, reason: .unreadable)
            return false
        }

        // Check resource values for root
        guard let resourceValues = try? url.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isPackageKey, .isHiddenKey
        ]) else {
            context.recordSkipped(path: url.path, reason: .unreadable)
            return false
        }

        // Skip symbolic links at root level
        if resourceValues.isSymbolicLink == true {
            context.recordSkipped(path: url.path, reason: .symbolicLink)
            return false
        }

        // Skip packages at root level
        if resourceValues.isPackage == true {
            context.recordSkipped(path: url.path, reason: .package)
            return false
        }

        // Skip hidden at root level
        if resourceValues.isHidden == true {
            context.recordSkipped(path: url.path, reason: .hidden)
            return false
        }

        if isDirectory.boolValue {
            return scanDirectory(url, recursive: recursive, context: &context, isCancelled: isCancelled)
        } else {
            processFile(url, context: &context)
            return false
        }
    }

    /// Returns true if cancelled
    private static func scanDirectory(
        _ dirURL: URL,
        recursive: Bool,
        context: inout ScanContext,
        isCancelled: () -> Bool
    ) -> Bool {
        // Check if already visited (deduplication)
        if context.isDirectoryVisited(dirURL) {
            context.recordSkipped(path: dirURL.path, reason: .duplicate)
            return false
        }

        let fileManager = FileManager.default

        // Read child names by path, then rebuild logical URLs from the caller-provided
        // root so results preserve the caller's lexical path identity (URL-based
        // enumeration would physically canonicalize e.g. /var -> /private/var).
        guard let childNames = try? fileManager.contentsOfDirectory(atPath: dirURL.path) else {
            context.recordSkipped(path: dirURL.path, reason: .unreadable)
            return false
        }
        let contents = childNames.map { dirURL.appendingPathComponent($0) }

        // Mark this directory as visited
        context.markDirectoryVisited(dirURL)

        // Sort contents by canonical path for stable ordering
        let sortedContents = contents.sorted { url1, url2 in
            PathKey.canonical(for: url1) < PathKey.canonical(for: url2)
        }

        // Collect subdirectories to scan if recursive
        var subdirectories: [URL] = []

        // Process each item
        for url in sortedContents {
            if isCancelled() {
                return true
            }

            // Get resource values
            guard let resourceValues = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey
            ]) else {
                continue
            }

            // Skip symbolic links
            if resourceValues.isSymbolicLink == true {
                context.recordSkipped(path: url.path, reason: .symbolicLink)
                continue
            }

            // Skip packages (should already be filtered by options, but be defensive)
            if resourceValues.isPackage == true {
                context.recordSkipped(path: url.path, reason: .package)
                continue
            }

            // Skip hidden items (should already be filtered, but be defensive)
            if resourceValues.isHidden == true {
                context.recordSkipped(path: url.path, reason: .hidden)
                continue
            }

            // Handle directories
            if resourceValues.isDirectory == true {
                if recursive {
                    subdirectories.append(url)
                }
                // For non-recursive, we don't add subdirectories to the list
                continue
            }

            // Process regular files
            processFile(url, context: &context)
        }

        // Recursively scan subdirectories if requested
        if recursive {
            for subdir in subdirectories {
                let cancelled = scanDirectory(subdir, recursive: recursive, context: &context, isCancelled: isCancelled)
                if cancelled {
                    return true
                }
            }
        }

        return false
    }

    private static func processFile(_ url: URL, context: inout ScanContext) {
        // Increment total scanned count for visible non-symlink files
        context.incrementScanned()

        // Check if already seen (deduplication across all examined files)
        let isDuplicate = context.markFileSeenIfNeeded(url)
        if isDuplicate {
            context.recordSkipped(path: url.path, reason: .duplicate)
            return
        }

        // Check extension (case-insensitive)
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            context.recordUnsupportedFormat()
            return
        }

        // Check readability
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            context.recordSkipped(path: url.path, reason: .unreadable)
            return
        }

        // Check for disguised non-audio files
        if let _ = AudioFileSniffer.nonAudioReasonIfClearlyText(at: url) {
            context.recordSkipped(path: url.path, reason: .obviousNonAudio)
            return
        }

        // Accept the file
        context.recordFile(url)
    }
}
