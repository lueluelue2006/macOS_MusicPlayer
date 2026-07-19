import XCTest
@testable import MusicPlayer

final class BackgroundJobSchedulerTests: XCTestCase {
    func testLaneConcurrencyIsGloballyBounded() async throws {
        let scheduler = makeScheduler()
        let gate = TestAsyncGate()
        let probe = SchedulerActivityProbe()
        var handles: [BackgroundJobHandle] = []

        for index in 0..<4 {
            let submission = await scheduler.submit(lane: .audioDecode) {
                await probe.begin(lane: .audioDecode, label: "audio-\(index)")
                await gate.wait()
                await probe.end(lane: .audioDecode)
            }
            handles.append(try XCTUnwrap(submission.handle))
        }
        for index in 0..<6 {
            let submission = await scheduler.submit(lane: .metadataIO) {
                await probe.begin(lane: .metadataIO, label: "metadata-\(index)")
                await gate.wait()
                await probe.end(lane: .metadataIO)
            }
            handles.append(try XCTUnwrap(submission.handle))
        }

        let filled = await waitUntil {
            let state = await probe.state()
            return state.activeAudio == 1 && state.activeMetadata == 2
        }
        XCTAssertTrue(filled)
        let blockedState = await probe.state()
        XCTAssertEqual(blockedState.peakAudio, 1)
        XCTAssertEqual(blockedState.peakMetadata, 2)

        await gate.open()
        for handle in handles {
            await assertOutcome(handle, equals: .succeeded)
        }
        let finalState = await probe.state()
        XCTAssertEqual(finalState.peakAudio, 1)
        XCTAssertEqual(finalState.peakMetadata, 2)
    }

    func testHigherPriorityRunsFirstWithinLaneAndFIFOIsStable() async throws {
        let scheduler = makeScheduler()
        let blocker = TestAsyncGate()
        let probe = SchedulerActivityProbe()

        let running = try requireHandle(await scheduler.submit(
            lane: .audioDecode,
            priority: .utility
        ) {
            await probe.begin(lane: .audioDecode, label: "running")
            await blocker.wait()
            await probe.end(lane: .audioDecode)
        })
        let didStart = await waitUntil { await probe.state().activeAudio == 1 }
        XCTAssertTrue(didStart)

        let low = try requireHandle(await scheduler.submit(
            lane: .audioDecode,
            priority: .background
        ) {
            await probe.record(label: "low")
        })
        let highFirst = try requireHandle(await scheduler.submit(
            lane: .audioDecode,
            priority: .userInitiated
        ) {
            await probe.record(label: "high-first")
        })
        let highSecond = try requireHandle(await scheduler.submit(
            lane: .audioDecode,
            priority: .userInitiated
        ) {
            await probe.record(label: "high-second")
        })

        await blocker.open()
        for handle in [running, low, highFirst, highSecond] {
            await assertOutcome(handle, equals: .succeeded)
        }

        let order = await probe.state().order
        XCTAssertEqual(Array(order.suffix(3)), ["high-first", "high-second", "low"])
    }

