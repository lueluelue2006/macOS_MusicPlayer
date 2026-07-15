import Foundation

/// Protocol for tracking signature capture operations (primarily for testing)
protocol SignatureCaptureCounter: Sendable {
    func recordCapture(path: String) async
}

/// Service for capturing file signatures with bounded concurrency
actor SignatureCaptureService {
    private let fileIdentity: FileIdentity
    private let counter: (any SignatureCaptureCounter)?

    init(fileIdentity: FileIdentity = FileIdentity(), counter: (any SignatureCaptureCounter)? = nil) {
        self.fileIdentity = fileIdentity
        self.counter = counter
    }

    /// Captures signature for a single URL (non-throwing, returns nil on failure)
    func captureSignature(for url: URL) async -> FileSignature? {
        let path = PathKey.canonical(for: url)
        await counter?.recordCapture(path: path)
        return try? await fileIdentity.captureSignature(for: url)
    }

    /// Captures signatures for multiple URLs with bounded concurrency
    /// - Parameters:
    ///   - urls: URLs to capture signatures for
    ///   - maxConcurrent: Maximum concurrent captures
    /// - Returns: Dictionary mapping canonical path to signature (nil on failure)
    func captureSignatures(for urls: [URL], maxConcurrent: Int = 4) async -> [String: FileSignature] {
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

        let results = await BoundedWorkerPool.map(items: uniqueURLs, maxConcurrent: maxConcurrent) { [fileIdentity, counter] url in
            let path = PathKey.canonical(for: url)
            // Record capture attempt before actual capture
            await counter?.recordCapture(path: path)
            let signature = try? await fileIdentity.captureSignature(for: url)
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
}
