import XCTest
@testable import MusicPlayer

final class RegressionHarnessTests: XCTestCase {
    func testInternalRegressionHarnessPasses() async {
        let passed = await RegressionTests.runAll()
        XCTAssertTrue(passed)
    }
}
