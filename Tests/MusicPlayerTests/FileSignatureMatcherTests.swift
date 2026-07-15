import XCTest
@testable import MusicPlayer

final class FileSignatureMatcherTests: XCTestCase {

    // MARK: - Strong Identity Match (Tier 1)

    func testResourceIdentifierMatchAccepted() {
        let original = FileSignature(
            pathKey: "/Volumes/Music/artist/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let movedSameVolume = FileSignature(
            pathKey: "/Volumes/Music/moved/renamed.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: movedSameVolume)

        XCTAssertEqual(result, .matched, "fileResourceIdentifier + volumeIdentifier match should accept")
    }

    func testResourceIdentifierMatchRequiresBothNonNil() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: nil // Missing volume ID
        )

        let candidate = FileSignature(
            pathKey: "/other/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: candidate)

        XCTAssertEqual(result, .rejected, "resource ID match requires both volumeIdentifier non-nil")
    }

    func testResourceIdentifierMismatchRejected() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let differentFile = FileSignature(
            pathKey: "/path/song.mp3", // Same path
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 67890,
            fileResourceIdentifier: "resource-def", // Different file
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: differentFile)

        XCTAssertEqual(result, .rejected, "different fileResourceIdentifier should reject even if path matches")
    }

    func testResourceIdentifierSameButDifferentVolumeRejected() {
        let original = FileSignature(
            pathKey: "/Volumes/USB1/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-usb1"
        )

        let differentVolume = FileSignature(
            pathKey: "/Volumes/USB2/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345, // Same inode
            fileResourceIdentifier: "resource-abc", // Same resource ID
            volumeIdentifier: "volume-usb2" // Different volume
        )

        let result = FileSignatureMatcher.match(original: original, candidate: differentVolume)

        XCTAssertEqual(result, .rejected, "same resourceId on different volume should reject even if inode/size/mtime match")
    }

    func testStrongIdentityDoesNotDowngradeToInodeFallback() {
        let originalWithResourceId = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let candidateMissingResourceId = FileSignature(
            pathKey: "/new/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345, // Same inode
            fileResourceIdentifier: nil, // Resource ID missing
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: originalWithResourceId, candidate: candidateMissingResourceId)

        XCTAssertEqual(result, .rejected, "original has resourceId but candidate missing resourceId should reject, no downgrade to inode fallback")
    }

    func testInodeFallbackRejectsWhenCandidateHasResourceId() {
        let originalMissingResourceId = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil, // Resource ID missing
            volumeIdentifier: "volume-xyz"
        )

        let candidateWithResourceId = FileSignature(
            pathKey: "/new/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345, // Same inode
            fileResourceIdentifier: "resource-abc", // Has resource ID
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: originalMissingResourceId, candidate: candidateWithResourceId)

        XCTAssertEqual(result, .rejected, "inode fallback requires both sides lack resourceId; candidate having resourceId should reject")
    }

    func testDifferentResourceIdRejectsDespiteFallbackMatch() {
        let original = FileSignature(
            pathKey: "/path1/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let differentResourceId = FileSignature(
            pathKey: "/path2/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345, // Same fallback fields
            fileResourceIdentifier: "resource-def", // Different resource ID
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: differentResourceId)

        XCTAssertEqual(result, .rejected, "different resourceId should reject even if inode/volume/size/mtime match")
    }

    func testEmptyStringResourceIdNotTreatedAsStrongIdentity() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "", // Empty string
            volumeIdentifier: "volume-xyz"
        )

        let candidate = FileSignature(
            pathKey: "/other/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 67890, // Different inode
            fileResourceIdentifier: "", // Empty string
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: candidate)

        XCTAssertEqual(result, .rejected, "empty string resourceId should not be treated as strong identity, different inode should reject")
    }

    func testWhitespaceResourceIdNotTreatedAsStrongIdentity() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "   ", // Whitespace
            volumeIdentifier: "volume-xyz"
        )

        let candidate = FileSignature(
            pathKey: "/other/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 67890, // Different inode
            fileResourceIdentifier: "   ", // Whitespace
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: candidate)

        XCTAssertEqual(result, .rejected, "whitespace-only resourceId should not be treated as strong identity")
    }

    func testEmptyVolumeIdDoesNotSatisfyAnyAutoMatch() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "" // Empty volume ID
        )

        let candidate = FileSignature(
            pathKey: "/other/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "" // Empty volume ID
        )

        let result = FileSignatureMatcher.match(original: original, candidate: candidate)

        XCTAssertEqual(result, .rejected, "empty volumeId should not satisfy Tier 1 or Tier 2 auto-match")
    }

    // MARK: - Inode Match (Tier 2)

    func testInodeMatchWhenNoResourceIdentifiers() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let moved = FileSignature(
            pathKey: "/moved/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: moved)

        XCTAssertEqual(result, .matched, "inode + volumeIdentifier + size + mtime should match when no resource IDs")
    }

    func testInodeMatchRequiresAllFieldsNonNil() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: nil, // Missing inode
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let candidate = FileSignature(
            pathKey: "/other/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: candidate)

        XCTAssertEqual(result, .rejected, "inode match requires inode, volumeIdentifier, size, mtime all non-nil")
    }

    func testInodeMatchRequiresSameVolume() {
        let original = FileSignature(
            pathKey: "/Volumes/USB1/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-usb1"
        )

        let differentVolume = FileSignature(
            pathKey: "/Volumes/USB2/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345, // Same inode on different volume
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-usb2"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: differentVolume)

        XCTAssertEqual(result, .rejected, "same inode on different volume should reject (inode reuse)")
    }

    func testInodeMatchRequiresSizeMatch() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let differentSize = FileSignature(
            pathKey: "/path/song.mp3",
            size: 6_000_000, // Different size
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: differentSize)

        XCTAssertEqual(result, .rejected, "inode match requires size to match")
    }

    func testInodeMatchRequiresMtimeMatch() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let differentMtime = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_001_000_000_000, // Different mtime
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: differentMtime)

        XCTAssertEqual(result, .rejected, "inode match requires exact mtime nanoseconds")
    }

    // MARK: - Weak Fingerprint Rejection

    func testSizeAndMtimeOnlyRejected() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: nil,
            fileResourceIdentifier: nil,
            volumeIdentifier: nil
        )

        let sameFingerprint = FileSignature(
            pathKey: "/other/different.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: nil,
            fileResourceIdentifier: nil,
            volumeIdentifier: nil
        )

        let result = FileSignatureMatcher.match(original: original, candidate: sameFingerprint)

        XCTAssertEqual(result, .rejected, "size + mtime alone should reject (too weak)")
    }

    func testPathOnlyRejected() {
        let original = FileSignature(
            pathKey: "/path/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let samePath = FileSignature(
            pathKey: "/path/song.mp3", // Same path
            size: 6_000_000, // Different size
            modificationTimeNanoseconds: 1_700_000_001_000_000_000,
            inode: 67890, // Different inode
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.match(original: original, candidate: samePath)

        XCTAssertEqual(result, .rejected, "same path with different content should reject")
    }

    // MARK: - Batch Matching

    func testMatchBestReturnsUniqueStrongMatch() {
        let original = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let unrelated = FileSignature(
            pathKey: "/other/unrelated.mp3",
            size: 3_000_000,
            modificationTimeNanoseconds: 1_600_000_000_000_000_000,
            inode: 99999,
            fileResourceIdentifier: "resource-zzz",
            volumeIdentifier: "volume-xyz"
        )

        let correctMatch = FileSignature(
            pathKey: "/new/moved.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.matchBest(original: original, candidates: [unrelated, correctMatch])

        XCTAssertEqual(result, .matched(correctMatch), "should return unique strong match")
    }

    func testMatchBestReturnsAmbiguousWhenMultipleStrongMatches() {
        let original = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let candidate1 = FileSignature(
            pathKey: "/copy1/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let candidate2 = FileSignature(
            pathKey: "/copy2/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.matchBest(original: original, candidates: [candidate1, candidate2])

        XCTAssertEqual(result, .ambiguous, "multiple strong matches should return ambiguous, not pick first")
    }

    func testMatchBestReturnsAmbiguousWhenMultipleInodeFallbackMatches() {
        let original = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let candidate1 = FileSignature(
            pathKey: "/copy1/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let candidate2 = FileSignature(
            pathKey: "/copy2/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: nil,
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.matchBest(original: original, candidates: [candidate1, candidate2])

        XCTAssertEqual(result, .ambiguous, "multiple inode fallback matches (Tier 2) should also return ambiguous")
    }

    func testMatchBestReturnsNoneWhenNoMatches() {
        let original = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let unrelated1 = FileSignature(
            pathKey: "/other1.mp3",
            size: 3_000_000,
            modificationTimeNanoseconds: 1_600_000_000_000_000_000,
            inode: 99999,
            fileResourceIdentifier: "resource-zzz",
            volumeIdentifier: "volume-xyz"
        )

        let unrelated2 = FileSignature(
            pathKey: "/other2.mp3",
            size: 4_000_000,
            modificationTimeNanoseconds: 1_650_000_000_000_000_000,
            inode: 88888,
            fileResourceIdentifier: "resource-yyy",
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.matchBest(original: original, candidates: [unrelated1, unrelated2])

        XCTAssertEqual(result, .none, "no matching candidates should return none")
    }

    func testMatchBestReturnsNoneForEmptyCandidates() {
        let original = FileSignature(
            pathKey: "/old/song.mp3",
            size: 5_000_000,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 12345,
            fileResourceIdentifier: "resource-abc",
            volumeIdentifier: "volume-xyz"
        )

        let result = FileSignatureMatcher.matchBest(original: original, candidates: [])

        XCTAssertEqual(result, .none, "empty candidate list should return none")
    }
}
