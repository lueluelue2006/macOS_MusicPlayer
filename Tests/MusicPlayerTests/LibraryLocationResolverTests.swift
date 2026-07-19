import Foundation
import XCTest
@testable import MusicPlayer

final class LibraryLocationResolverTests: XCTestCase {
    func testDirectoryReferenceResolvesThroughBookmark() async throws {
        let fixture = try ResolverFixture()
        let resolution = await fixture.resolver.resolve(fixture.reference, in: fixture.location)

        XCTAssertEqual(resolution.availability, .available(fixture.fileURL))
        XCTAssertNil(resolution.bookmarkRefresh)
        XCTAssertEqual(fixture.bookmarks.resolveCount, 1)
        XCTAssertEqual(fixture.scopes.startCount, 1)
        XCTAssertEqual(fixture.scopes.stopCount, 1)
    }

    func testMissingExpectedVolumeShortCircuitsBookmarkResolution() async throws {
        let fixture = try ResolverFixture()
        fixture.volumes.setVolumes([])

        let resolution = await fixture.resolver.resolve(fixture.reference, in: fixture.location)

        XCTAssertEqual(resolution.availability, .volumeUnavailable)
        XCTAssertEqual(fixture.bookmarks.resolveCount, 0)
        XCTAssertEqual(fixture.scopes.startCount, 0)
    }

    func testStaleBookmarkProducesBoundedRefresh() async throws {
        let fixture = try ResolverFixture(bookmarkIsStale: true)

        let resolution = await fixture.resolver.resolve(fixture.reference, in: fixture.location)

        XCTAssertEqual(resolution.availability, .available(fixture.fileURL))
        let refresh = try XCTUnwrap(resolution.bookmarkRefresh)
        XCTAssertEqual(refresh.locationID, fixture.location.id)
        XCTAssertEqual(refresh.bookmarkData, Data("fresh-bookmark".utf8))
        XCTAssertEqual(refresh.resolvedPath, fixture.rootURL.path)
        XCTAssertEqual(refresh.volumeRelativeRootPath, "Music")
        XCTAssertEqual(fixture.bookmarks.createCount, 1)
    }

    func testBrokenBookmarkUsesUniqueVolumeRelativeFallback() async throws {
        let fixture = try ResolverFixture(bookmarkResolveError: ResolverFakeError.brokenBookmark)

        let resolution = await fixture.resolver.resolve(fixture.reference, in: fixture.location)

        XCTAssertEqual(resolution.availability, .available(fixture.fileURL))
        XCTAssertNotNil(resolution.bookmarkRefresh)
        XCTAssertEqual(fixture.bookmarks.resolveCount, 1)
    }

    func testAmbiguousVolumeDoesNotGuessFallback() async throws {
        let fixture = try ResolverFixture(bookmarkResolveError: ResolverFakeError.brokenBookmark)
        fixture.volumes.setVolumes([
            fixture.volume,
            MountedLibraryVolume(
                url: URL(fileURLWithPath: "/DuplicateVolume", isDirectory: true),
                identifier: fixture.volume.identifier,
                displayName: "Duplicate"
            )
        ])

        let resolution = await fixture.resolver.resolve(fixture.reference, in: fixture.location)

        XCTAssertEqual(resolution.availability, .rootMissing)
    }

    func testTrackAvailabilityDistinguishesMissingAndAuthorization() async throws {
        let missingFixture = try ResolverFixture(trackInspection: .missing)
        let missing = await missingFixture.resolver.resolve(
            missingFixture.reference,
            in: missingFixture.location
        )
        XCTAssertEqual(missing.availability, .fileMissing)

        let deniedFixture = try ResolverFixture(trackInspection: .permissionDenied)
        let denied = await deniedFixture.resolver.resolve(
            deniedFixture.reference,
            in: deniedFixture.location
        )
        XCTAssertEqual(denied.availability, .authorizationRequired)
    }

    func testSecurityScopeIsReferenceCountedAcrossLeases() async throws {
        let fixture = try ResolverFixture()
        let first = try await fixture.resolver.acquireAccess(
            to: fixture.reference,
            in: fixture.location
        )
        let second = try await fixture.resolver.acquireAccess(
            to: fixture.reference,
            in: fixture.location
        )

        let activeAfterAcquire = await fixture.resolver.activeLeaseCount(for: fixture.location.id)
        XCTAssertEqual(activeAfterAcquire, 2)
        XCTAssertEqual(fixture.scopes.startCount, 1)
        XCTAssertEqual(fixture.scopes.stopCount, 0)

        await first.release()
        let activeAfterFirstRelease = await fixture.resolver.activeLeaseCount(for: fixture.location.id)
        XCTAssertEqual(activeAfterFirstRelease, 1)
        XCTAssertEqual(fixture.scopes.stopCount, 0)

        await second.release()
        let activeAfterSecondRelease = await fixture.resolver.activeLeaseCount(for: fixture.location.id)
        XCTAssertEqual(activeAfterSecondRelease, 0)
        XCTAssertEqual(fixture.scopes.stopCount, 1)
    }

    func testWithAccessReleasesLeaseWhenOperationThrows() async throws {
        let fixture = try ResolverFixture()
        do {
            _ = try await fixture.resolver.withAccess(
                to: fixture.reference,
                in: fixture.location
            ) { _ -> Bool in
                throw ResolverFakeError.operationFailed
            }
            XCTFail("Expected operation failure")
        } catch ResolverFakeError.operationFailed {
            // Expected.
        }

        let activeAfterFailure = await fixture.resolver.activeLeaseCount(for: fixture.location.id)
        XCTAssertEqual(activeAfterFailure, 0)
        XCTAssertEqual(fixture.scopes.stopCount, 1)
    }

