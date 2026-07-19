import Foundation

enum BackgroundJobLane: String, CaseIterable, Sendable, Hashable {
    case audioDecode
    case metadataIO

    var maximumConcurrentJobs: Int {
        switch self {
        case .audioDecode: return 1
        case .metadataIO: return 2
        }
    }
}

enum BackgroundJobPriority: Int, Sendable, Comparable {
    case background = 0
    case utility = 1
    case userInitiated = 2

    static func < (lhs: BackgroundJobPriority, rhs: BackgroundJobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate var taskPriority: TaskPriority {
        switch self {
        case .background: return .background
        case .utility: return .utility
        case .userInitiated: return .userInitiated
        }
    }
}

struct BackgroundJobDeduplicationKey: Hashable, Sendable, ExpressibleByStringLiteral {
    let namespace: String
    let value: String

    init(namespace: String = "default", value: String) {
        self.namespace = namespace
        self.value = value
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(value: value)
    }
}

enum BackgroundJobExecutionMode: Sendable, Equatable {
    case userInitiated
    case automatic(AutomaticJobRequirements)
}

enum BackgroundJobOutcome: Sendable, Equatable {
    case succeeded
    case cancelled
    case failed(message: String)
}

enum BackgroundJobSubmissionRejection: Sendable, Equatable {
    case pendingWindowFull(limit: Int)
}

enum BackgroundJobSubmission: Sendable {
    case accepted(BackgroundJobHandle)
    case deduplicated(BackgroundJobHandle)
    case rejected(BackgroundJobSubmissionRejection)

    var handle: BackgroundJobHandle? {
        switch self {
        case .accepted(let handle), .deduplicated(let handle): return handle
        case .rejected: return nil
        }
    }
}

struct BackgroundJobSchedulerSnapshot: Sendable, Equatable {
    let pendingAudioDecodeJobs: Int
    let runningAudioDecodeJobs: Int
    let pendingMetadataIOJobs: Int
    let runningMetadataIOJobs: Int
    let resourceBlockedAutomaticJobs: Int
    let trackedDeduplicationKeys: Int

    var totalPendingJobs: Int {
        pendingAudioDecodeJobs + pendingMetadataIOJobs
    }

    var totalRunningJobs: Int {
        runningAudioDecodeJobs + runningMetadataIOJobs
    }
}

fileprivate final class BackgroundJobCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: BackgroundJobOutcome?
    private var waiters: [CheckedContinuation<BackgroundJobOutcome, Never>] = []

    func wait() async -> BackgroundJobOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func resolve(_ outcome: BackgroundJobOutcome) {
        let pendingWaiters: [CheckedContinuation<BackgroundJobOutcome, Never>]
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in pendingWaiters {
            waiter.resume(returning: outcome)
        }
    }
}

struct BackgroundJobHandle: Sendable {
    let id: UUID
    let lane: BackgroundJobLane
    let deduplicationKey: BackgroundJobDeduplicationKey?

    fileprivate let completion: BackgroundJobCompletion
    fileprivate let scheduler: BackgroundJobScheduler

    func value() async -> BackgroundJobOutcome {
        await completion.wait()
    }

    func cancel() async {
        await scheduler.cancel(jobID: id)
    }
}

