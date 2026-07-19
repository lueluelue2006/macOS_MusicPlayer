import XCTest
@testable import MusicPlayer

final class LibraryLocationTests: XCTestCase {
    func testBookmarkAndPathBoundsAreEnforced() throws {
        XCTAssertThrowsError(
            try LibraryLocation(
                kind: .directory,
                bookmarkData: Data(),
                bookmarkKind: .regular,
                fallbackPath: "/Music",
                displayName: "Music"
            )
        ) { error in
            XCTAssertEqual(error as? LibraryLocationValidationError, .emptyBookmark)
        }

        XCTAssertThrowsError(
            try LibraryLocation(
                kind: .directory,
                bookmarkData: Data(
                    repeating: 1,
                    count: LibraryLocationLimits.maximumBookmarkBytes + 1
                ),
                bookmarkKind: .regular,
                fallbackPath: "/Music",
                displayName: "Music"
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryLocationValidationError,
                .bookmarkTooLarge(maximumBytes: LibraryLocationLimits.maximumBookmarkBytes)
            )
        }

        XCTAssertThrowsError(
            try LibraryLocation(
                kind: .directory,
                bookmarkData: Data([1]),
                bookmarkKind: .regular,
                fallbackPath: "relative/Music",
                displayName: "Music"
            )
        )
    }

    func testSafeRelativePathRoundTripsNestedUnicodePath() throws {
        let root = URL(fileURLWithPath: "/Volumes/音乐盘/我的音乐", isDirectory: true)
        let child = root
            .appendingPathComponent("王菲", isDirectory: true)
            .appendingPathComponent("红豆.m4a", isDirectory: false)

        let relative = try LibraryRelativePath.make(childURL: child, relativeTo: root)
        XCTAssertEqual(relative, "王菲/红豆.m4a")
        XCTAssertEqual(
            try LibraryRelativePath.resolve(relative, under: root),
            child.standardizedFileURL
        )
    }

    func testUnsafeRelativePathsAreRejected() {
        for path in ["../song.mp3", "artist/../../song.mp3", "/song.mp3", "a//b.mp3", "./song.mp3"] {
            XCTAssertThrowsError(
                try LibraryRelativePath.resolve(
                    path,
                    under: URL(fileURLWithPath: "/Music", isDirectory: true)
                ),
                "Expected rejection for \(path)"
            )
        }
    }

    func testChildOutsideRootIsRejectedByPathComponents() {
        XCTAssertThrowsError(
            try LibraryRelativePath.make(
                childURL: URL(fileURLWithPath: "/Music-Other/song.mp3"),
                relativeTo: URL(fileURLWithPath: "/Music", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? LibraryLocationValidationError, .pathOutsideRoot)
        }
    }

    func testTrackReferenceCodableRejectsEscapingRelativePath() throws {
        let locationID = UUID()
        let invalidJSON = """
        {
          "id": "\(UUID().uuidString)",
          "locationID": "\(locationID.uuidString)",
          "relativePath": "../outside.mp3",
          "legacyAbsolutePath": "/Music/outside.mp3"
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LibraryTrackReference.self,
                from: Data(invalidJSON.utf8)
            )
        )
    }

    func testApplyingBookmarkRefreshPreservesStableIdentity() throws {
        let id = UUID()
        let location = try LibraryLocation(
            id: id,
            kind: .directory,
            bookmarkData: Data("old".utf8),
            bookmarkKind: .regular,
            fallbackPath: "/Volumes/Old/Music",
            volumeIdentifier: "volume",
            volumeRelativeRootPath: "Music",
            rootResourceIdentifier: "root",
            displayName: "Music"
        )
        let refresh = try LibraryBookmarkRefresh(
            locationID: id,
            bookmarkData: Data("new".utf8),
            bookmarkKind: .securityScoped,
            resolvedPath: "/Volumes/New/Music",
            volumeRelativeRootPath: "Music"
        )

        let updated = try location.applying(refresh)
        XCTAssertEqual(updated.id, location.id)
        XCTAssertEqual(updated.bookmarkData, Data("new".utf8))
        XCTAssertEqual(updated.bookmarkKind, .securityScoped)
        XCTAssertEqual(updated.fallbackPath, "/Volumes/New/Music")
        XCTAssertEqual(updated.rootResourceIdentifier, "root")
    }

    func testSingleFileReferenceDoesNotAcceptRelativePathWithoutLocation() {
        XCTAssertThrowsError(
            try LibraryTrackReference(
                locationID: nil,
                relativePath: "song.mp3",
                legacyAbsolutePath: "/Music/song.mp3"
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryLocationValidationError,
                .locationIdentifierMismatch
            )
        }
    }
}
