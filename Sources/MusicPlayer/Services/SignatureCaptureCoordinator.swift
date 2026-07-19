import Foundation

/// A compare-and-swap target for reconstructable signature enrichment.
/// `trackID`, `expectedPath`, and `generation` must still match when the result
/// returns; otherwise the store discards the late result.
struct SignatureCaptureTarget: Hashable, Sendable {
    let playlistID: UserPlaylist.ID
    let trackID: UUID
    let expectedPath: String
    let generation: UInt64
}

struct SignatureCaptureBatch: Sendable {
    let id: UUID
    let targets: [SignatureCaptureTarget]

    init(id: UUID = UUID(), targets: [SignatureCaptureTarget]) {
        self.id = id
        self.targets = targets
    }
}

struct SignatureCaptureResult: Sendable {
    struct Entry: Sendable {
        let target: SignatureCaptureTarget
        let signature: FileSignature?
    }

    let batchID: UUID
    let entries: [Entry]
}

/// Owns capture-task lifecycle. Signature work is enrichment rather than a
/// prerequisite for committing playlist paths, so termination cancels it and
/// never waits for a slow or unavailable volume.
actor SignatureCaptureCoordinator {
    private let service: SignatureCaptureService
    private var activeBatches: [UUID: Task<SignatureCaptureResult, Never>] = [:]
    private var terminationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var isTerminating = false

    init(service: SignatureCaptureService) {
        self.service = service
    }

    /// Returns nil after termination has started. Captures for the same path are
    /// shared by SignatureCaptureService even when they arrive in different batches.
    func submitBatch(
        _ batch: SignatureCaptureBatch
    ) -> Task<SignatureCaptureResult, Never>? {
        guard !isTerminating else { return nil }

        let task = Task<SignatureCaptureResult, Never> { [service] in
            guard !Task.isCancelled else {
                return SignatureCaptureResult(batchID: batch.id, entries: [])
            }

            let urls = batch.targets.map {
                URL(fileURLWithPath: $0.expectedPath)
            }
            let signatures = await service.captureSignatures(for: urls)

            guard !Task.isCancelled else {
                return SignatureCaptureResult(batchID: batch.id, entries: [])
            }
            let entries = batch.targets.map { target in
                SignatureCaptureResult.Entry(
                    target: target,
                    signature: signatures[PathKey.canonical(path: target.expectedPath)]
                )
            }
            return SignatureCaptureResult(batchID: batch.id, entries: entries)
        }

        activeBatches[batch.id] = task
        return task
    }

    func finishBatch(_ batchID: UUID) {
        activeBatches.removeValue(forKey: batchID)
    }

    /// Rejects new enrichment and cancels every active batch. This method does
    /// not await the underlying filesystem operation; callers may quit at once.
    func cancelForTermination() async {
        if !isTerminating {
            isTerminating = true
            let waiters = terminationStartWaiters
            terminationStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        let tasks = Array(activeBatches.values)
        activeBatches.removeAll()
        for task in tasks {
            task.cancel()
        }
        await service.cancelAll()
    }

    /// Backward-compatible name. Draining signature enrichment is intentionally
    /// no longer part of the termination durability barrier.
    func drainForTermination() async {
        await cancelForTermination()
    }

    func waitUntilTerminationStartedForTesting() async {
        guard !isTerminating else { return }
        await withCheckedContinuation { continuation in
            terminationStartWaiters.append(continuation)
        }
    }

    func hasActiveBatches() -> Bool {
        !activeBatches.isEmpty
    }
}
