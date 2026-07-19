import XCTest
@testable import MusicPlayer

final class PlaylistsSchemaModelTests: XCTestCase {
    private struct StoreV1: Decodable {
        let version: Int
        let playlists: [UserPlaylist]
    }

    private struct StoreV2: Codable {
        let version: Int
        let storeRevision: UInt64
        let playlists: [UserPlaylist]
    }

    func testLegacyTrackWithoutIdentifierDecodesAndWritesStableIdentifier() throws {
        let legacyData = Data(#"{"path":"/Music/legacy.mp3"}"#.utf8)

        let migrated = try JSONDecoder().decode(UserPlaylist.Track.self, from: legacyData)
        XCTAssertEqual(migrated.path, "/Music/legacy.mp3")
        XCTAssertNil(migrated.signature)

        let migratedData = try JSONEncoder().encode(migrated)
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["id"] as? String, migrated.id.uuidString)

        let reloaded = try JSONDecoder().decode(UserPlaylist.Track.self, from: migratedData)
        XCTAssertEqual(reloaded.id, migrated.id)
        XCTAssertEqual(reloaded, migrated)
    }

    func testV2TrackRoundTripPreservesIdentifierAndSignature() throws {
        let trackID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let signature = FileSignature(
            pathKey: "/Music/song.mp3",
            size: 4_096,
            modificationTimeNanoseconds: 1_700_000_000_000_000_000,
            inode: 42,
            fileResourceIdentifier: "resource-id",
            volumeIdentifier: "volume-id"
        )
        let original = UserPlaylist.Track(
            id: trackID,
            path: "/Music/song.mp3",
            signature: signature
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserPlaylist.Track.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, trackID)
        XCTAssertEqual(decoded.signature, signature)
    }

    func testLegacyDuplicatePathsReceiveDistinctTrackIdentifiers() throws {
        let data = Data(
            #"[{"path":"/Music/duplicate.mp3"},{"path":"/Music/duplicate.mp3"}]"#.utf8
        )

        let tracks = try JSONDecoder().decode([UserPlaylist.Track].self, from: data)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.map(\.path), ["/Music/duplicate.mp3", "/Music/duplicate.mp3"])
        XCTAssertNotEqual(tracks[0].id, tracks[1].id)
        XCTAssertNotEqual(tracks[0], tracks[1])
        XCTAssertEqual(Set(tracks).count, 2)
    }

    func testV1StoreDocumentDecodesTracksWithoutIdentifiers() throws {
        let data = Data(
            #"{"version":1,"playlists":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"Legacy","tracks":[{"path":"/Music/legacy.mp3"}],"createdAt":0,"updatedAt":0}]}"#.utf8
        )

        let document = try JSONDecoder().decode(StoreV1.self, from: data)

        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.playlists.count, 1)
        XCTAssertEqual(document.playlists[0].tracks.count, 1)
        XCTAssertEqual(document.playlists[0].tracks[0].path, "/Music/legacy.mp3")
    }

    func testV2StoreDocumentRoundTripPreservesRevisionAndTrackIdentifiers() throws {
        let playlistID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let trackID = try XCTUnwrap(UUID(uuidString: "99999999-8888-7777-6666-555555555555"))
        let playlist = UserPlaylist(
            id: playlistID,
            name: "Current",
            tracks: [.init(id: trackID, path: "/Music/current.mp3")],
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let original = StoreV2(version: 2, storeRevision: 37, playlists: [playlist])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoreV2.self, from: data)

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.storeRevision, 37)
        XCTAssertEqual(decoded.playlists, [playlist])
        XCTAssertEqual(decoded.playlists[0].tracks[0].id, trackID)
    }
}
