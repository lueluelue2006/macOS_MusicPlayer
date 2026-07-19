import Foundation
import XCTest
@testable import MusicPlayer

@MainActor
final class ExternalVolumeCoordinatorTests: XCTestCase {
    func testInitialRefreshPublishesBoundedSnapshot() {
        let provider = CoordinatorFakeVolumeProvider(volumes: [volume(id: "B"), volume(id: "A")])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 0,
            workspaceNotificationCenter: NotificationCenter()
        )
        var events: [ExternalVolumeCoordinatorEvent] = []
        coordinator.onEvent = { events.append($0) }

        coordinator.start()
        defer { coordinator.stop() }

        XCTAssertEqual(coordinator.snapshot.generation, 1)
        XCTAssertEqual(coordinator.snapshot.volumes.map(\.identifier), ["A", "B"])
        guard case .topologyChanged(let diff) = events.first else {
            return XCTFail("Expected initial topology event")
        }
        XCTAssertEqual(diff.reason, .initial)
        XCTAssertEqual(diff.addedTopologyKeys, ["id:A", "id:B"])
    }

    func testDiffClassifiesAddRemoveAndRename() {
        let original = volume(id: "A", path: "/Volumes/Old", name: "Old")
        let provider = CoordinatorFakeVolumeProvider(volumes: [original, volume(id: "B")])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 0,
            workspaceNotificationCenter: NotificationCenter()
        )
        var lastDiff: ExternalVolumeDiff?
        coordinator.onEvent = { event in
            if case .topologyChanged(let diff) = event { lastDiff = diff }
        }
        coordinator.start()
        defer { coordinator.stop() }

        provider.setVolumes([
            volume(id: "A", path: "/Volumes/New", name: "New"),
            volume(id: "C")
        ])
        coordinator.refreshNow(reason: .renamed)

        let diff = try? XCTUnwrap(lastDiff)
        XCTAssertEqual(diff?.changedTopologyKeys, ["id:A"])
        XCTAssertEqual(diff?.removedTopologyKeys, ["id:B"])
        XCTAssertEqual(diff?.addedTopologyKeys, ["id:C"])
    }

    func testDebounceCoalescesMountStormToFinalProviderState() async throws {
        let provider = CoordinatorFakeVolumeProvider(volumes: [])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 0.02,
            workspaceNotificationCenter: NotificationCenter()
        )
        var topologyEventCount = 0
        coordinator.onEvent = { event in
            if case .topologyChanged = event { topologyEventCount += 1 }
        }
        coordinator.start()
        defer { coordinator.stop() }

        provider.setVolumes([volume(id: "A")])
        coordinator.requestRefresh(reason: .mounted)
        provider.setVolumes([volume(id: "A"), volume(id: "B")])
        coordinator.requestRefresh(reason: .mounted)
        provider.setVolumes([volume(id: "B")])
        coordinator.requestRefresh(reason: .unmounted)

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(topologyEventCount, 2, "initial + one coalesced topology event")
        XCTAssertEqual(coordinator.snapshot.volumes.map(\.identifier), ["B"])
    }

    func testWillUnmountPublishesImmediateMatchedVolume() {
        let expected = volume(id: "A")
        let provider = CoordinatorFakeVolumeProvider(volumes: [expected])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 1,
            workspaceNotificationCenter: NotificationCenter()
        )
        var event: ExternalVolumeCoordinatorEvent?
        coordinator.start()
        coordinator.onEvent = { event = $0 }
        defer { coordinator.stop() }

        coordinator.signalWillUnmount(volumeURL: expected.url)

        XCTAssertEqual(event, .willUnmount(expected))
        XCTAssertEqual(coordinator.snapshot.volumes, [expected])
    }

    func testWillUnmountWithoutSnapshotMatchRetainsStandardizedURL() {
        let provider = CoordinatorFakeVolumeProvider(volumes: [volume(id: "A")])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 1,
            workspaceNotificationCenter: NotificationCenter()
        )
        var event: ExternalVolumeCoordinatorEvent?
        coordinator.start()
        coordinator.onEvent = { event = $0 }
        defer { coordinator.stop() }

        let reportedURL = URL(
            fileURLWithPath: "/Volumes/Missing/../External",
            isDirectory: true
        )
        coordinator.signalWillUnmount(volumeURL: reportedURL)

        XCTAssertEqual(
            event,
            .willUnmount(
                MountedLibraryVolume(
                    url: reportedURL.standardizedFileURL,
                    identifier: nil,
                    displayName: "External",
                    isRemovable: true,
                    isEjectable: true,
                    isLocal: false
                )
            )
        )
    }

    func testDuplicateIdentifiersRemainAmbiguous() {
        let provider = CoordinatorFakeVolumeProvider(volumes: [
            volume(id: "same", path: "/Volumes/One"),
            volume(id: "same", path: "/Volumes/Two")
        ])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 0,
            workspaceNotificationCenter: NotificationCenter()
        )
        coordinator.start()
        defer { coordinator.stop() }

        XCTAssertNil(coordinator.snapshot.uniqueVolume(identifier: "same"))
        XCTAssertEqual(coordinator.snapshot.volumes.count, 2)
    }

    func testProviderFailurePreservesLastGoodSnapshot() {
        let provider = CoordinatorFakeVolumeProvider(volumes: [volume(id: "A")])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 0,
            workspaceNotificationCenter: NotificationCenter()
        )
        coordinator.start()
        let original = coordinator.snapshot
        var failure: ExternalVolumeCoordinatorEvent?
        coordinator.onEvent = { failure = $0 }
        defer { coordinator.stop() }

        provider.setError(CoordinatorFakeError.unavailable)
        coordinator.refreshNow(reason: .manual)

        XCTAssertEqual(coordinator.snapshot, original)
        guard case .refreshFailed(let reason, _) = failure else {
            return XCTFail("Expected refresh failure")
        }
        XCTAssertEqual(reason, .manual)
    }

    func testTerminationStopCancelsQueuedRefreshAndRejectsLateCallbacks() async throws {
        let initial = volume(id: "A")
        let provider = CoordinatorFakeVolumeProvider(volumes: [initial])
        let coordinator = ExternalVolumeCoordinator(
            volumeProvider: provider,
            debounceInterval: 0.02,
            workspaceNotificationCenter: NotificationCenter()
        )
        var events: [ExternalVolumeCoordinatorEvent] = []
        coordinator.onEvent = { events.append($0) }
        coordinator.start()
        events.removeAll()

        provider.setVolumes([volume(id: "B")])
        coordinator.requestRefresh(reason: .mounted)
        coordinator.stopForTermination(generation: 7)
        coordinator.stopForTermination(generation: 7)
        coordinator.stopForTermination(generation: 6)
        coordinator.refreshNow(reason: .manual)
        coordinator.signalWillUnmount(volumeURL: initial.url)
        coordinator.start()

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(coordinator.snapshot.volumes, [initial])
        XCTAssertTrue(events.isEmpty)
    }

    private func volume(
        id: String,
        path: String? = nil,
        name: String? = nil
    ) -> MountedLibraryVolume {
        MountedLibraryVolume(
            url: URL(
                fileURLWithPath: path ?? "/Volumes/\(id)",
                isDirectory: true
            ),
            identifier: id,
            displayName: name ?? id,
            isRemovable: true,
            isEjectable: true
        )
    }
}

private enum CoordinatorFakeError: Error {
    case unavailable
}

private final class CoordinatorFakeVolumeProvider: MountedLibraryVolumeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var volumes: [MountedLibraryVolume]
    private var error: Error?

    init(volumes: [MountedLibraryVolume]) {
        self.volumes = volumes
    }

    func setVolumes(_ volumes: [MountedLibraryVolume]) {
        lock.lock()
        self.volumes = volumes
        error = nil
        lock.unlock()
    }

    func setError(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func mountedVolumes() throws -> [MountedLibraryVolume] {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        return volumes
    }
}
