import Foundation

/// Protocol for tracking signature capture operations (primarily for testing).
protocol SignatureCaptureCounter: Sendable {
    func recordCapture(path: String) async
}

struct SignatureCaptureServiceDiagnostics: Sendable, Equatable {
    let activeCaptureCount: Int
    let peakActiveCaptureCount: Int
    let pendingCaptureCount: Int
    let inFlightPathCount: Int
    let rejectedForCapacityCount: Int
}

private final class SignatureCaptureCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: FileSignature??
    private var waiters: [CheckedContinuation<FileSignature?, Never>] = []

    func value() async -> FileSignature? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func resolve(_ result: FileSignature?) {
        let pendingWaiters: [CheckedContinuation<FileSignature?, Never>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = .some(result)
        pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in pendingWaiters {
            waiter.resume(returning: result)
        }
    }
}

/// Process-local signature capture service with one global bounded pump.
/// Callers never create per-batch worker pools: only the two active filesystem
/// Tasks exist, while duplicate paths share one completion.
actor SignatureCaptureService {
    private struct InFlightCapture {
        let id: UUID
        let completion: SignatureCaptureCompletion
    }

    private struct PendingCapture {
        let id: UUID
        let path: String
        let url: URL
        let completion: SignatureCaptureCompletion
    }

    private let fileIdentity: FileIdentity
    private let counter: (any SignatureCaptureCounter)?
    private let maximumConcurrentCaptures: Int
    private let maximumPendingCaptures: Int

    private var inFlightByPath: [String: InFlightCapture] = [:]
    private var pendingCaptures: [PendingCapture] = []
    private var pendingCaptureHead = 0
    private var activeTasksByID: [UUID: Task<Void, Never>] = [:]
    private var peakActiveCaptureCount = 0
    private var rejectedForCapacityCount = 0

    init(
        fileIdentity: FileIdentity = FileIdentity(),
        counter: (any SignatureCaptureCounter)? = nil,
        maximumConcurrentCaptures: Int = 2,
        maximumPendingCaptures: Int = 512
    ) {
        self.fileIdentity = fileIdentity
        self.counter = counter
        self.maximumConcurrentCaptures = min(2, max(1, maximumConcurrentCaptures))
        self.maximumPendingCaptures = max(1, maximumPendingCaptures)
    }

    /// Captures one signature without throwing. Work for a canonical path is
    /// shared even when it arrives from queue import and playlist enrichment at
    /// the same time.
    func captureSignature(for url: URL) async -> FileSignature? {
        let path = PathKey.canonical(for: url)
        if let existing = inFlightByPath[path] {
            return await existing.completion.value()
        }

        guard pendingCount < maximumPendingCaptures else {
            rejectedForCapacityCount += 1
            return nil
        }

        let id = UUID()
        let completion = SignatureCaptureCompletion()
        inFlightByPath[path] = InFlightCapture(id: id, completion: completion)
        pendingCaptures.append(PendingCapture(
            id: id,
            path: path,
            url: url,
            completion: completion
        ))
        pump()
        return await completion.value()
    }

    /// Batch compatibility API. It deliberately iterates serially; global
    /// concurrency belongs to this service's pump and the coordinator's chunk
    /// scheduler, never to each individual batch.
    func captureSignatures(
        for urls: [URL],
        maxConcurrent _: Int = 2
    ) async -> [String: FileSignature] {
        guard !urls.isEmpty else { return [:] }

        var uniqueURLs: [(path: String, url: URL)] = []
        uniqueURLs.reserveCapacity(urls.count)
        var seenKeys = Set<String>()
        seenKeys.reserveCapacity(urls.count)
        for url in urls {
            let path = PathKey.canonical(for: url)
            if seenKeys.insert(path).inserted {
                uniqueURLs.append((path, url))
            }
        }

        var signatures: [String: FileSignature] = [:]
        signatures.reserveCapacity(uniqueURLs.count)
        for item in uniqueURLs {
            guard !Task.isCancelled else { break }
            if let signature = await captureSignature(for: item.url) {
                signatures[item.path] = signature
            }
        }
        return signatures
    }

    func diagnostics() -> SignatureCaptureServiceDiagnostics {
        SignatureCaptureServiceDiagnostics(
            activeCaptureCount: activeTasksByID.count,
            peakActiveCaptureCount: peakActiveCaptureCount,
            pendingCaptureCount: pendingCount,
            inFlightPathCount: inFlightByPath.count,
            rejectedForCapacityCount: rejectedForCapacityCount
        )
    }

    /// Cancels queued and active work without awaiting filesystem calls. Late
    /// FileIdentity results are ignored because their work IDs are no longer
    /// registered, while every caller is resumed immediately with nil.
    func cancelAll() {
        let tasks = Array(activeTasksByID.values)
        let completions = inFlightByPath.values.map(\.completion)

        activeTasksByID.removeAll(keepingCapacity: false)
        pendingCaptures.removeAll(keepingCapacity: false)
        pendingCaptureHead = 0
        inFlightByPath.removeAll(keepingCapacity: false)

        for task in tasks {
            task.cancel()
        }
        for completion in completions {
            completion.resolve(nil)
        }
    }

    private var pendingCount: Int {
        max(0, pendingCaptures.count - pendingCaptureHead)
    }

    private func pump() {
        while activeTasksByID.count < maximumConcurrentCaptures,
              let capture = takeNextPendingCapture() {
            let fileIdentity = self.fileIdentity
            let counter = self.counter
            let task = Task { [weak self] in
                let signature: FileSignature?
                if Task.isCancelled {
                    signature = nil
                } else {
                    await counter?.recordCapture(path: capture.path)
                    if Task.isCancelled {
                        signature = nil
                    } else {
                        signature = try? await fileIdentity.captureSignature(for: capture.url)
                    }
                }
                await self?.finish(capture: capture, signature: signature)
            }
            activeTasksByID[capture.id] = task
            peakActiveCaptureCount = max(peakActiveCaptureCount, activeTasksByID.count)
        }
    }

    private func takeNextPendingCapture() -> PendingCapture? {
        guard pendingCaptureHead < pendingCaptures.count else {
            pendingCaptures.removeAll(keepingCapacity: true)
            pendingCaptureHead = 0
            return nil
        }
        let capture = pendingCaptures[pendingCaptureHead]
        pendingCaptureHead += 1
        if pendingCaptureHead == pendingCaptures.count {
            pendingCaptures.removeAll(keepingCapacity: true)
            pendingCaptureHead = 0
        } else if pendingCaptureHead > 64,
                  pendingCaptureHead * 2 > pendingCaptures.count {
            pendingCaptures.removeFirst(pendingCaptureHead)
            pendingCaptureHead = 0
        }
        return capture
    }

    private func finish(capture: PendingCapture, signature: FileSignature?) {
        guard activeTasksByID.removeValue(forKey: capture.id) != nil else { return }
        if inFlightByPath[capture.path]?.id == capture.id {
            inFlightByPath.removeValue(forKey: capture.path)
            capture.completion.resolve(signature)
        }
        pump()
    }
}
