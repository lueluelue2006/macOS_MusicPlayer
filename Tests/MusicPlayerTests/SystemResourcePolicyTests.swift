import XCTest
@testable import MusicPlayer

final class SystemResourcePolicyTests: XCTestCase {
    private let policy = SystemResourcePolicy()

    func testHealthyIdleACSnapshotAllowsBackgroundAnalysis() {
        XCTAssertEqual(
            policy.decision(
                forAutomaticJob: .backgroundAnalysis,
                snapshot: makeSnapshot()
            ),
            .allowed
        )
    }

    func testPowerLowPowerThermalAndMemoryEachBlockAutomaticWork() {
        XCTAssertEqual(
            decision(powerSource: .battery),
            .blocked(.acPowerRequired(actual: .battery))
        )
        XCTAssertEqual(
            decision(powerSource: .unknown),
            .blocked(.acPowerRequired(actual: .unknown))
        )
        XCTAssertEqual(
            decision(lowPowerMode: true),
            .blocked(.lowPowerModeEnabled)
        )
        XCTAssertEqual(
            decision(thermalLevel: .fair),
            .blocked(.thermalLevelTooHigh(actual: .fair, maximum: .nominal))
        )
        XCTAssertEqual(
            decision(memoryPressure: .warning),
            .blocked(.memoryPressureTooHigh(actual: .warning, maximum: .normal))
        )
    }

    func testBothIdleWindowsAreRequired() {
        XCTAssertEqual(
            decision(systemIdle: 59),
            .blocked(.insufficientSystemIdle(required: 60, actual: 59))
        )
        XCTAssertEqual(
            decision(applicationIdle: 59),
            .blocked(.insufficientApplicationIdle(required: 60, actual: 59))
        )
    }

    func testRequirementsCanPermitBatteryFairThermalAndWarningPressure() {
        let requirements = AutomaticJobRequirements(
            requiresACPower: false,
            maximumThermalLevel: .fair,
            maximumMemoryPressure: .warning,
            minimumSystemIdleDuration: 5,
            minimumApplicationIdleDuration: 10
        )
        let snapshot = makeSnapshot(
            powerSource: .battery,
            thermalLevel: .fair,
            memoryPressure: .warning,
            systemIdle: 5,
            applicationIdle: 10
        )

        XCTAssertTrue(policy.allowsAutomaticJob(requirements, snapshot: snapshot))
    }

    func testInvalidObservedIdleDurationIsConservativelyTreatedAsZero() {
        XCTAssertEqual(
            decision(systemIdle: .infinity),
            .blocked(.insufficientSystemIdle(required: 60, actual: 0))
        )
        XCTAssertEqual(
            decision(applicationIdle: -.infinity),
            .blocked(.insufficientApplicationIdle(required: 60, actual: 0))
        )
    }

    func testInjectedProviderObservesMemoryPressureStateChanges() {
        let memoryState = SystemMemoryPressureState(initialValue: .normal)
        let provider = SystemResourceSnapshotProvider {
            self.makeSnapshot(memoryPressure: memoryState.current)
        }

        XCTAssertEqual(provider.currentSnapshot().memoryPressure, .normal)
        memoryState.update(.critical)
        XCTAssertEqual(provider.currentSnapshot().memoryPressure, .critical)
    }

    func testApplicationActivityStateAdvancesMonotonically() {
        let state = SystemResourceActivityState(
            lastApplicationInteractionAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(
            state.applicationIdleDuration(now: Date(timeIntervalSince1970: 160)),
            60
        )

        state.recordApplicationInteraction(at: Date(timeIntervalSince1970: 150))
        state.recordApplicationInteraction(at: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(
            state.applicationIdleDuration(now: Date(timeIntervalSince1970: 180)),
            30,
            "An older publisher delivery must not move the idle clock backwards"
        )
    }

    private func decision(
        powerSource: SystemPowerSource = .acPower,
        lowPowerMode: Bool = false,
        thermalLevel: SystemThermalLevel = .nominal,
        memoryPressure: SystemMemoryPressure = .normal,
        systemIdle: TimeInterval = 120,
        applicationIdle: TimeInterval = 120
    ) -> AutomaticJobDecision {
        policy.decision(
            forAutomaticJob: .backgroundAnalysis,
            snapshot: makeSnapshot(
                powerSource: powerSource,
                lowPowerMode: lowPowerMode,
                thermalLevel: thermalLevel,
                memoryPressure: memoryPressure,
                systemIdle: systemIdle,
                applicationIdle: applicationIdle
            )
        )
    }

    private func makeSnapshot(
        powerSource: SystemPowerSource = .acPower,
        lowPowerMode: Bool = false,
        thermalLevel: SystemThermalLevel = .nominal,
        memoryPressure: SystemMemoryPressure = .normal,
        systemIdle: TimeInterval = 120,
        applicationIdle: TimeInterval = 120
    ) -> SystemResourceSnapshot {
        SystemResourceSnapshot(
            powerSource: powerSource,
            isLowPowerModeEnabled: lowPowerMode,
            thermalLevel: thermalLevel,
            memoryPressure: memoryPressure,
            systemIdleDuration: systemIdle,
            applicationIdleDuration: applicationIdle
        )
    }
}
