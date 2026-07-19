import Foundation

/// Protocol for tracking signature capture operations (primarily for testing)
protocol SignatureCaptureCounter: Sendable {
    func recordCapture(path: String) async
}

/// Service for capturing file signatures with bounded concurrency
actor SignatureCaptureService {
    private struct InFlightCapture {
        let id: UUID
        let task: Task<FileSignature?, Never>
    }

    private let fileIdentity: FileIdentity
    private let counter: (any SignatureCaptureCounter)?
    private var inFlightByPath: [String: InFlightCapture] = [:]

    init(fileIdentity: FileIdentity = FileIdentity(), counter: (any SignatureCaptureCounter)? = nil) {
        self.fileIdentity = fileIdentity
        self.counter = counter
    }

    /// Captures signature for a single URL (non-throwing, returns nil on failure)
    func captureSignature(for url: URL) async -> FileSignature? {
        let path = PathKey.canonical(for: url)
        if let existing = inFlightByPath[path] {
            return await existing.task.value
        }

        let captureID = UUID()
        let task = Task<FileSignature?, Never> { [fileIdentity, counter] in
            guard !Task.isCancelled else { return nil }
            await counter?.recordCapture(path: path)
            guard !Task.isCancelled else { return nil }
            return try? await fileIdentity.captureSignature(for: url)
        }
        inFlightByPath[path] = InFlightCapture(id: captureID, task: task)

        let result = await task.value
        if inFlightByPath[path]?.id == captureID {
            inFlightByPath.removeValue(forKey: path)
        }
        return result
    }

    /// Captures signatures for multiple URLs with bounded concurrency
    /// - Parameters:
    ///   - urls: URLs to capture signatures for
    ///   - maxConcurrent: Maximum concurrent captures
    /// - Returns: Dictionary mapping canonical path to signature (nil on failure)
    func captureSignatures(for urls: [URL], maxConcurrent: Int = 2) async -> [String: FileSignature] {
        guard !urls.isEmpty else { return [:] }

        // Deduplicate URLs by canonical path to avoid redundant disk reads
        var uniqueURLs: [URL] = []
        var seenKeys = Set<String>()
        for url in urls {
            let key = PathKey.canonical(for: url)
            if seenKeys.insert(key).inserted {
                uniqueURLs.append(url)
            }
        }

        let results = await BoundedWorkerPool.map(items: uniqueURLs, maxConcurrent: maxConcurrent) { [weak self] url in
            let path = PathKey.canonical(for: url)
            let signature = await self?.captureSignature(for: url)
            return (path, signature)
        }

        var signatures: [String: FileSignature] = [:]
        signatures.reserveCapacity(results.count)
        for (path, signature) in results {
            if let sig = signature {
                signatures[path] = sig
            }
        }
        return signatures
    }

    /// Cancels shared enrichment tasks without waiting for a slow filesystem.
    /// Individual FileManager calls are not cancellable, but their late results
    /// are detached from the coordinator and will never be merged after quit.
    func cancelAll() {
        let captures = Array(inFlightByPath.values)
        inFlightByPath.removeAll()
        for capture in captures {
            capture.task.cancel()
        }
    }
}
