import Foundation
import XCTest
@testable import MusicPlayer

@MainActor
final class ExternalMediaIntegrationTests: XCTestCase {
    func testDirectoryImportPersistsOneRootBookmarkAndRelativeQueueRows() async throws {
        try await withFixture { fixture in
            let volumeRoot = fixture.root.appendingPathComponent("MountedVolume", isDirectory: true)
            let musicRoot = volumeRoot.appendingPathComponent("Music", isDirectory: true)
            let artistRoot = musicRoot.appendingPathComponent("Artist", isDirectory: true)
            try FileManager.default.createDirectory(
                at: artistRoot,
                withIntermediateDirectories: true
            )
            let firstURL = artistRoot.appendingPathComponent("One.mp3")
            let secondURL = artistRoot.appendingPathComponent("Two.mp3")
            try Data().write(to: firstURL)
            try Data().write(to: secondURL)

            let volume = fixture.volume(at: volumeRoot)
            fixture.volumes.set([volume])
            fixture.bookmarks.setResolvedURL(musicRoot)
            fixture.inspector.set(
                .available(fixture.directorySnapshot(resourceIdentifier: "music-root")),
                for: musicRoot
            )

            let manager = fixture.makeManager()
            await manager.addFiles([musicRoot])
            await manager.waitForAddFilesCompletionForTesting()
            await manager.waitForBackgroundRestoreWorkForTesting()
            XCTAssertTrue(manager.flushPlaylistPersistence(timeout: 2).isDurable)

            var locations: [LibraryLocationRecord] = []
            let locationCount = try fixture.database.forEachLibraryLocation { record in
                locations.append(record)
                return true
            }
            XCTAssertEqual(locationCount, 1)
            let location = try XCTUnwrap(locations.first?.location)
            XCTAssertEqual(location.fallbackPath, musicRoot.standardizedFileURL.path)
            XCTAssertEqual(location.volumeIdentifier, fixture.volumeIdentifier)
            XCTAssertEqual(location.volumeRelativeRootPath, "Music")
            XCTAssertEqual(fixture.bookmarks.createdURLs, [musicRoot.standardizedFileURL])

            let queue = try fixture.database.loadQueue()
            XCTAssertEqual(queue.entries.count, 2)
            XCTAssertEqual(Set(queue.entries.compactMap(\.locationID)), [location.id])
            XCTAssertEqual(
                Set(queue.entries.compactMap(\.relativePath)),
                ["Artist/One.mp3", "Artist/Two.mp3"]
            )
            XCTAssertEqual(Set(queue.entries.map(\.path)), Set([firstURL.path, secondURL.path]))
            XCTAssertEqual(Set(queue.entries.map(\.id)).count, 2)

            manager.prepareForImmediateTermination()
        }
    }

