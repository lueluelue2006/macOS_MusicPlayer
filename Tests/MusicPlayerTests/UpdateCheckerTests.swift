import XCTest
@testable import MusicPlayer

final class UpdateCheckerTests: XCTestCase {
    func testPrefersAppleSiliconDMGWhenReleaseContainsBothArchitectures() {
        let selected = UpdateChecker.preferredDMGAssetName(from: [
            "MusicPlayer-v4.3.5-intel.dmg",
            "SHA256SUMS.txt",
            "MusicPlayer-v4.3.5.dmg"
        ], version: "4.3.5")

        XCTAssertEqual(selected, "MusicPlayer-v4.3.5.dmg")
    }

    func testRejectsIntelOnlyDMGs() {
        let selected = UpdateChecker.preferredDMGAssetName(from: [
            "MusicPlayer-v4.3.5-INTEL-signed.DMG",
            "MusicPlayer-v4.3.5-x86_64.dmg",
            "MusicPlayer-v4.3.5-x64.dmg"
        ], version: "4.3.5")

        XCTAssertNil(selected)
    }

    func testIgnoresNonDMGAndMismatchedVersionAssets() {
        let selected = UpdateChecker.preferredDMGAssetName(from: [
            "MusicPlayer-v4.3.5.zip",
            "MusicPlayer-v4.3.4.dmg",
            "MusicPlayer-v4.3.5-arm64.dmg",
            "MusicPlayer-v4.3.5.DMG"
        ], version: "4.3.5")

        XCTAssertEqual(selected, "MusicPlayer-v4.3.5.DMG")
    }
}
