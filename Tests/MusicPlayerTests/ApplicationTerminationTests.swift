import AppKit
import XCTest
@testable import MusicPlayer

final class ApplicationTerminationTests: XCTestCase {
    @MainActor
    func testAppDelegateTerminatesWithoutDeferringToMainActor() {
        let delegate = AppDelegate()

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
    }
}