/// A small, process-wide style scheduler for expensive background work.
/// Pending jobs are closures rather than Tasks; Tasks are allocated only for
/// the three globally runnable slots, keeping a large library memory-stable.
actor BackgroundJobScheduler {
    /// One process-wide set of decode/metadata slots. Automatic work submitted
    /// by independent features therefore cannot multiply expensive decoders.
    static let shared = BackgroundJobScheduler()

    struct Configuration: Sendable, Equatable {
        let maximumPendingJobs: Int

        init(maximumPendingJobs: Int = 256) {
            self.maximumPendingJobs = max(1, maximumPendingJobs)
        }
    }

    typealias Operation = @Sendable () async throws -> Void

    private struct DeduplicationIdentity: Hashable, Sendable {
        let lane: BackgroundJobLane
        let key: BackgroundJobDeduplicationKey
    }

    private struct Job: Sendable {
        let id: UUID
        let lane: BackgroundJobLane
        let priority: BackgroundJobPriority
        let mode: BackgroundJobExecutionMode
        let deduplicationKey: BackgroundJobDeduplicationKey?
        let sequence: UInt64
        let operation: Operation
        let completion: BackgroundJobCompletion
    }

    private struct RunningJob: Sendable {
        let job: Job
        let task: Task<Void, Never>
    }

    private let configuration: Configuration
    private let resourcePolicy: SystemResourcePolicy
    private let resourceSnapshotProvider: SystemResourceSnapshotProvider

    private var pendingByLane: [BackgroundJobLane: [Job]] = [
        .audioDecode: [],
        .metadataIO: []
    ]
    private var runningByID: [UUID: RunningJob] = [:]
    private var jobsByID: [UUID: Job] = [:]
    private var jobIDByDeduplicationIdentity: [DeduplicationIdentity: UUID] = [:]
    private var nextSequence: UInt64 = 0

    init(
        configuration: Configuration = Configuration(),
        resourcePolicy: SystemResourcePolicy = SystemResourcePolicy(),
        resourceSnapshotProvider: SystemResourceSnapshotProvider = .live()
    ) {
        self.configuration = configuration
        self.resourcePolicy = resourcePolicy
        self.resourceSnapshotProvider = resourceSnapshotProvider
    }

    @discardableResult
    func submit(
        lane: BackgroundJobLane,
        priority: BackgroundJobPriority = .utility,
        mode: BackgroundJobExecutionMode = .userInitiated,
        deduplicationKey: BackgroundJobDeduplicationKey? = nil,
        operation: @escaping Operation
    ) -> BackgroundJobSubmission {
        if let deduplicationKey {
            let identity = DeduplicationIdentity(lane: lane, key: deduplicationKey)
            if let existingID = jobIDByDeduplicationIdentity[identity],
               let existing = jobsByID[existingID] {
                return .deduplicated(makeHandle(for: existing))
            }
        }

        guard pendingJobCount < configuration.maximumPendingJobs else {
            return .rejected(.pendingWindowFull(limit: configuration.maximumPendingJobs))
        }

        let id = UUID()
        let completion = BackgroundJobCompletion()
        let job = Job(
            id: id,
            lane: lane,
            priority: priority,
            mode: mode,
            deduplicationKey: deduplicationKey,
            sequence: nextSequence,
            operation: operation,
            completion: completion
        )
        nextSequence &+= 1

        pendingByLane[lane, default: []].append(job)
        jobsByID[id] = job
        if let deduplicationKey {
            jobIDByDeduplicationIdentity[
                DeduplicationIdentity(lane: lane, key: deduplicationKey)
            ] = id
        }
        pump()
        return .accepted(makeHandle(for: job))
    }

    func cancel(jobID: UUID) {
        if let running = runningByID[jobID] {
            running.task.cancel()
            return
        }

        for lane in BackgroundJobLane.allCases {
            guard let index = pendingByLane[lane]?.firstIndex(where: { $0.id == jobID }) else {
                continue
            }
            let job = pendingByLane[lane]!.remove(at: index)
            removeTracking(for: job)
            job.completion.resolve(.cancelled)
            pump()
            return
        }
    }

    func cancel(
        lane: BackgroundJobLane,
        deduplicationKey: BackgroundJobDeduplicationKey
    ) {
        let identity = DeduplicationIdentity(lane: lane, key: deduplicationKey)
        guard let id = jobIDByDeduplicationIdentity[identity] else { return }
        cancel(jobID: id)
    }

    func cancelAll() {
        let pending = BackgroundJobLane.allCases.flatMap { pendingByLane[$0] ?? [] }
        for lane in BackgroundJobLane.allCases {
            pendingByLane[lane]?.removeAll(keepingCapacity: false)
        }
        for job in pending {
            removeTracking(for: job)
            job.completion.resolve(.cancelled)
        }
        for running in runningByID.values {
            running.task.cancel()
        }
    }

    /// Re-evaluates queued automatic work. Running automatic jobs that no longer
    /// meet their requirements are cancelled cooperatively; user-initiated jobs
    /// are never cancelled by resource policy.
    func resourcesDidChange(cancelRunningAutomaticJobs: Bool = true) {
        let snapshot = resourceSnapshotProvider.currentSnapshot()
        if cancelRunningAutomaticJobs {
            for running in runningByID.values {
                guard case .automatic(let requirements) = running.job.mode else { continue }
                if !resourcePolicy.allowsAutomaticJob(requirements, snapshot: snapshot) {
                    running.task.cancel()
                }
            }
        }
        pump(snapshot: snapshot)
    }

    func snapshot() -> BackgroundJobSchedulerSnapshot {
        let resourceSnapshot = resourceSnapshotProvider.currentSnapshot()
        let blockedCount = pendingByLane.values
            .joined()
            .reduce(into: 0) { result, job in
                guard case .automatic(let requirements) = job.mode else { return }
                if !resourcePolicy.allowsAutomaticJob(
                    requirements,
                    snapshot: resourceSnapshot
                ) {
                    result += 1
                }
            }
        return BackgroundJobSchedulerSnapshot(
            pendingAudioDecodeJobs: pendingByLane[.audioDecode]?.count ?? 0,
            runningAudioDecodeJobs: runningCount(in: .audioDecode),
            pendingMetadataIOJobs: pendingByLane[.metadataIO]?.count ?? 0,
            runningMetadataIOJobs: runningCount(in: .metadataIO),
            resourceBlockedAutomaticJobs: blockedCount,
            trackedDeduplicationKeys: jobIDByDeduplicationIdentity.count
        )
    }

    private var pendingJobCount: Int {
        pendingByLane.values.reduce(0) { $0 + $1.count }
    }

    private func runningCount(in lane: BackgroundJobLane) -> Int {
        runningByID.values.reduce(into: 0) { count, running in
            if running.job.lane == lane { count += 1 }
        }
    }

    private func makeHandle(for job: Job) -> BackgroundJobHandle {
        BackgroundJobHandle(
            id: job.id,
            lane: job.lane,
            deduplicationKey: job.deduplicationKey,
            completion: job.completion,
            scheduler: self
        )
    }

    private func pump(snapshot suppliedSnapshot: SystemResourceSnapshot? = nil) {
        let snapshot = suppliedSnapshot ?? resourceSnapshotProvider.currentSnapshot()
        for lane in BackgroundJobLane.allCases {
            while runningCount(in: lane) < lane.maximumConcurrentJobs {
                guard let index = nextRunnableJobIndex(in: lane, snapshot: snapshot),
                      let job = pendingByLane[lane]?.remove(at: index) else {
                    break
                }
                start(job)
            }
        }
    }

    private func nextRunnableJobIndex(
        in lane: BackgroundJobLane,
        snapshot: SystemResourceSnapshot
    ) -> Int? {
        guard let jobs = pendingByLane[lane] else { return nil }
        var selectedIndex: Int?
        for (index, job) in jobs.enumerated() {
            guard isRunnable(job, snapshot: snapshot) else { continue }
            guard let currentIndex = selectedIndex else {
                selectedIndex = index
                continue
            }
            let current = jobs[currentIndex]
            if job.priority > current.priority
                || (job.priority == current.priority && job.sequence < current.sequence) {
                selectedIndex = index
            }
        }
        return selectedIndex
    }

    private func isRunnable(_ job: Job, snapshot: SystemResourceSnapshot) -> Bool {
        switch job.mode {
        case .userInitiated:
            return true
        case .automatic(let requirements):
            return resourcePolicy.allowsAutomaticJob(requirements, snapshot: snapshot)
        }
    }

    private func start(_ job: Job) {
        let task = Task(priority: job.priority.taskPriority) { [weak self] in
            let outcome: BackgroundJobOutcome
            do {
                try Task.checkCancellation()
                try await job.operation()
                try Task.checkCancellation()
                outcome = .succeeded
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled
                    ? .cancelled
                    : .failed(message: String(describing: error))
            }
            await self?.finish(jobID: job.id, outcome: outcome)
        }
        runningByID[job.id] = RunningJob(job: job, task: task)
    }

    private func finish(jobID: UUID, outcome: BackgroundJobOutcome) {
        guard let running = runningByID.removeValue(forKey: jobID) else { return }
        removeTracking(for: running.job)
        running.job.completion.resolve(outcome)
        pump()
    }

    private func removeTracking(for job: Job) {
        jobsByID.removeValue(forKey: job.id)
        guard let key = job.deduplicationKey else { return }
        let identity = DeduplicationIdentity(lane: job.lane, key: key)
        if jobIDByDeduplicationIdentity[identity] == job.id {
            jobIDByDeduplicationIdentity.removeValue(forKey: identity)
        }
    }
}
