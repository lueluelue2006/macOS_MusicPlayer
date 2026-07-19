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

struct SignatureCaptureCoordinatorDiagnostics: Sendable, Equatable {
    let activeCaptureCount: Int
    let peakActiveCaptureCount: Int
    let pendingCaptureCount: Int
    let activeChunkCount: Int
    let pendingChunkCount: Int
    let admittedBatchCount: Int
    let waitingSubmissionCount: Int
    let largestScheduledChunkSize: Int
}

private final class SignatureCaptureBatchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SignatureCaptureResult?
    private var waiters: [CheckedContinuation<SignatureCaptureResult, Never>] = []

    func value() async -> SignatureCaptureResult {
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

    func resolve(_ result: SignatureCaptureResult) {
        let pendingWaiters: [CheckedContinuation<SignatureCaptureResult, Never>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in pendingWaiters {
            waiter.resume(returning: result)
        }
    }
}

/// Owns a single bounded, fair chunk pump for every playlist-enrichment batch.
/// At most two chunk workers exist, each chunk contains at most 256 targets,
/// and only a bounded number of batches may occupy the pump at once.
actor SignatureCaptureCoordinator {
    private struct CompletedChunk {
        let startIndex: Int
        let entries: [SignatureCaptureResult.Entry]
    }

    private final class BatchState {
        let batch: SignatureCaptureBatch
        let completion: SignatureCaptureBatchCompletion
        var nextTargetIndex = 0
        var inFlightChunkCount = 0
        var completedChunks: [CompletedChunk] = []

        init(batch: SignatureCaptureBatch, completion: SignatureCaptureBatchCompletion) {
            self.batch = batch
            self.completion = completion
        }
    }

    private struct AdmissionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let service: SignatureCaptureService
    private let maximumConcurrentChunkJobs: Int
    private let maximumChunkSize: Int
    private let maximumAdmittedBatches: Int

    private var batchesByID: [UUID: BatchState] = [:]
    private var resultTasksByBatchID: [UUID: Task<SignatureCaptureResult, Never>] = [:]
    private var readyBatchIDs: [UUID] = []
    private var activeChunkTasksByID: [UUID: Task<Void, Never>] = [:]
    private var admissionWaiters: [AdmissionWaiter] = []
    private var reservedAdmissionSlots = 0
    private var terminationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var largestScheduledChunkSize = 0
    private var isTerminating = false

    init(
        service: SignatureCaptureService,
        maximumConcurrentChunkJobs: Int = 2,
        maximumChunkSize: Int = 256,
        maximumAdmittedBatches: Int = 8
    ) {
        self.service = service
        self.maximumConcurrentChunkJobs = min(2, max(1, maximumConcurrentChunkJobs))
        self.maximumChunkSize = min(256, max(1, maximumChunkSize))
        self.maximumAdmittedBatches = max(1, maximumAdmittedBatches)
    }

    /// Returns nil after termination or caller cancellation. When the bounded
    /// batch window is full, submission waits FIFO without placing its target
    /// array inside the coordinator.
    func submitBatch(
        _ batch: SignatureCaptureBatch
    ) async -> Task<SignatureCaptureResult, Never>? {
        guard !isTerminating, !Task.isCancelled else { return nil }
        if let existing = resultTasksByBatchID[batch.id] {
            return existing
        }

        if batch.targets.isEmpty {
            return Task {
                SignatureCaptureResult(batchID: batch.id, entries: [])
            }
        }

        guard await acquireAdmissionSlot() else { return nil }
        guard !isTerminating, !Task.isCancelled else {
            grantAdmissionSlotsIfPossible()
            return nil
        }

        let completion = SignatureCaptureBatchCompletion()
        let resultTask = Task { await completion.value() }
        let state = BatchState(batch: batch, completion: completion)
        batchesByID[batch.id] = state
        resultTasksByBatchID[batch.id] = resultTask
        readyBatchIDs.append(batch.id)
        pumpChunks()
        return resultTask
    }

    /// Releases the completed result Task retained for duplicate submissions.
    /// Work itself is retired as soon as its final chunk completes.
    func finishBatch(_ batchID: UUID) {
        resultTasksByBatchID.removeValue(forKey: batchID)
    }

    func diagnostics() async -> SignatureCaptureCoordinatorDiagnostics {
        let activeChunkCount = activeChunkTasksByID.count
        let pendingChunkCount = batchesByID.values.reduce(into: 0) { count, state in
            let remaining = max(0, state.batch.targets.count - state.nextTargetIndex)
            if remaining > 0 {
                count += (remaining + maximumChunkSize - 1) / maximumChunkSize
            }
        }
        let admittedBatchCount = batchesByID.count
        let waitingSubmissionCount = admissionWaiters.count
        let largestScheduledChunkSize = largestScheduledChunkSize
        let serviceDiagnostics = await service.diagnostics()
        return SignatureCaptureCoordinatorDiagnostics(
            activeCaptureCount: serviceDiagnostics.activeCaptureCount,
            peakActiveCaptureCount: serviceDiagnostics.peakActiveCaptureCount,
            pendingCaptureCount: serviceDiagnostics.pendingCaptureCount,
            activeChunkCount: activeChunkCount,
            pendingChunkCount: pendingChunkCount,
            admittedBatchCount: admittedBatchCount,
            waitingSubmissionCount: waitingSubmissionCount,
            largestScheduledChunkSize: largestScheduledChunkSize
        )
    }

    /// Rejects new enrichment and cancels every admitted or waiting batch. This
    /// never awaits an unavailable volume; completions are resolved before the
    /// service receives cooperative cancellation.
    func cancelForTermination() async {
        guard !isTerminating else { return }
        isTerminating = true

        let startWaiters = terminationStartWaiters
        terminationStartWaiters.removeAll(keepingCapacity: false)
        for waiter in startWaiters {
            waiter.resume()
        }

        let chunkTasks = Array(activeChunkTasksByID.values)
        activeChunkTasksByID.removeAll(keepingCapacity: false)
        for task in chunkTasks {
            task.cancel()
        }

        let states = Array(batchesByID.values)
        batchesByID.removeAll(keepingCapacity: false)
        readyBatchIDs.removeAll(keepingCapacity: false)
        for state in states {
            state.completion.resolve(SignatureCaptureResult(
                batchID: state.batch.id,
                entries: []
            ))
        }

        reservedAdmissionSlots = 0
        let waiting = admissionWaiters
        admissionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiting {
            waiter.continuation.resume(returning: false)
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
        !batchesByID.isEmpty || !activeChunkTasksByID.isEmpty
    }

    private func acquireAdmissionSlot() async -> Bool {
        guard !isTerminating, !Task.isCancelled else { return false }
        if batchesByID.count + reservedAdmissionSlots < maximumAdmittedBatches {
            return true
        }

        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isTerminating || Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    admissionWaiters.append(AdmissionWaiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelAdmissionWaiter(waiterID)
            }
        }

        if granted {
            reservedAdmissionSlots = max(0, reservedAdmissionSlots - 1)
        }
        if !granted || Task.isCancelled || isTerminating {
            grantAdmissionSlotsIfPossible()
            return false
        }
        return true
    }

    private func cancelAdmissionWaiter(_ waiterID: UUID) {
        guard let index = admissionWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = admissionWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        grantAdmissionSlotsIfPossible()
    }

    private func grantAdmissionSlotsIfPossible() {
        guard !isTerminating else { return }
        while batchesByID.count + reservedAdmissionSlots < maximumAdmittedBatches,
              !admissionWaiters.isEmpty {
            let waiter = admissionWaiters.removeFirst()
            reservedAdmissionSlots += 1
            waiter.continuation.resume(returning: true)
        }
    }

    private func pumpChunks() {
        guard !isTerminating else { return }
        while activeChunkTasksByID.count < maximumConcurrentChunkJobs,
              let batchID = takeNextReadyBatchID(),
              let state = batchesByID[batchID] {
            let startIndex = state.nextTargetIndex
            let endIndex = min(
                startIndex + maximumChunkSize,
                state.batch.targets.count
            )
            guard startIndex < endIndex else { continue }

            let targets = Array(state.batch.targets[startIndex..<endIndex])
            state.nextTargetIndex = endIndex
            state.inFlightChunkCount += 1
            largestScheduledChunkSize = max(largestScheduledChunkSize, targets.count)
            if endIndex < state.batch.targets.count {
                readyBatchIDs.append(batchID)
            }
            startChunk(
                batchID: batchID,
                startIndex: startIndex,
                targets: targets
            )
        }
    }

    /// Prefer a batch with fewer active chunks, retaining FIFO order for ties.
    /// A lone large batch can use both workers, while a newly arrived batch gets
    /// the next released slot instead of sitting behind the large one.
    private func takeNextReadyBatchID() -> UUID? {
        var selectedIndex: Int?
        var selectedInFlight = Int.max
        for (index, batchID) in readyBatchIDs.enumerated() {
            guard let state = batchesByID[batchID],
                  state.nextTargetIndex < state.batch.targets.count else { continue }
            if state.inFlightChunkCount < selectedInFlight {
                selectedIndex = index
                selectedInFlight = state.inFlightChunkCount
            }
        }
        guard let selectedIndex else {
            readyBatchIDs.removeAll(keepingCapacity: true)
            return nil
        }
        return readyBatchIDs.remove(at: selectedIndex)
    }

    private func startChunk(
        batchID: UUID,
        startIndex: Int,
        targets: [SignatureCaptureTarget]
    ) {
        let workID = UUID()
        let service = self.service
        let task = Task { [weak self] in
            let urls = targets.map { URL(fileURLWithPath: $0.expectedPath) }
            let signatures = await service.captureSignatures(for: urls)
            let entries: [SignatureCaptureResult.Entry]
            if Task.isCancelled {
                entries = []
            } else {
                entries = targets.map { target in
                    SignatureCaptureResult.Entry(
                        target: target,
                        signature: signatures[
                            PathKey.canonical(path: target.expectedPath)
                        ]
                    )
                }
            }
            await self?.finishChunk(
                workID: workID,
                batchID: batchID,
                startIndex: startIndex,
                entries: entries
            )
        }
        activeChunkTasksByID[workID] = task
    }

    private func finishChunk(
        workID: UUID,
        batchID: UUID,
        startIndex: Int,
        entries: [SignatureCaptureResult.Entry]
    ) {
        guard activeChunkTasksByID.removeValue(forKey: workID) != nil,
              let state = batchesByID[batchID] else { return }

        state.inFlightChunkCount = max(0, state.inFlightChunkCount - 1)
        state.completedChunks.append(CompletedChunk(
            startIndex: startIndex,
            entries: entries
        ))

        if state.nextTargetIndex >= state.batch.targets.count,
           state.inFlightChunkCount == 0 {
            let orderedEntries = state.completedChunks
                .sorted { $0.startIndex < $1.startIndex }
                .flatMap(\.entries)
            batchesByID.removeValue(forKey: batchID)
            state.completion.resolve(SignatureCaptureResult(
                batchID: batchID,
                entries: orderedEntries
            ))
            grantAdmissionSlotsIfPossible()
        }
        pumpChunks()
    }
}