    func testOfflineQueueRestoresAndReconnectsInPlaceThenUnmountMarksCurrent() async throws {
        try await withFixture { fixture in
            let oldVolumeRoot = fixture.root.appendingPathComponent("OldMount", isDirectory: true)
            let oldMusicRoot = oldVolumeRoot.appendingPathComponent("Music", isDirectory: true)
            let oldFileURL = oldMusicRoot.appendingPathComponent("Artist/Song.mp3")
            let locationID = UUID()
            let entryID = UUID()
            let location = try fixture.makeLocation(
                id: locationID,
                rootURL: oldMusicRoot,
                bookmark: Data("old-root-bookmark".utf8)
            )
            try fixture.store(location)
            try fixture.database.replaceQueue(
                LibraryQueueSnapshot(
                    revision: 1,
                    entries: [
                        LibraryQueueEntry(
                            id: entryID,
                            sortKey: 0,
                            path: oldFileURL.path,
                            signature: nil,
                            locationID: locationID,
                            relativePath: "Artist/Song.mp3"
                        )
                    ],
                    currentEntryID: entryID,
                    pendingRekeys: []
                )
            )

            fixture.volumes.set([])
            fixture.bookmarks.setResolvedURL(oldMusicRoot)
            let manager = fixture.makeManager()
            await manager.loadSavedPlaylist()

            XCTAssertEqual(manager.audioFiles.map(\.url), [oldFileURL])
            XCTAssertEqual(manager.unplayableReason(for: oldFileURL), "所在磁盘当前未连接")
            XCTAssertEqual(try fixture.database.loadQueue().entries.first?.id, entryID)

            let newVolumeRoot = fixture.root.appendingPathComponent("RenamedMount", isDirectory: true)
            let newMusicRoot = newVolumeRoot.appendingPathComponent("Music", isDirectory: true)
            let newArtistRoot = newMusicRoot.appendingPathComponent("Artist", isDirectory: true)
            try FileManager.default.createDirectory(
                at: newArtistRoot,
                withIntermediateDirectories: true
            )
            let newFileURL = newArtistRoot.appendingPathComponent("Song.mp3")
            try Data().write(to: newFileURL)
            let mountedVolume = fixture.volume(at: newVolumeRoot)
            fixture.volumes.set([mountedVolume])
            fixture.inspector.set(.missing, for: oldMusicRoot)
            fixture.inspector.set(
                .available(fixture.directorySnapshot(resourceIdentifier: "music-root")),
                for: newMusicRoot
            )
            fixture.inspector.set(
                .available(fixture.fileSnapshot(resourceIdentifier: "song-file")),
                for: newFileURL
            )

            await manager.refreshExternalMediaAvailability()
            XCTAssertEqual(manager.audioFiles.map(\.url), [newFileURL])
            XCTAssertNil(manager.unplayableReason(for: newFileURL))
            XCTAssertTrue(manager.flushPlaylistPersistence(timeout: 2).isDurable)

            let refreshedQueue = try fixture.database.loadQueue()
            let refreshedEntry = try XCTUnwrap(refreshedQueue.entries.first)
            XCTAssertEqual(refreshedEntry.id, entryID, "Reconnect must preserve occurrence identity")
            XCTAssertEqual(refreshedEntry.path, newFileURL.path)
            XCTAssertEqual(refreshedEntry.locationID, locationID)
            XCTAssertEqual(refreshedEntry.relativePath, "Artist/Song.mp3")
            XCTAssertEqual(
                try fixture.database.loadLibraryLocation(id: locationID)?.location.fallbackPath,
                newMusicRoot.path
            )

            manager.currentIndex = 0
            let currentWasAffected = await manager.handleExternalVolumeWillUnmount(mountedVolume)
            XCTAssertTrue(currentWasAffected)
            XCTAssertEqual(manager.unplayableReason(for: newFileURL), "所在磁盘正在断开")

            manager.prepareForImmediateTermination()
        }
    }

    func testPlaylistTrackLocationRoundTripsAndResolvesAfterVolumePathChange() async throws {
        try await withFixture { fixture in
            let oldVolumeRoot = fixture.root.appendingPathComponent("PlaylistOldMount", isDirectory: true)
            let oldMusicRoot = oldVolumeRoot.appendingPathComponent("Music", isDirectory: true)
            let oldFileURL = oldMusicRoot.appendingPathComponent("Artist/Playlist Song.mp3")
            let location = try fixture.makeLocation(
                rootURL: oldMusicRoot,
                bookmark: Data("playlist-root-bookmark".utf8)
            )
            try fixture.store(location)

            let track = UserPlaylist.Track(
                id: UUID(),
                path: oldFileURL.path,
                signature: nil,
                locationID: location.id,
                relativePath: "Artist/Playlist Song.mp3"
            )
            let playlist = UserPlaylist(id: UUID(), name: "External", tracks: [track])
            try fixture.database.replacePlaylists(
                LibraryPlaylistsSnapshot(
                    revision: 1,
                    playlists: [playlist],
                    pendingCleanup: []
                )
            )

            let roundTrippedTrack = try XCTUnwrap(
                fixture.database.loadPlaylists().playlists.first?.tracks.first
            )
            XCTAssertEqual(roundTrippedTrack.id, track.id)
            XCTAssertEqual(roundTrippedTrack.path, track.path)
            XCTAssertEqual(roundTrippedTrack.locationID, location.id)
            XCTAssertEqual(roundTrippedTrack.relativePath, track.relativePath)

            let newVolumeRoot = fixture.root.appendingPathComponent("PlaylistNewMount", isDirectory: true)
            let newMusicRoot = newVolumeRoot.appendingPathComponent("Music", isDirectory: true)
            let newArtistRoot = newMusicRoot.appendingPathComponent("Artist", isDirectory: true)
            try FileManager.default.createDirectory(
                at: newArtistRoot,
                withIntermediateDirectories: true
            )
            let newFileURL = newArtistRoot.appendingPathComponent("Playlist Song.mp3")
            try Data().write(to: newFileURL)
            fixture.volumes.set([fixture.volume(at: newVolumeRoot)])
            fixture.bookmarks.setResolvedURL(oldMusicRoot)
            fixture.inspector.set(.missing, for: oldMusicRoot)
            fixture.inspector.set(
                .available(fixture.directorySnapshot(resourceIdentifier: "music-root")),
                for: newMusicRoot
            )
            fixture.inspector.set(
                .available(fixture.fileSnapshot(resourceIdentifier: "playlist-song")),
                for: newFileURL
            )

            let manager = fixture.makeManager()
            let resolved = await manager.resolvePlaylistTrackLocations([roundTrippedTrack])
            XCTAssertEqual(resolved.count, 1)
            XCTAssertEqual(resolved.first?.url, newFileURL)
            XCTAssertNil(resolved.first?.offlineReason)
            let stillRoundTripped = try XCTUnwrap(
                fixture.database.loadPlaylists().playlists.first?.tracks.first
            )
            XCTAssertEqual(stillRoundTripped.id, track.id)
            XCTAssertEqual(stillRoundTripped.locationID, location.id)
            XCTAssertEqual(stillRoundTripped.relativePath, "Artist/Playlist Song.mp3")

            manager.prepareForImmediateTermination()
        }
    }

