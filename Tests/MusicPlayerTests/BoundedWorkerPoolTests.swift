import XCTest
@testable import MusicPlayer

final class BoundedWorkerPoolTests: XCTestCase {

    // MARK: - Empty Input

    func testEmptyInput() async throws {
        let gate = ControlledGate()

        let results = await BoundedWorkerPool.map(
            items: [Int](),
            maxConcurrent: 4
        ) { item in
            await gate.enterAndWait(id: item)
            return item * 2
        }

        XCTAssertEqual(results, [])
        let enteredCount = await gate.entered
        XCTAssertEqual(enteredCount, 0, "operation should not be called for empty input")
    }

    // MARK: - Worker Count Clamping

    func testMaxConcurrentZeroAndNegativeClampedToOne() async throws {
        let resultsZero = await BoundedWorkerPool.map(
            items: [1, 2, 3],
            maxConcurrent: 0
        ) { item in
            return item * 10
        }

        let resultsNegative = await BoundedWorkerPool.map(
            items: [5, 6],
            maxConcurrent: -3
        ) { item in
            return item + 100
        }

        XCTAssertEqual(resultsZero, [10, 20, 30], "maxConcurrent=0 should clamp to 1")
        XCTAssertEqual(resultsNegative, [105, 106], "negative maxConcurrent should clamp to 1")
    }

    // MARK: - Concurrency Limit

    func testPeakConcurrencyExactlyMaxConcurrent() async throws {
        let gate = ControlledGate()
        let items = Array(0..<20)

        let task = Task {
            await BoundedWorkerPool.map(
                items: items,
                maxConcurrent: 4
            ) { item in
                await gate.enterAndWait(id: item)
                return item
            }
        }

        // Wait for exactly 4 operations to enter
        await gate.waitUntilEntered(4)

        let peakCount = await gate.peak
        let activeCount = await gate.active
        XCTAssertEqual(peakCount, 4, "peak concurrent operations should be exactly 4")
        XCTAssertEqual(activeCount, 4, "should have exactly 4 active operations")

        // Release all and wait for completion
        await gate.releaseAll()
        let results = await task.value

        XCTAssertEqual(results.count, 20)
        let maxEverActive = await gate.peak
        XCTAssertEqual(maxEverActive, 4, "should never exceed maxConcurrent=4")
    }

    // MARK: - Result Ordering

    func testResultsPreserveInputOrderDespiteReverseCompletion() async throws {
        let gate = ControlledGate()
        let items = [0, 1, 2, 3]

        let task = Task {
            await BoundedWorkerPool.map(
                items: items,
                maxConcurrent: 4
            ) { item in
                await gate.enterAndWait(id: item)
                await gate.reportCompleted(id: item)
                return item * 100
            }
        }

        // Wait for all 4 to enter
        await gate.waitUntilEntered(4)

        // Release in reverse order: 3, 2, 1, 0
        for id in [3, 2, 1, 0] {
            await gate.release(id: id)
            await gate.waitUntilCompleted(id: id)
        }

        let results = await task.value

        XCTAssertEqual(results, [0, 100, 200, 300], "results must preserve input order despite reverse completion")
    }

    // MARK: - Cancellation

    func testCancellationStopsAfterInitialBatch() async throws {
        let gate = ControlledGate()
        let items = Array(0..<1000)

        let task = Task {
            await BoundedWorkerPool.map(
                items: items,
                maxConcurrent: 4
            ) { item in
                await gate.enterAndWait(id: item)
                return item
            }
        }

        // Wait for first batch of 4 to enter
        await gate.waitUntilEntered(4)

        // Cancel the task
        task.cancel()

        // Release all blocked operations
        await gate.releaseAll()

        // Wait for task to complete
        _ = await task.value

        let enteredCount = await gate.entered
        XCTAssertEqual(enteredCount, 4, "should have started exactly 4 operations (initial batch) before cancellation stopped new work")
    }
}

// MARK: - Test Probe

/// Deterministic gate for controlling operation execution
private actor ControlledGate {
    private(set) var entered = 0
    private(set) var active = 0
    private(set) var peak = 0
    private var blockedOperations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedAll = false
    private var enteredWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completedIds: Set<Int> = []
    private var completionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func enterAndWait(id: Int) async {
        entered += 1
        active += 1
        if active > peak {
            peak = active
        }

        // Resume any waiters waiting for this entered count
        var resumedIndices: [Int] = []
        for (index, waiter) in enteredWaiters.enumerated() {
            if entered >= waiter.threshold {
                waiter.continuation.resume()
                resumedIndices.append(index)
            }
        }
        for index in resumedIndices.reversed() {
            enteredWaiters.remove(at: index)
        }

        // If already released, don't block
        if releasedAll {
            active -= 1
            return
        }

        // Block until released (atomically within this actor call)
        await withCheckedContinuation { continuation in
            blockedOperations[id] = continuation
        }
        active -= 1
    }

    func reportCompleted(id: Int) {
        completedIds.insert(id)
        if let waiter = completionWaiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }

    func release(id: Int) {
        if let continuation = blockedOperations.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    func releaseAll() {
        releasedAll = true
        for (_, continuation) in blockedOperations {
            continuation.resume()
        }
        blockedOperations.removeAll()
    }

    func waitUntilEntered(_ threshold: Int) async {
        if entered >= threshold {
            return
        }

        await withCheckedContinuation { continuation in
            enteredWaiters.append((threshold: threshold, continuation: continuation))
        }
    }

    func waitUntilCompleted(id: Int) async {
        if completedIds.contains(id) {
            return
        }

        await withCheckedContinuation { continuation in
            completionWaiters[id] = continuation
        }
    }
}
