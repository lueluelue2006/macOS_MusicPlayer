import XCTest
@testable import MusicPlayer

@MainActor
final class SearchSortPersistenceTests: XCTestCase {
    func testRoundTripUsesVersionedEnvelope() throws {
        let defaults = makeDefaults()
        let state = SearchSortState(userDefaults: defaults)
        let option = SearchSortOption(field: .artist, direction: .descending)

        state.setOption(option, for: .queue)

        XCTAssertEqual(SearchSortState(userDefaults: defaults).option(for: .queue), option)
        let data = try XCTUnwrap(defaults.data(forKey: SearchSortState.envelopeKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, SearchSortState.formatVersion)
        XCTAssertNotNil(json["optionsByTarget"] as? [String: Any])
    }

    func testLegacyMapMigratesAndIsRemoved() throws {
        let defaults = makeDefaults()
        let legacy: [String: SearchSortOption] = [
            SearchFocusTarget.playlists.rawValue: .init(field: .title, direction: .ascending),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: SearchSortState.legacyKey)

        let state = SearchSortState(userDefaults: defaults)

        XCTAssertEqual(state.option(for: .playlists), legacy[SearchFocusTarget.playlists.rawValue])
        XCTAssertNotNil(defaults.data(forKey: SearchSortState.envelopeKey))
        XCTAssertNil(defaults.object(forKey: SearchSortState.legacyKey))
    }

    func testFutureEnvelopeIsReadOnlyAndPreservedByteForByte() throws {
        let defaults = makeDefaults()
        let future = try JSONSerialization.data(withJSONObject: [
            "version": 42,
            "optionsByTarget": [
                "queue": ["field": "title", "direction": "descending"],
            ],
            "future": "keep",
        ])
        defaults.set(future, forKey: SearchSortState.envelopeKey)
        let state = SearchSortState(userDefaults: defaults)

        XCTAssertEqual(state.persistenceState, .protectedFuture(version: 42))
        XCTAssertEqual(state.option(for: .queue), .default)
        let revision = state.revision
        state.setOption(.init(field: .weight, direction: .descending), for: .queue)
        XCTAssertEqual(state.revision, revision)
        XCTAssertEqual(defaults.data(forKey: SearchSortState.envelopeKey), future)
    }

    func testOversizedEnvelopeIsReadOnlyAndPreservedByteForByte() {
        let defaults = makeDefaults()
        let oversized = Data(repeating: 0xA5, count: SearchSortState.maximumEnvelopeBytes + 1)
        defaults.set(oversized, forKey: SearchSortState.envelopeKey)
        let state = SearchSortState(userDefaults: defaults)

        XCTAssertEqual(state.persistenceState, .protectedCorrupt)
        state.setOption(.init(field: .title, direction: .descending), for: .queue)
        XCTAssertEqual(defaults.data(forKey: SearchSortState.envelopeKey), oversized)
    }

    func testCorruptDataIsQuarantinedWithBoundedRotation() {
        let defaults = makeDefaults()
        let first = Data("first-corrupt".utf8)
        defaults.set(first, forKey: SearchSortState.envelopeKey)
        _ = SearchSortState(userDefaults: defaults)

        let second = Data("second-corrupt".utf8)
        defaults.set(second, forKey: SearchSortState.envelopeKey)
        let state = SearchSortState(userDefaults: defaults)

        XCTAssertEqual(state.option(for: .queue), .default)
        XCTAssertEqual(defaults.data(forKey: SearchSortState.corruptQuarantineKeys[0]), second)
        XCTAssertEqual(defaults.data(forKey: SearchSortState.corruptQuarantineKeys[1]), first)
        XCTAssertNil(defaults.data(forKey: SearchSortState.envelopeKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "search-sort-persistence-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
