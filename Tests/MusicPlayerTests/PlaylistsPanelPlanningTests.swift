import Foundation
import XCTest
@testable import MusicPlayer

final class PlaylistsPanelPlanningTests: XCTestCase {
    func testQueueReferencePlanKeysStoredIdentityByResolvedPath() throws {
        let locationID = UUID()
        let trackID = UUID()
        let fallbackPath = "/Volumes/Old/Music/song.mp3"
        let resolvedURL = URL(fileURLWithPath: "/Volumes/Current/Music/song.mp3")
        let signature = FileSignature(
            pathKey: PathKey.canonical(path: fallbackPath),
            size: 12,
            modificationTimeNanoseconds: 34,
            inode: nil,
            fileResourceIdentifier: "file-id",
            volumeIdentifier: "volume-id"
        )
        let storedTrack = UserPlaylist.Track(
            id: trackID,
            path: fallbackPath,
            signature: signature,
            locationID: locationID,
            relativePath: "song.mp3"
        )
        let loadedFile = AudioFile(
            id: trackID.uuidString,
            url: resolvedURL,
            metadata: AudioMetadata(
                title: "song",
                artist: "",
                album: "",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )

        let plan = PlaylistQueueReferencePlanner.make(
            playableFiles: [loadedFile],
            playlist: UserPlaylist(name: "External", tracks: [storedTrack])
        )

        XCTAssertEqual(plan.signatures[resolvedURL.path], signature)
        XCTAssertEqual(plan.storedTracksByResolvedPath[resolvedURL.path], storedTrack)
        XCTAssertNil(plan.signatures[fallbackPath])
    }

    func testQueueReferencePlanIgnoresLoadedTrackWithoutStoredIdentity() {
        let loadedFile = AudioFile(
            id: UUID().uuidString,
            url: URL(fileURLWithPath: "/Music/unknown.mp3"),
            metadata: AudioMetadata(
                title: "unknown",
                artist: "",
                album: "",
                year: nil,
                genre: nil,
                artwork: nil
            )
        )

        let plan = PlaylistQueueReferencePlanner.make(
            playableFiles: [loadedFile],
            playlist: UserPlaylist(name: "Empty", tracks: [])
        )

        XCTAssertTrue(plan.signatures.isEmpty)
        XCTAssertTrue(plan.storedTracksByResolvedPath.isEmpty)
    }
}
