import AppKit
import XCTest
@testable import MusicPlayer

final class ApplicationTerminationTests: XCTestCase {
    private final class ManualClock {
        var value: TimeInterval

        init(_ value: TimeInterval) {
            self.value = value
        }

        func advance(by interval: TimeInterval) {
            value += interval
        }
    }

    private enum ExpectedFailure: Error {
        case persistence
    }

    @MainActor
    func testAppDelegateFreezesMutationsAndTerminatesWithoutDeferring() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.isTerminationMutationFrozen)
        var stoppedGenerations: [UInt64] = []
        _ = delegate.registerTerminationLifecycleHook(
            .init { context in stoppedGenerations.append(context.generation) }
        )

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        let repeatedReply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(repeatedReply, .terminateNow)
        XCTAssertTrue(delegate.isTerminationMutationFrozen)
        XCTAssertEqual(stoppedGenerations, [1])
        XCTAssertEqual(delegate.terminationContext?.generation, 1)
    }

    @MainActor
    func testApplicationWillTerminateRunsCleanupForSecondaryInstance() {
        let delegate = AppDelegate()

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertTrue(delegate.isTerminationMutationFrozen)
        XCTAssertEqual(delegate.lastTerminationReport?.budget, 0.75)
        XCTAssertEqual(delegate.lastTerminationReport?.steps, [])
        XCTAssertEqual(delegate.lastTerminationReport?.didRemoveEventMonitors, true)
    }

    func testCriticalBarrierUsesOneAbsoluteDeadlineInsteadOfAccumulatingTimeouts() {
        let clock = ManualClock(100)
        var offeredTimeouts: [TimeInterval] = []
        var cleanupCount = 0
        let durations: [AppDelegate.CriticalPersistenceStep: TimeInterval] = [
            .libraryQueue: 0.20,
            .playlists: 0.30,
            .playbackWeights: 0.30,
            .playbackState: 0,
            .typedPreferences: 0,
        ]
        let operations = AppDelegate.CriticalPersistenceStep.allCases.reversed().map { step in
            AppDelegate.CriticalPersistenceOperation(step: step) { remaining in
                offeredTimeouts.append(remaining)
                clock.advance(by: durations[step] ?? 0)
                return .durable
            }
        }

        let report = AppDelegate.runCriticalTerminationBarrier(
            timeout: 0.75,
            now: { clock.value },
            operations: operations,
            cleanup: { cleanupCount += 1 }
        )

        XCTAssertEqual(offeredTimeouts.count, 3)
        XCTAssertEqual(offeredTimeouts[0], 0.75, accuracy: 0.000_001)
        XCTAssertEqual(offeredTimeouts[1], 0.55, accuracy: 0.000_001)
        XCTAssertEqual(offeredTimeouts[2], 0.25, accuracy: 0.000_001)
        XCTAssertEqual(report.steps.map(\.step), AppDelegate.CriticalPersistenceStep.allCases)
        XCTAssertEqual(
            report.steps.map(\.outcome),
            [.durable, .durable, .timedOut, .skippedNoRemainingTime, .skippedNoRemainingTime]
        )
        XCTAssertEqual(report.elapsed, 0.80, accuracy: 0.000_001)
        XCTAssertFalse(report.didMeetDeadline)
        XCTAssertFalse(report.isFullyDurable)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(report.didRemoveEventMonitors)
    }

    func testCriticalBarrierChargesPreparationTimeFromFreezeEntry() {
        let clock = ManualClock(100.30)
        var offeredTimeout: TimeInterval?
        let deadline = AppDelegate.TerminationDeadline(
            startedAt: 100,
            timeout: 0.75
        )
        let report = AppDelegate.runCriticalTerminationBarrier(
            deadline: deadline,
            now: { clock.value },
            operations: [
                .init(step: .libraryQueue) { remaining in
                    offeredTimeout = remaining
                    clock.advance(by: 0.50)
                    return .durable
                },
            ],
            cleanup: {}
        )

        XCTAssertEqual(offeredTimeout ?? -1, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(report.preparationElapsed, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(report.barrierElapsed, 0.50, accuracy: 0.000_001)
        XCTAssertEqual(report.elapsed, 0.80, accuracy: 0.000_001)
        XCTAssertEqual(report.steps.first?.outcome, .timedOut)
        XCTAssertFalse(report.didMeetDeadline)
        XCTAssertFalse(report.isFullyDurable)
    }

    func testExpiredPreparationSkipsEveryPersistenceOperation() {
        let clock = ManualClock(50.90)
        var attempted = 0
        let report = AppDelegate.runCriticalTerminationBarrier(
            deadline: .init(startedAt: 50, timeout: 0.75),
            now: { clock.value },
            operations: AppDelegate.CriticalPersistenceStep.allCases.map { step in
                .init(step: step) { _ in
                    attempted += 1
                    return .durable
                }
            },
            cleanup: {}
        )

        XCTAssertEqual(attempted, 0)
        XCTAssertEqual(
            report.steps.map(\.outcome),
            Array(
                repeating: AppDelegate.CriticalPersistenceOutcome.skippedNoRemainingTime,
                count: AppDelegate.CriticalPersistenceStep.allCases.count
            )
        )
        XCTAssertEqual(report.preparationElapsed, 0.90, accuracy: 0.000_001)
        XCTAssertFalse(report.didMeetDeadline)
    }

    func testCriticalBarrierContinuesAfterStoreFailuresAndStillCleansUp() {
        var attempted: [AppDelegate.CriticalPersistenceStep] = []
        var cleanupCount = 0
        let operations: [AppDelegate.CriticalPersistenceOperation] = [
            .init(step: .libraryQueue) { _ in
                attempted.append(.libraryQueue)
                return .failed
            },
            .init(step: .playlists) { _ in
                attempted.append(.playlists)
                throw ExpectedFailure.persistence
            },
            .init(step: .playbackWeights) { _ in
                attempted.append(.playbackWeights)
                return .durable
            },
            .init(step: .playbackState) { _ in
                attempted.append(.playbackState)
                return .failed
            },
            .init(step: .typedPreferences) { _ in
                attempted.append(.typedPreferences)
                return .durable
            },
        ]

        let report = AppDelegate.runCriticalTerminationBarrier(
            now: { 50 },
            operations: operations,
            cleanup: { cleanupCount += 1 }
        )

        XCTAssertEqual(attempted, AppDelegate.CriticalPersistenceStep.allCases)
        XCTAssertEqual(
            report.steps.map(\.outcome),
            [.failed, .failed, .durable, .failed, .durable]
        )
        XCTAssertFalse(report.isFullyDurable)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(report.didRemoveEventMonitors)
    }

    func testCriticalBarrierCoalescesAnExplicitSharedDurabilityUnit() {
        let sharedStore = NSObject()
        let identity = AppDelegate.TerminationStoreIdentity(sharedStore)
        var attempted: [AppDelegate.CriticalPersistenceStep] = []
        let operations: [AppDelegate.CriticalPersistenceOperation] = [
            .init(step: .playlists, coalescingIdentity: identity) { _ in
                attempted.append(.playlists)
                return .durable
            },
            .init(step: .playbackWeights, coalescingIdentity: identity) { _ in
                attempted.append(.playbackWeights)
                return .durable
            },
        ]

        let report = AppDelegate.runCriticalTerminationBarrier(
            operations: operations,
            cleanup: {}
        )

        XCTAssertEqual(attempted, [.playlists])
        XCTAssertEqual(report.steps.map(\.step), [.playlists, .playbackWeights])
        XCTAssertEqual(report.steps.map(\.outcome), [.durable, .skippedCoalesced])
        XCTAssertTrue(report.isFullyDurable)
    }

    func testCriticalStepContractContainsNoDerivedCaches() {
        XCTAssertEqual(
            AppDelegate.CriticalPersistenceStep.allCases,
            [.libraryQueue, .playlists, .playbackWeights, .playbackState, .typedPreferences]
        )
    }
}