    func testDeduplicationReturnsExistingHandleAndRunsOperationOnce() async throws {
        let scheduler = makeScheduler()
        let gate = TestAsyncGate()
        let counter = AsyncCounter()
        let key = BackgroundJobDeduplicationKey(namespace: "volume", value: "track-a")

        let firstSubmission = await scheduler.submit(
            lane: .audioDecode,
            deduplicationKey: key
        ) {
            await counter.increment()
            await gate.wait()
        }
        let first = try XCTUnwrap(firstSubmission.handle)
        let didStart = await waitUntil { await counter.value == 1 }
        XCTAssertTrue(didStart)

        let duplicateSubmission = await scheduler.submit(
            lane: .audioDecode,
            priority: .userInitiated,
            deduplicationKey: key
        ) {
            await counter.increment()
        }
        guard case .deduplicated(let duplicate) = duplicateSubmission else {
            return XCTFail("Expected duplicate submission to reuse the in-flight job")
        }
        XCTAssertEqual(duplicate.id, first.id)

        await gate.open()
        await assertOutcome(first, equals: .succeeded)
        await assertOutcome(duplicate, equals: .succeeded)
        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 1)
    }

    func testPendingWindowRejectsExcessAndCancellationFreesCapacity() async throws {
        let scheduler = makeScheduler(maximumPendingJobs: 2)
        let blocker = TestAsyncGate()
        let counter = AsyncCounter()

        let running = try requireHandle(await scheduler.submit(lane: .audioDecode) {
            await blocker.wait()
        })
        let firstPending = try requireHandle(await scheduler.submit(lane: .audioDecode) {
            await counter.increment()
        })
        _ = try requireHandle(await scheduler.submit(lane: .audioDecode) {
            await counter.increment()
        })

        let rejected = await scheduler.submit(lane: .audioDecode) {
            await counter.increment()
        }
        guard case .rejected(.pendingWindowFull(let limit)) = rejected else {
            return XCTFail("Expected bounded pending window rejection")
        }
        XCTAssertEqual(limit, 2)

        await firstPending.cancel()
        await assertOutcome(firstPending, equals: .cancelled)
        let replacement = try requireHandle(await scheduler.submit(lane: .audioDecode) {
            await counter.increment()
        })

        await blocker.open()
        await assertOutcome(running, equals: .succeeded)
        await assertOutcome(replacement, equals: .succeeded)
        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 2)
    }

    func testAutomaticJobWaitsForResourcesAndStartsAfterReevaluation() async throws {
        let snapshotBox = ResourceSnapshotBox(snapshot: .fixture(powerSource: .battery))
        let scheduler = BackgroundJobScheduler(
            resourceSnapshotProvider: SystemResourceSnapshotProvider {
                snapshotBox.current
            }
        )
        let counter = AsyncCounter()
        let requirements = AutomaticJobRequirements(
            requiresACPower: true,
            minimumSystemIdleDuration: 0,
            minimumApplicationIdleDuration: 0
        )

        let handle = try requireHandle(await scheduler.submit(
            lane: .audioDecode,
            mode: .automatic(requirements)
        ) {
            await counter.increment()
        })

        let waiting = await scheduler.snapshot()
        XCTAssertEqual(waiting.resourceBlockedAutomaticJobs, 1)
        XCTAssertEqual(waiting.runningAudioDecodeJobs, 0)
        let countWhileBlocked = await counter.value
        XCTAssertEqual(countWhileBlocked, 0)

        snapshotBox.update(.fixture(powerSource: .acPower))
        await scheduler.resourcesDidChange()
        await assertOutcome(handle, equals: .succeeded)
        let finalCount = await counter.value
        XCTAssertEqual(finalCount, 1)
    }

    func testResourcePressureCancelsRunningAutomaticJobButNotUserJob() async throws {
        let snapshotBox = ResourceSnapshotBox(snapshot: .fixture())
        let scheduler = BackgroundJobScheduler(
            resourceSnapshotProvider: SystemResourceSnapshotProvider {
                snapshotBox.current
            }
        )
        let automaticStarted = AsyncCounter()
        let manualGate = TestAsyncGate()

        let automatic = try requireHandle(await scheduler.submit(
            lane: .audioDecode,
            mode: .automatic(AutomaticJobRequirements(
                minimumSystemIdleDuration: 0,
                minimumApplicationIdleDuration: 0
            ))
        ) {
            await automaticStarted.increment()
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        })
        let manual = try requireHandle(await scheduler.submit(lane: .metadataIO) {
            await manualGate.wait()
        })
        let didStart = await waitUntil { await automaticStarted.value == 1 }
        XCTAssertTrue(didStart)

        snapshotBox.update(.fixture(memoryPressure: .warning))
        await scheduler.resourcesDidChange()
        await assertOutcome(automatic, equals: .cancelled)

        let state = await scheduler.snapshot()
        XCTAssertEqual(state.runningMetadataIOJobs, 1)
        await manualGate.open()
        await assertOutcome(manual, equals: .succeeded)
    }

    func testAutomaticVolumeJobsShareGlobalPerTrackDeduplication() async throws {
        let scheduler = makeScheduler()
        let client = SchedulerAutomaticVolumeClient()
        let url = URL(fileURLWithPath: "/tmp/global-volume-track.mp3")

        let firstSubmission = await AutomaticVolumePreanalysisJobs.submit(
            url: url,
            client: client,
            scheduler: scheduler,
            requirements: AutomaticJobRequirements(
                minimumSystemIdleDuration: 0,
                minimumApplicationIdleDuration: 0
            )
        )
        let first = try requireHandle(firstSubmission)
        let didStart = await waitUntil { client.executionCount == 1 }
        XCTAssertTrue(didStart)

        let duplicateSubmission = await AutomaticVolumePreanalysisJobs.submit(
            url: url,
            client: client,
            scheduler: scheduler,
            requirements: AutomaticJobRequirements(
                minimumSystemIdleDuration: 0,
                minimumApplicationIdleDuration: 0
            )
        )
        guard case .deduplicated(let duplicate) = duplicateSubmission else {
            return XCTFail("Expected the process-wide audio lane to reuse the track job")
        }
        XCTAssertEqual(duplicate.id, first.id)

        client.release()
        await assertOutcome(first, equals: .succeeded)
        await assertOutcome(duplicate, equals: .succeeded)
        XCTAssertEqual(client.executionCount, 1)
    }

    func testAutomaticVolumeJobIsCancelledWhenResourcePolicyChanges() async throws {
        let snapshotBox = ResourceSnapshotBox(snapshot: .fixture())
        let scheduler = BackgroundJobScheduler(
            resourceSnapshotProvider: SystemResourceSnapshotProvider {
                snapshotBox.current
            }
        )
        let client = SchedulerAutomaticVolumeClient()
        let handle = try requireHandle(await AutomaticVolumePreanalysisJobs.submit(
            url: URL(fileURLWithPath: "/tmp/cancelled-volume-track.mp3"),
            client: client,
            scheduler: scheduler,
            requirements: AutomaticJobRequirements(
                minimumSystemIdleDuration: 0,
                minimumApplicationIdleDuration: 0
            )
        ))
        let didStart = await waitUntil { client.executionCount == 1 }
        XCTAssertTrue(didStart)

        snapshotBox.update(.fixture(memoryPressure: .warning))
        await scheduler.resourcesDidChange()
        await assertOutcome(handle, equals: .cancelled)
        XCTAssertEqual(client.cancellationCount, 1)
    }

    private func makeScheduler(maximumPendingJobs: Int = 256) -> BackgroundJobScheduler {
        BackgroundJobScheduler(
            configuration: .init(maximumPendingJobs: maximumPendingJobs),
            resourceSnapshotProvider: .constant(.fixture())
        )
    }

    private func requireHandle(
        _ submission: BackgroundJobSubmission,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BackgroundJobHandle {
        try XCTUnwrap(submission.handle, file: file, line: line)
    }

    private func assertOutcome(
        _ handle: BackgroundJobHandle,
        equals expected: BackgroundJobOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await handle.value()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

private final class SchedulerAutomaticVolumeClient:
    AutomaticVolumePreanalysisClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var executions = 0
    private var cancellations = 0
    private var isReleased = false

    var executionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return executions
    }

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func eligibleCandidates(in urls: [URL], limit: Int) async -> [URL] {
        Array(urls.prefix(limit))
    }

    func nextRetryDate() -> Date? { nil }

    func runAutomaticPreanalysis(for _: URL) async throws {
        recordExecution()
        do {
            while true {
                if releasedSnapshot() { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch {
            recordCancellation()
            throw error
        }
    }

    func cancelAutomaticPreanalysis() {}

    func release() {
        lock.lock()
        isReleased = true
        lock.unlock()
    }

    private func recordExecution() {
        lock.lock()
        executions += 1
        lock.unlock()
    }

    private func recordCancellation() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }

    private func releasedSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReleased
    }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SchedulerActivityProbe {
    struct State: Sendable {
        let activeAudio: Int
        let peakAudio: Int
        let activeMetadata: Int
        let peakMetadata: Int
        let order: [String]
    }

    private var activeAudio = 0
    private var peakAudio = 0
    private var activeMetadata = 0
    private var peakMetadata = 0
    private var order: [String] = []

    func begin(lane: BackgroundJobLane, label: String) {
        order.append(label)
        switch lane {
        case .audioDecode:
            activeAudio += 1
            peakAudio = max(peakAudio, activeAudio)
        case .metadataIO:
            activeMetadata += 1
            peakMetadata = max(peakMetadata, activeMetadata)
        }
    }

    func end(lane: BackgroundJobLane) {
        switch lane {
        case .audioDecode: activeAudio -= 1
        case .metadataIO: activeMetadata -= 1
        }
    }

    func record(label: String) {
        order.append(label)
    }

    func state() -> State {
        State(
            activeAudio: activeAudio,
            peakAudio: peakAudio,
            activeMetadata: activeMetadata,
            peakMetadata: peakMetadata,
            order: order
        )
    }
}

private final class ResourceSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: SystemResourceSnapshot

    init(snapshot: SystemResourceSnapshot) {
        self.snapshot = snapshot
    }

    var current: SystemResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func update(_ snapshot: SystemResourceSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }
}

private extension SystemResourceSnapshot {
    static func fixture(
        powerSource: SystemPowerSource = .acPower,
        lowPowerMode: Bool = false,
        thermalLevel: SystemThermalLevel = .nominal,
        memoryPressure: SystemMemoryPressure = .normal,
        systemIdle: TimeInterval = 120,
        applicationIdle: TimeInterval = 120
    ) -> Self {
        Self(
            powerSource: powerSource,
            isLowPowerModeEnabled: lowPowerMode,
            thermalLevel: thermalLevel,
            memoryPressure: memoryPressure,
            systemIdleDuration: systemIdle,
            applicationIdleDuration: applicationIdle
        )
    }
}
