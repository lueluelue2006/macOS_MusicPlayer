import Foundation

enum BoundedWorkerPool {
    /// Process items with bounded concurrency, preserving input order in results.
    ///
    /// Creates exactly `min(max(1, maxConcurrent), items.count)` worker tasks.
    /// Each worker processes multiple items in a loop, checking for cancellation
    /// before claiming the next item and after each operation completes.
    ///
    /// - Parameters:
    ///   - items: Input items to process
    ///   - maxConcurrent: Maximum number of concurrent workers (clamped to [1, items.count])
    ///   - operation: Async operation to perform on each item
    /// - Returns: Array of results in the same order as input items
    static func map<Input, Output>(
        items: [Input],
        maxConcurrent: Int,
        operation: @escaping (Input) async -> Output
    ) async -> [Output] {
        guard !items.isEmpty else {
            return []
        }

        let workerCount = min(max(1, maxConcurrent), items.count)
        let state = WorkState<Output>(itemCount: items.count)

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<workerCount {
                group.addTask {
                    await processWorker(
                        workerIndex: workerIndex,
                        workerCount: workerCount,
                        items: items,
                        state: state,
                        operation: operation
                    )
                }
            }

            // Wait for all workers to complete
            for await _ in group {}
        }

        return await state.getResults()
    }

    private static func processWorker<Input, Output>(
        workerIndex: Int,
        workerCount: Int,
        items: [Input],
        state: WorkState<Output>,
        operation: @escaping (Input) async -> Output
    ) async {
        // Use stride pattern: worker 0 handles indices 0, workerCount, 2*workerCount, ...
        var index = workerIndex
        while index < items.count {
            // Check cancellation before claiming next item
            if Task.isCancelled {
                return
            }

            let item = items[index]
            let result = await operation(item)

            // Check cancellation after operation completes
            if Task.isCancelled {
                return
            }

            await state.setResult(result, at: index)

            index += workerCount
        }
    }
}

// MARK: - State Management

private actor WorkState<Output> {
    private var results: [Output?]

    init(itemCount: Int) {
        self.results = Array(repeating: nil, count: itemCount)
    }

    func setResult(_ result: Output, at index: Int) {
        results[index] = result
    }

    func getResults() -> [Output] {
        return results.compactMap { $0 }
    }
}