    func testExistingQueueEntryIsSupplementedAndCentralProviderAcquiresLease() async throws {
        try await withFixture { fixture in
            let volumeRoot = fixture.root.appendingPathComponent("LeaseVolume", isDirectory: true)
            let musicRoot = volumeRoot.appendingPathComponent("Music", isDirectory: true)
            try FileManager.default.createDirectory(at: musicRoot, withIntermediateDirectories: true)
            let fileURL = musicRoot.appendingPathComponent("song.mp3")
            try Data().write(to: fileURL)
            let location = try fixture.makeLocation(
                rootURL: musicRoot,
                bookmark: Data("lease-bookmark".utf8)
            )
            try fixture.store(location)
            fixture.volumes.set([fixture.volume(at: volumeRoot)])
            fixture.bookmarks.setResolvedURL(musicRoot)
            fixture.inspector.set(
                .available(fixture.directorySnapshot(resourceIdentifier: "music-root")),
                for: musicRoot
            )
            fixture.inspector.set(
                .available(fixture.fileSnapshot(resourceIdentifier: "song")),
                for: fileURL
            )

            let manager = fixture.makeManager()
            let file = AudioFile(
                url: fileURL,
                metadata: AudioMetadata(
                    title: "song",
                    artist: "",
                    album: "",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
            )
            XCTAssertNotNil(manager.ensureInQueue([file], focusURL: fileURL))
            let storedTrack = UserPlaylist.Track(
                path: fileURL.path,
                signature: nil,
                locationID: location.id,
                relativePath: "song.mp3"
            )
            XCTAssertNotNil(manager.ensureInQueue(
                [file],
                focusURL: fileURL,
                storedTracksByResolvedPath: [fileURL.path: storedTrack]
            ))
            XCTAssertTrue(manager.flushPlaylistPersistence(timeout: 2).isDurable)

            let persisted = try XCTUnwrap(fixture.database.loadQueue().entries.first)
            XCTAssertEqual(persisted.locationID, location.id)
            XCTAssertEqual(persisted.relativePath, "song.mp3")

            let request = try XCTUnwrap(manager.playbackAccessRequest(for: file))
            let lease = try await manager.acquirePlaybackAccessLease(for: request)
            XCTAssertEqual(lease.locationID, location.id)
            XCTAssertEqual(lease.url, fileURL.standardizedFileURL)
            lease.releasePlaybackAccess()
            manager.prepareForImmediateTermination()
        }
    }

    private func withFixture(
        _ body: (ExternalMediaIntegrationFixture) async throws -> Void
    ) async throws {
        let fixture = try ExternalMediaIntegrationFixture()
        defer { fixture.cleanUp() }
        try await body(fixture)
    }
}

private final class ExternalMediaIntegrationFixture {
    let root: URL
    let database: LibraryDatabase
    let bookmarks = ExternalMediaBookmarkProvider()
    let volumes = ExternalMediaVolumeProvider()
    let inspector = ExternalMediaResourceInspector()
    let scopes = ExternalMediaSecurityScopeAccessor()
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let volumeIdentifier = "external-volume-id"

    private lazy var resolver = LibraryLocationResolver(
        bookmarkProvider: bookmarks,
        volumeProvider: volumes,
        resourceInspector: inspector,
        securityScopeAccessor: scopes
    )

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExternalMediaIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try LibraryDatabase(fileURL: root.appendingPathComponent("Library.sqlite3"))
        defaultsSuiteName = "ExternalMediaIntegrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @MainActor
    func makeManager() -> PlaylistManager {
        let preferences = AppPreferencesStore(userDefaults: defaults)
        let weights = PlaybackWeights(
            persistenceDebounceInterval: 0,
            libraryDatabase: database
        )
        return PlaylistManager(
            libraryDatabase: database,
            libraryLocationResolver: resolver,
            disablePersistence: false,
            persistenceDebounceInterval: 0,
            signatureCaptureService: SignatureCaptureService(
                maximumConcurrentCaptures: 1,
                maximumPendingCaptures: 16
            ),
            initialQueueLoadState: .ready,
            appPreferencesStore: preferences,
            legacyUserDefaults: defaults,
            playbackWeights: weights,
            freshMetadataLoaderOverride: { url in
                AudioMetadata(
                    title: url.deletingPathExtension().lastPathComponent,
                    artist: "Test Artist",
                    album: "Test Album",
                    year: nil,
                    genre: nil,
                    artwork: nil
                )
            }
        )
    }

