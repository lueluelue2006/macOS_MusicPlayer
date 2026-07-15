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

// MARK: - Version Parsing and Comparison Tests

final class VersionTests: XCTestCase {
    func testParseSimpleTwoComponentVersion() throws {
        let version = try XCTUnwrap(Version.parse("3.2"))
        XCTAssertEqual(version.components, [3, 2])
    }

    func testParseThreeComponentVersion() throws {
        let version = try XCTUnwrap(Version.parse("4.5.6"))
        XCTAssertEqual(version.components, [4, 5, 6])
    }

    func testParseVersionWithVPrefix() throws {
        let version = try XCTUnwrap(Version.parse("v1.2.3"))
        XCTAssertEqual(version.components, [1, 2, 3])
    }

    func testParseVersionWithBetaSuffix() throws {
        let version = try XCTUnwrap(Version.parse("2.5.0-beta"))
        XCTAssertEqual(version.components, [2, 5, 0])
    }

    func testParseVersionWithAlphaSuffix() throws {
        let version = try XCTUnwrap(Version.parse("3.0.0-alpha.1"))
        XCTAssertEqual(version.components, [3, 0, 0])
    }

    func testParseVersionWithRCSuffix() throws {
        let version = try XCTUnwrap(Version.parse("1.0.0-rc.2"))
        XCTAssertEqual(version.components, [1, 0, 0])
    }

    func testParseSingleComponentVersion() throws {
        let version = try XCTUnwrap(Version.parse("5"))
        XCTAssertEqual(version.components, [5])
    }

    func testParseFourComponentVersion() throws {
        let version = try XCTUnwrap(Version.parse("1.2.3.4"))
        XCTAssertEqual(version.components, [1, 2, 3, 4])
    }

    func testParseEmptyStringReturnsNil() {
        let version = Version.parse("")
        XCTAssertNil(version)
    }

    func testParseWhitespaceOnlyReturnsNil() {
        let version = Version.parse("   ")
        XCTAssertNil(version)
    }

    func testParseNonNumericReturnsNil() {
        let version = Version.parse("abc")
        XCTAssertNil(version)
    }

    func testParseVersionWithLeadingWhitespace() throws {
        let version = try XCTUnwrap(Version.parse("  2.3.4"))
        XCTAssertEqual(version.components, [2, 3, 4])
    }

    func testParseVersionWithTrailingWhitespace() throws {
        let version = try XCTUnwrap(Version.parse("2.3.4  "))
        XCTAssertEqual(version.components, [2, 3, 4])
    }

    func testCompareSameVersionsAreEqual() throws {
        let v1 = try XCTUnwrap(Version.parse("1.2.3"))
        let v2 = try XCTUnwrap(Version.parse("1.2.3"))
        XCTAssertFalse(v1 < v2)
        XCTAssertFalse(v2 < v1)
        XCTAssertEqual(v1, v2)
    }

    func testCompareMajorVersionDifference() throws {
        let v1 = try XCTUnwrap(Version.parse("1.0.0"))
        let v2 = try XCTUnwrap(Version.parse("2.0.0"))
        XCTAssertTrue(v1 < v2)
        XCTAssertFalse(v2 < v1)
    }

    func testCompareMinorVersionDifference() throws {
        let v1 = try XCTUnwrap(Version.parse("1.2.0"))
        let v2 = try XCTUnwrap(Version.parse("1.3.0"))
        XCTAssertTrue(v1 < v2)
    }

    func testComparePatchVersionDifference() throws {
        let v1 = try XCTUnwrap(Version.parse("1.2.3"))
        let v2 = try XCTUnwrap(Version.parse("1.2.4"))
        XCTAssertTrue(v1 < v2)
    }

    func testCompareDifferentLengthVersionsShorterIsLess() throws {
        let v1 = try XCTUnwrap(Version.parse("1.2"))
        let v2 = try XCTUnwrap(Version.parse("1.2.1"))
        XCTAssertTrue(v1 < v2)
    }

    func testCompareDifferentLengthVersionsWithEqualPrefix() throws {
        let v1 = try XCTUnwrap(Version.parse("1.2.0"))
        let v2 = try XCTUnwrap(Version.parse("1.2"))
        XCTAssertFalse(v1 < v2)
        XCTAssertFalse(v2 < v1)
        XCTAssertEqual(v1, v2)
    }

    func testCompareSingleComponentVersions() throws {
        let v1 = try XCTUnwrap(Version.parse("3"))
        let v2 = try XCTUnwrap(Version.parse("5"))
        XCTAssertTrue(v1 < v2)
    }

    func testCompareWithVPrefix() throws {
        let v1 = try XCTUnwrap(Version.parse("v1.5.0"))
        let v2 = try XCTUnwrap(Version.parse("v2.0.0"))
        XCTAssertTrue(v1 < v2)
    }

    func testCompareMixedPrefixAndNonPrefix() throws {
        let v1 = try XCTUnwrap(Version.parse("v1.5.0"))
        let v2 = try XCTUnwrap(Version.parse("1.5.0"))
        XCTAssertEqual(v1, v2)
    }

    func testCompareLargeVersionNumbers() throws {
        let v1 = try XCTUnwrap(Version.parse("10.20.30"))
        let v2 = try XCTUnwrap(Version.parse("10.20.31"))
        XCTAssertTrue(v1 < v2)
    }

    func testCompareVersionWithBetaSuffixIgnoresSuffix() throws {
        let v1 = try XCTUnwrap(Version.parse("2.0.0-beta"))
        let v2 = try XCTUnwrap(Version.parse("2.0.0"))
        XCTAssertEqual(v1, v2)
    }
}
