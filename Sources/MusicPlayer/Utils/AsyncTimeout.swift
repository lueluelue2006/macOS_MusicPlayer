import Foundation

enum TimeoutError: Error {
    case timedOut
}

enum AsyncTimeout {
    /// Runs the given async operation and throws `TimeoutError.timedOut` if it doesn't
    /// complete within the specified number of seconds. Cancels the losing task.
    static func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

