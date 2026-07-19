import AppKit
import Combine
import Foundation

enum ExternalVolumeRefreshReason: String, Equatable, Sendable {
    case initial
    case mounted
    case unmounted
    case renamed
    case manual
}

struct ExternalVolumeSnapshot: Equatable, Sendable {
    let generation: UInt64
    let volumes: [MountedLibraryVolume]

    static let empty = ExternalVolumeSnapshot(generation: 0, volumes: [])

    func uniqueVolume(identifier: String) -> MountedLibraryVolume? {
        let matches = volumes.filter { $0.identifier == identifier }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

struct ExternalVolumeDiff: Equatable, Sendable {
    let reason: ExternalVolumeRefreshReason
    let snapshot: ExternalVolumeSnapshot
    let addedTopologyKeys: Set<String>
    let removedTopologyKeys: Set<String>
    let changedTopologyKeys: Set<String>

    var hasChanges: Bool {
        !addedTopologyKeys.isEmpty
            || !removedTopologyKeys.isEmpty
            || !changedTopologyKeys.isEmpty
    }
}

enum ExternalVolumeCoordinatorEvent: Equatable, Sendable {
    case willUnmount(MountedLibraryVolume?)
    case topologyChanged(ExternalVolumeDiff)
    case refreshFailed(reason: ExternalVolumeRefreshReason, message: String)
}

/// Coalesces workspace mount notifications into small topology snapshots. It
/// intentionally tracks mounted roots only; callers can index locations by
/// volume identifier without touching every track on mount or unmount.
@MainActor
final class ExternalVolumeCoordinator: ObservableObject {
    @Published private(set) var snapshot: ExternalVolumeSnapshot = .empty

    var onEvent: ((ExternalVolumeCoordinatorEvent) -> Void)?

    private let volumeProvider: any MountedLibraryVolumeProviding
    private let debounceNanoseconds: UInt64
    private let workspaceNotificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var isStarted = false
    private var callbackGeneration: UInt64 = 0
    private var stoppedForTerminationGeneration: UInt64?

    init(
        volumeProvider: any MountedLibraryVolumeProviding = FoundationMountedLibraryVolumeProvider(),
        debounceInterval: TimeInterval = 0.35,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.volumeProvider = volumeProvider
        self.debounceNanoseconds = Self.nanoseconds(for: debounceInterval)
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    func start() {
        guard !isStarted, stoppedForTerminationGeneration == nil else { return }
        callbackGeneration &+= 1
        isStarted = true
        registerWorkspaceObservers(callbackGeneration: callbackGeneration)
        refreshNow(reason: .initial, emitWhenUnchanged: true)
    }

    func stop() {
        callbackGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        for token in observerTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        isStarted = false
    }

    /// Synchronously invalidates observer and debounce callbacks for the app's
    /// termination generation. It is safe to invoke repeatedly from a
    /// termination lifecycle hook and never waits for a refresh task.
    func stopForTermination(generation: UInt64) {
        if let stoppedGeneration = stoppedForTerminationGeneration {
            if generation > stoppedGeneration {
                stoppedForTerminationGeneration = generation
            }
            return
        }
        stoppedForTerminationGeneration = generation
        stop()
    }

    func requestRefresh(reason: ExternalVolumeRefreshReason) {
        guard isStarted, stoppedForTerminationGeneration == nil else { return }
        let generation = callbackGeneration
        requestRefresh(reason: reason, callbackGeneration: generation)
    }

    private func requestRefresh(
        reason: ExternalVolumeRefreshReason,
        callbackGeneration: UInt64
    ) {
        guard isCallbackActive(generation: callbackGeneration) else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: self.debounceNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard self.isCallbackActive(generation: callbackGeneration) else { return }
            self.refreshTask = nil
            self.refreshNow(reason: reason)
        }
    }

    func refreshNow(
        reason: ExternalVolumeRefreshReason = .manual,
        emitWhenUnchanged: Bool = false
    ) {
        guard isStarted, stoppedForTerminationGeneration == nil else { return }
        let volumes: [MountedLibraryVolume]
        do {
            volumes = try Self.normalizedVolumes(volumeProvider.mountedVolumes())
        } catch {
            onEvent?(
                .refreshFailed(
                    reason: reason,
                    message: (error as NSError).localizedDescription
                )
            )
            return
        }

        let previous = snapshot
        let next = ExternalVolumeSnapshot(
            generation: previous.generation &+ 1,
            volumes: volumes
        )
        let diff = Self.diff(from: previous, to: next, reason: reason)
        guard diff.hasChanges || emitWhenUnchanged || previous.generation == 0 else { return }
        snapshot = next
        onEvent?(.topologyChanged(diff))
    }

    /// Immediate pre-unmount signal used by playback integration to pause and
    /// release file handles before the volume disappears. Topology mutation is
    /// still driven by the debounced did-unmount refresh.
    func signalWillUnmount(volumeURL: URL?) {
        guard isStarted, stoppedForTerminationGeneration == nil else { return }
        let standardized = volumeURL?.standardizedFileURL
        let volume = standardized.flatMap { target in
            if let matched = snapshot.volumes.first(where: { volume in
                volume.url.standardizedFileURL.path == target.path
            }) {
                return matched
            }
            return MountedLibraryVolume(
                url: target,
                identifier: nil,
                displayName: target.lastPathComponent,
                isRemovable: true,
                isEjectable: true,
                isLocal: false
            )
        }
        onEvent?(.willUnmount(volume))
    }

    private func registerWorkspaceObservers(callbackGeneration: UInt64) {
        let topologyNotifications: [(Notification.Name, ExternalVolumeRefreshReason)] = [
            (NSWorkspace.didMountNotification, .mounted),
            (NSWorkspace.didUnmountNotification, .unmounted),
            (NSWorkspace.didRenameVolumeNotification, .renamed)
        ]
        for (name, reason) in topologyNotifications {
            let token = workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.requestRefresh(
                        reason: reason,
                        callbackGeneration: callbackGeneration
                    )
                }
            }
            observerTokens.append(token)
        }

        let willUnmountToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                guard self?.isCallbackActive(generation: callbackGeneration) == true else {
                    return
                }
                self?.signalWillUnmount(volumeURL: url)
            }
        }
        observerTokens.append(willUnmountToken)
    }

    private func isCallbackActive(generation: UInt64) -> Bool {
        isStarted
            && stoppedForTerminationGeneration == nil
            && callbackGeneration == generation
    }

    private static func normalizedVolumes(
        _ volumes: [MountedLibraryVolume]
    ) throws -> [MountedLibraryVolume] {
        var seen = Set<String>()
        let unique = volumes.filter { volume in
            let key = "\(volume.topologyKey)\u{0}\(volume.url.path)"
            return seen.insert(key).inserted
        }
        return unique.sorted {
            if $0.topologyKey == $1.topologyKey {
                return $0.url.path < $1.url.path
            }
            return $0.topologyKey < $1.topologyKey
        }
    }

    private static func diff(
        from previous: ExternalVolumeSnapshot,
        to next: ExternalVolumeSnapshot,
        reason: ExternalVolumeRefreshReason
    ) -> ExternalVolumeDiff {
        let previousGroups = Dictionary(grouping: previous.volumes, by: \.topologyKey)
        let nextGroups = Dictionary(grouping: next.volumes, by: \.topologyKey)
        let previousKeys = Set(previousGroups.keys)
        let nextKeys = Set(nextGroups.keys)
        let sharedKeys = previousKeys.intersection(nextKeys)
        let changed = Set(sharedKeys.filter { key in
            previousGroups[key] != nextGroups[key]
        })
        return ExternalVolumeDiff(
            reason: reason,
            snapshot: next,
            addedTopologyKeys: nextKeys.subtracting(previousKeys),
            removedTopologyKeys: previousKeys.subtracting(nextKeys),
            changedTopologyKeys: changed
        )
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let capped = min(interval, 60)
        return UInt64((capped * 1_000_000_000).rounded())
    }

    deinit {
        refreshTask?.cancel()
        for token in observerTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
    }
}