    func testInvalidationBlocksNewLeaseButLetsExistingLeaseRelease() async throws {
        let fixture = try ResolverFixture()
        let lease = try await fixture.resolver.acquireAccess(
            to: fixture.reference,
            in: fixture.location
        )
        await fixture.resolver.invalidateActiveResolution(for: fixture.location.id)

        do {
            _ = try await fixture.resolver.acquireAccess(
                to: fixture.reference,
                in: fixture.location
            )
            XCTFail("Expected invalidated location to reject a new lease")
        } catch let error as LibraryLocationResolverError {
            XCTAssertEqual(error, .unavailable(.volumeUnavailable))
        }

        await lease.release()
        XCTAssertEqual(fixture.scopes.stopCount, 1)
    }
}

private struct ResolverFixture {
    let volumeRootURL: URL
    let rootURL: URL
    let fileURL: URL
    let volume: MountedLibraryVolume
    let location: LibraryLocation
    let reference: LibraryTrackReference
    let bookmarks: ResolverFakeBookmarkProvider
    let volumes: ResolverFakeVolumeProvider
    let inspector: ResolverFakeResourceInspector
    let scopes: ResolverFakeSecurityScopeAccessor
    let resolver: LibraryLocationResolver

    init(
        bookmarkIsStale: Bool = false,
        bookmarkResolveError: Error? = nil,
        trackInspection: LibraryResourceInspection? = nil
    ) throws {
        volumeRootURL = URL(fileURLWithPath: "/SyntheticVolume", isDirectory: true)
        rootURL = volumeRootURL.appendingPathComponent("Music", isDirectory: true)
        fileURL = rootURL.appendingPathComponent("Artist/song.mp3", isDirectory: false)
        volume = MountedLibraryVolume(
            url: volumeRootURL,
            identifier: "volume-id",
            displayName: "SyntheticVolume",
            isRemovable: true,
            isEjectable: true
        )
        location = try LibraryLocation(
            kind: .directory,
            bookmarkData: Data("bookmark".utf8),
            bookmarkKind: .securityScoped,
            fallbackPath: rootURL.path,
            volumeIdentifier: "volume-id",
            volumeRelativeRootPath: "Music",
            rootResourceIdentifier: "root-id",
            displayName: "Music"
        )
        reference = try LibraryTrackReference(
            locationID: location.id,
            relativePath: "Artist/song.mp3",
            legacyAbsolutePath: fileURL.path
        )

        bookmarks = ResolverFakeBookmarkProvider(
            resolvedURL: rootURL,
            isStale: bookmarkIsStale,
            resolveError: bookmarkResolveError
        )
        volumes = ResolverFakeVolumeProvider(volumes: [volume])
        inspector = ResolverFakeResourceInspector(
            inspections: [
                rootURL.path: .available(
                    LibraryResourceSnapshot(
                        isDirectory: true,
                        isRegularFile: false,
                        volumeIdentifier: "volume-id",
                        resourceIdentifier: "root-id"
                    )
                ),
                fileURL.path: trackInspection ?? .available(
                    LibraryResourceSnapshot(
                        isDirectory: false,
                        isRegularFile: true,
                        volumeIdentifier: "volume-id",
                        resourceIdentifier: "file-id"
                    )
                )
            ]
        )
        scopes = ResolverFakeSecurityScopeAccessor()
        resolver = LibraryLocationResolver(
            bookmarkProvider: bookmarks,
            volumeProvider: volumes,
            resourceInspector: inspector,
            securityScopeAccessor: scopes
        )
    }
}

private enum ResolverFakeError: Error {
    case brokenBookmark
    case operationFailed
}

private final class ResolverFakeBookmarkProvider: LibraryBookmarkProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let resolvedURL: URL
    private let isStale: Bool
    private let resolveError: Error?
    private(set) var createCount = 0
    private(set) var resolveCount = 0

    init(resolvedURL: URL, isStale: Bool, resolveError: Error?) {
        self.resolvedURL = resolvedURL
        self.isStale = isStale
        self.resolveError = resolveError
    }

    func createBookmark(
        for _: URL,
        preferredKind: LibraryBookmarkKind
    ) throws -> LibraryBookmark {
        lock.lock()
        createCount += 1
        lock.unlock()
        return try LibraryBookmark(data: Data("fresh-bookmark".utf8), kind: preferredKind)
    }

    func resolveBookmark(_: LibraryBookmark) throws -> ResolvedLibraryBookmark {
        lock.lock()
        resolveCount += 1
        lock.unlock()
        if let resolveError { throw resolveError }
        return ResolvedLibraryBookmark(url: resolvedURL, isStale: isStale)
    }
}

private final class ResolverFakeVolumeProvider: MountedLibraryVolumeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MountedLibraryVolume]

    init(volumes: [MountedLibraryVolume]) {
        values = volumes
    }

    func setVolumes(_ volumes: [MountedLibraryVolume]) {
        lock.lock()
        values = volumes
        lock.unlock()
    }

    func mountedVolumes() throws -> [MountedLibraryVolume] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ResolverFakeResourceInspector: LibraryResourceInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var inspections: [String: LibraryResourceInspection]

    init(inspections: [String: LibraryResourceInspection]) {
        self.inspections = inspections
    }

    func inspect(_ url: URL) -> LibraryResourceInspection {
        lock.lock()
        defer { lock.unlock() }
        return inspections[url.standardizedFileURL.path] ?? .missing
    }
}

private final class ResolverFakeSecurityScopeAccessor: LibrarySecurityScopeAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startAccessing(_: URL) -> Bool {
        lock.lock()
        startCount += 1
        lock.unlock()
        return true
    }

    func stopAccessing(_: URL) {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}
