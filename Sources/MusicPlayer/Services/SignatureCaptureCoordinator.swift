import Foundation

/// Batch record for tracking signature capture operations
struct SignatureCaptureBatch: Sendable {
    let id: UUID
    let playlistID: UserPlaylist.ID?
    let tracks: [UserPlaylist.Track]

    init(id: UUID = UUID(), playlistID: UserPlaylist.ID?, tracks: [UserPlaylist.Track]) {
        self.id = id
        self.playlistID = playlistID
        self.tracks = tracks
    }
}

/// Result of signature capture batch
struct SignatureCaptureResult: Sendable {
    let batchID: UUID
    let enrichedTracks: [UserPlaylist.Track]
}

/// Coordinator for managing signature capture batches without store reference cycles
actor SignatureCaptureCoordinator {
    private let service: SignatureCaptureService
    private var activeBatches: [UUID: Task<SignatureCaptureResult, Never>] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var isTerminating = false

    init(service: SignatureCaptureService) {
        self.service = service
    }

    /// Submit a batch for signature capture
    /// - Returns: Batch ID and result task, or nil if terminating
    func submitBatch(_ batch: SignatureCaptureBatch) -> (UUID, Task<SignatureCaptureResult, Never>)? {
        guard !isTerminating else { return nil }

        let task = Task<SignatureCaptureResult, Never> { [service] in
            // Extract URLs for tracks that need signatures
            let urlsToCapture = batch.tracks.compactMap { track -> URL? in
                guard track.signature == nil else { return nil }
                return URL(fileURLWithPath: track.path)
            }

            let signatures = await service.captureSignatures(for: urlsToCapture)

            // Enrich tracks: preserve existing signatures, use canonical key lookup for new ones
            let enrichedTracks = batch.tracks.map { track in
                if track.signature != nil {
                    return track  // Preserve existing signature
                }
                let canonicalKey = PathKey.canonical(path: track.path)
                return UserPlaylist.Track(path: track.path, signature: signatures[canonicalKey])
            }

            return SignatureCaptureResult(batchID: batch.id, enrichedTracks: enrichedTracks)
        }

        activeBatches[batch.id] = task
        return (batch.id, task)
    }

    /// Mark batch lifecycle as finished (called by store after merge/save or discard)
    func finishBatch(_ batchID: UUID) {
        activeBatches.removeValue(forKey: batchID)

        // If this was the last active batch, resume all drain waiters
        if activeBatches.isEmpty && !drainWaiters.isEmpty {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Enter terminating state, reject new submissions, and wait for all active batches to finish
    func drainForTermination() async {
        isTerminating = true

        let startWaiters = terminationStartWaiters
        terminationStartWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }

        guard !activeBatches.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters.append(continuation)
        }
    }

    /// Wait until termination has started (for testing)
    func waitUntilTerminationStartedForTesting() async {
        guard !isTerminating else { return }
        await withCheckedContinuation { continuation in
            terminationStartWaiters.append(continuation)
        }
    }

    /// Check if any batches are still active (for testing)
    func hasActiveBatches() -> Bool {
        !activeBatches.isEmpty
    }
}
