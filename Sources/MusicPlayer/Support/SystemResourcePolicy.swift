import Foundation
import Dispatch
import CoreGraphics
import IOKit.ps

enum SystemPowerSource: Int, Sendable, Equatable {
    case acPower
    case battery
    case unknown
}

enum SystemThermalLevel: Int, Sendable, Equatable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
    case unknown = 4

    static func < (lhs: SystemThermalLevel, rhs: SystemThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .unknown
        }
    }
}

enum SystemMemoryPressure: Int, Sendable, Equatable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: SystemMemoryPressure, rhs: SystemMemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Thread-safe state shared by the live memory-pressure monitor and resource
/// snapshot providers. Tests can inject and update the same state without
/// installing a DispatchSource.
final class SystemMemoryPressureState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: SystemMemoryPressure

    init(initialValue: SystemMemoryPressure = .normal) {
        storedValue = initialValue
    }

    var current: SystemMemoryPressure {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func update(_ value: SystemMemoryPressure) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

/// Lightweight process-wide memory-pressure monitor backed by Dispatch. Power
/// source detection is handled separately by the live snapshot provider.
final class SystemMemoryPressureMonitor: @unchecked Sendable {
    let state: SystemMemoryPressureState

    private let source: DispatchSourceMemoryPressure

    init(
        state: SystemMemoryPressureState = SystemMemoryPressureState(),
        queue: DispatchQueue = DispatchQueue(
            label: "musicplayer.system-memory-pressure",
            qos: .utility
        )
    ) {
        self.state = state
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.source.data
            if data.contains(.critical) {
                self.state.update(.critical)
            } else if data.contains(.warning) {
                self.state.update(.warning)
            } else if data.contains(.normal) {
                self.state.update(.normal)
            }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Process-wide application activity used by automatic background jobs. The
/// queue/player layer records user interaction once; every scheduler then sees
/// the same idle window without reaching back into UI-owned observable state.
final class SystemResourceActivityState: @unchecked Sendable {
    static let shared = SystemResourceActivityState()

    private let lock = NSLock()
    private var lastApplicationInteractionAt: Date

    init(lastApplicationInteractionAt: Date = Date()) {
        self.lastApplicationInteractionAt = lastApplicationInteractionAt
    }

    func recordApplicationInteraction(at date: Date = Date()) {
        lock.lock()
        if date > lastApplicationInteractionAt {
            lastApplicationInteractionAt = date
        }
        lock.unlock()
    }

    func applicationIdleDuration(now: Date = Date()) -> TimeInterval {
        lock.lock()
        let lastInteraction = lastApplicationInteractionAt
        lock.unlock()
        let duration = now.timeIntervalSince(lastInteraction)
        guard duration.isFinite else { return 0 }
        return max(0, duration)
    }
}

struct SystemResourceSnapshot: Sendable, Equatable {
    let powerSource: SystemPowerSource
    let isLowPowerModeEnabled: Bool
    let thermalLevel: SystemThermalLevel
    let memoryPressure: SystemMemoryPressure
    let systemIdleDuration: TimeInterval
    let applicationIdleDuration: TimeInterval

    init(
        powerSource: SystemPowerSource,
        isLowPowerModeEnabled: Bool,
        thermalLevel: SystemThermalLevel,
        memoryPressure: SystemMemoryPressure,
        systemIdleDuration: TimeInterval,
        applicationIdleDuration: TimeInterval
    ) {
        self.powerSource = powerSource
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalLevel = thermalLevel
        self.memoryPressure = memoryPressure
        self.systemIdleDuration = systemIdleDuration
        self.applicationIdleDuration = applicationIdleDuration
    }
}

/// Type-erased, synchronous provider. Live snapshots use IOKit power-source
/// state and CoreGraphics idle counters; every input remains injectable.
struct SystemResourceSnapshotProvider: Sendable {
    private let capture: @Sendable () -> SystemResourceSnapshot

    init(capture: @escaping @Sendable () -> SystemResourceSnapshot) {
        self.capture = capture
    }

    func currentSnapshot() -> SystemResourceSnapshot {
        capture()
    }

    static func constant(_ snapshot: SystemResourceSnapshot) -> Self {
        Self { snapshot }
    }

    static func live(
        powerSource: @escaping @Sendable () -> SystemPowerSource = {
            livePowerSource()
        },
        systemIdleDuration: @escaping @Sendable () -> TimeInterval = {
            liveSystemIdleDuration()
        },
        applicationIdleDuration: @escaping @Sendable () -> TimeInterval = {
            SystemResourceActivityState.shared.applicationIdleDuration()
        },
        memoryPressureMonitor: SystemMemoryPressureMonitor = SystemMemoryPressureMonitor()
    ) -> Self {
        Self {
            let processInfo = ProcessInfo.processInfo
            return SystemResourceSnapshot(
                powerSource: powerSource(),
                isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                thermalLevel: SystemThermalLevel(processInfo.thermalState),
                memoryPressure: memoryPressureMonitor.state.current,
                systemIdleDuration: systemIdleDuration(),
                applicationIdleDuration: applicationIdleDuration()
            )
        }
    }

    static func livePowerSource() -> SystemPowerSource {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(information)?.takeUnretainedValue()
        else { return .unknown }
        let value = source as String
        if value == kIOPSACPowerValue { return .acPower }
        if value == kIOPSBatteryPowerValue { return .battery }
        return .unknown
    }

    static func liveSystemIdleDuration() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .flagsChanged,
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        let duration = eventTypes.reduce(TimeInterval.greatestFiniteMagnitude) {
            minimum, eventType in
            min(
                minimum,
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: eventType
                )
            )
        }
        guard duration.isFinite,
              duration != .greatestFiniteMagnitude else { return 0 }
        return max(0, duration)
    }
}

struct AutomaticJobRequirements: Sendable, Equatable {
    let requiresACPower: Bool
    let maximumThermalLevel: SystemThermalLevel
    let maximumMemoryPressure: SystemMemoryPressure
    let minimumSystemIdleDuration: TimeInterval
    let minimumApplicationIdleDuration: TimeInterval

    init(
        requiresACPower: Bool = true,
        maximumThermalLevel: SystemThermalLevel = .nominal,
        maximumMemoryPressure: SystemMemoryPressure = .normal,
        minimumSystemIdleDuration: TimeInterval = 60,
        minimumApplicationIdleDuration: TimeInterval = 60
    ) {
        self.requiresACPower = requiresACPower
        self.maximumThermalLevel = maximumThermalLevel
        self.maximumMemoryPressure = maximumMemoryPressure
        self.minimumSystemIdleDuration = Self.normalizedDuration(minimumSystemIdleDuration)
        self.minimumApplicationIdleDuration = Self.normalizedDuration(
            minimumApplicationIdleDuration
        )
    }

    static let backgroundAnalysis = AutomaticJobRequirements()

    private static func normalizedDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}

enum AutomaticJobBlockReason: Sendable, Equatable {
    case acPowerRequired(actual: SystemPowerSource)
    case lowPowerModeEnabled
    case thermalLevelTooHigh(actual: SystemThermalLevel, maximum: SystemThermalLevel)
    case memoryPressureTooHigh(actual: SystemMemoryPressure, maximum: SystemMemoryPressure)
    case insufficientSystemIdle(required: TimeInterval, actual: TimeInterval)
    case insufficientApplicationIdle(required: TimeInterval, actual: TimeInterval)
}

enum AutomaticJobDecision: Sendable, Equatable {
    case allowed
    case blocked(AutomaticJobBlockReason)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

struct SystemResourcePolicy: Sendable {
    func decision(
        forAutomaticJob requirements: AutomaticJobRequirements,
        snapshot: SystemResourceSnapshot
    ) -> AutomaticJobDecision {
        if requirements.requiresACPower, snapshot.powerSource != .acPower {
            return .blocked(.acPowerRequired(actual: snapshot.powerSource))
        }
        if snapshot.isLowPowerModeEnabled {
            return .blocked(.lowPowerModeEnabled)
        }
        if snapshot.thermalLevel > requirements.maximumThermalLevel {
            return .blocked(.thermalLevelTooHigh(
                actual: snapshot.thermalLevel,
                maximum: requirements.maximumThermalLevel
            ))
        }
        if snapshot.memoryPressure > requirements.maximumMemoryPressure {
            return .blocked(.memoryPressureTooHigh(
                actual: snapshot.memoryPressure,
                maximum: requirements.maximumMemoryPressure
            ))
        }

        let systemIdle = normalizedObservedDuration(snapshot.systemIdleDuration)
        if systemIdle < requirements.minimumSystemIdleDuration {
            return .blocked(.insufficientSystemIdle(
                required: requirements.minimumSystemIdleDuration,
                actual: systemIdle
            ))
        }

        let applicationIdle = normalizedObservedDuration(snapshot.applicationIdleDuration)
        if applicationIdle < requirements.minimumApplicationIdleDuration {
            return .blocked(.insufficientApplicationIdle(
                required: requirements.minimumApplicationIdleDuration,
                actual: applicationIdle
            ))
        }
        return .allowed
    }

    func allowsAutomaticJob(
        _ requirements: AutomaticJobRequirements,
        snapshot: SystemResourceSnapshot
    ) -> Bool {
        decision(forAutomaticJob: requirements, snapshot: snapshot).isAllowed
    }

    private func normalizedObservedDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