    func makeLocation(
        id: UUID = UUID(),
        rootURL: URL,
        bookmark: Data
    ) throws -> LibraryLocation {
        try LibraryLocation(
            id: id,
            kind: .directory,
            bookmarkData: bookmark,
            bookmarkKind: .regular,
            fallbackPath: rootURL.path,
            volumeIdentifier: volumeIdentifier,
            volumeRelativeRootPath: "Music",
            rootResourceIdentifier: "music-root",
            displayName: "Music"
        )
    }

    func store(_ location: LibraryLocation) throws {
        let revision = try database.libraryLocationsRevision()
        let stored = try database.upsertLibraryLocation(
            LibraryLocationRecord(location: location, updatedAt: Date()),
            expectedRevision: revision,
            nextRevision: revision &+ 1
        )
        guard stored else {
            throw ExternalMediaIntegrationError.locationRevisionConflict
        }
    }

    func volume(at url: URL) -> MountedLibraryVolume {
        MountedLibraryVolume(
            url: url,
            identifier: volumeIdentifier,
            displayName: url.lastPathComponent,
            isRemovable: true,
            isEjectable: true,
            isLocal: true
        )
    }

    func directorySnapshot(resourceIdentifier: String) -> LibraryResourceSnapshot {
        LibraryResourceSnapshot(
            isDirectory: true,
            isRegularFile: false,
            volumeIdentifier: volumeIdentifier,
            resourceIdentifier: resourceIdentifier
        )
    }

    func fileSnapshot(resourceIdentifier: String) -> LibraryResourceSnapshot {
        LibraryResourceSnapshot(
            isDirectory: false,
            isRegularFile: true,
            volumeIdentifier: volumeIdentifier,
            resourceIdentifier: resourceIdentifier
        )
    }

    func cleanUp() {
        database.close()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ExternalMediaIntegrationError: Error {
    case locationRevisionConflict
}

private final class ExternalMediaBookmarkProvider: LibraryBookmarkProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedURL = URL(fileURLWithPath: "/", isDirectory: true)
    private var createSequence = 0
    private var storedCreatedURLs: [URL] = []

    var createdURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedCreatedURLs
    }

    func setResolvedURL(_ url: URL) {
        lock.lock()
        resolvedURL = url.standardizedFileURL
        lock.unlock()
    }

    func createBookmark(
        for url: URL,
        preferredKind _: LibraryBookmarkKind
    ) throws -> LibraryBookmark {
        lock.lock()
        createSequence += 1
        let sequence = createSequence
        storedCreatedURLs.append(url.standardizedFileURL)
        lock.unlock()
        return try LibraryBookmark(
            data: Data("external-bookmark-\(sequence)".utf8),
            kind: .regular
        )
    }

    func resolveBookmark(_: LibraryBookmark) throws -> ResolvedLibraryBookmark {
        lock.lock()
        defer { lock.unlock() }
        return ResolvedLibraryBookmark(url: resolvedURL, isStale: false)
    }
}

private final class ExternalMediaVolumeProvider: MountedLibraryVolumeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedVolumes: [MountedLibraryVolume] = []

    func set(_ volumes: [MountedLibraryVolume]) {
        lock.lock()
        storedVolumes = volumes
        lock.unlock()
    }

    func mountedVolumes() throws -> [MountedLibraryVolume] {
        lock.lock()
        defer { lock.unlock() }
        return storedVolumes
    }
}

private final class ExternalMediaResourceInspector: LibraryResourceInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var inspections: [String: LibraryResourceInspection] = [:]

    func set(_ inspection: LibraryResourceInspection, for url: URL) {
        lock.lock()
        inspections[url.standardizedFileURL.path] = inspection
        lock.unlock()
    }

    func inspect(_ url: URL) -> LibraryResourceInspection {
        lock.lock()
        defer { lock.unlock() }
        return inspections[url.standardizedFileURL.path] ?? .missing
    }
}

private final class ExternalMediaSecurityScopeAccessor: LibrarySecurityScopeAccessing, @unchecked Sendable {
    func startAccessing(_: URL) -> Bool { true }
    func stopAccessing(_: URL) {}
}
