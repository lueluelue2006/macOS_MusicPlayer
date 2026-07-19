import XCTest
@testable import MusicPlayer

final class UserDefaultsMigratorTests: XCTestCase {
    func testV1AppPreferencesEnvelopeCrossesBundleMigrationAndUpgradesInStore() throws {
        let source = makeDefaults(prefix: "defaults-migration-v1-envelope-source")
        let target = makeDefaults(prefix: "defaults-migration-v1-envelope-target")
        let v1 = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "preferences": [
                "volume": 0.72,
                "playbackRate": 1.25,
                "playbackMode": "repeatOne",
                "playbackScope": ["kind": "queue"],
            ],
        ])
        source.set(v1, forKey: AppPreferencesStore.envelopeKey)

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        guard case .migrated(let keys) = result else {
            return XCTFail("Expected v1 envelope migration, got \(result)")
        }
        XCTAssertEqual(keys, [AppPreferencesStore.envelopeKey])
        XCTAssertEqual(target.data(forKey: AppPreferencesStore.envelopeKey), v1)

        let preferences = AppPreferencesStore(userDefaults: target).load()
        XCTAssertEqual(preferences.volume, 0.72, accuracy: 0.0001)
        XCTAssertEqual(preferences.playbackRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(preferences.playbackMode, .repeatOne)
        let upgraded = try XCTUnwrap(target.data(forKey: AppPreferencesStore.envelopeKey))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: upgraded) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, AppPreferencesStore.formatVersion)
    }

    func testMalformedV1PreferencesEnvelopeDoesNotCompleteBundleMigration() throws {
        let source = makeDefaults(prefix: "defaults-migration-malformed-v1-source")
        let target = makeDefaults(prefix: "defaults-migration-malformed-v1-target")
        let malformedV1 = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "preferences": [
                "volume": 0.72,
                "playbackRate": 1.25,
                "playbackMode": "repeatOne",
                // Required v1 playbackScope intentionally missing.
            ],
        ])
        source.set(malformedV1, forKey: AppPreferencesStore.envelopeKey)

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(
            result,
            .retryRequired(
                invalidKeys: [AppPreferencesStore.envelopeKey],
                failedKeys: []
            )
        )
        XCTAssertNil(target.data(forKey: AppPreferencesStore.envelopeKey))
        XCTAssertNil(target.object(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testCopiesOnlyValidatedAllowlistAndMarksCompletion() {
        let source = makeDefaults(prefix: "defaults-migration-source")
        let target = makeDefaults(prefix: "defaults-migration-target")
        source.set(0.7, forKey: "userPreferredVolume")
        source.set(true, forKey: "userNormalizationEnabled")
        source.set("private-framework-value", forKey: "unknownInjectedKey")

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        guard case .migrated(let keys) = result else {
            return XCTFail("Expected successful migration, got \(result)")
        }
        XCTAssertEqual(Set(keys), ["userPreferredVolume", "userNormalizationEnabled"])
        XCTAssertEqual(target.double(forKey: "userPreferredVolume"), 0.7)
        XCTAssertTrue(target.bool(forKey: "userNormalizationEnabled"))
        XCTAssertNil(target.object(forKey: "unknownInjectedKey"))
        XCTAssertTrue(target.bool(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testInvalidAllowlistedValueDoesNotSetCompletionAndCanRetry() {
        let source = makeDefaults(prefix: "defaults-migration-invalid-source")
        let target = makeDefaults(prefix: "defaults-migration-invalid-target")
        source.set("loud", forKey: "userPreferredVolume")

        let first = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )
        XCTAssertEqual(
            first,
            .retryRequired(invalidKeys: ["userPreferredVolume"], failedKeys: [])
        )
        XCTAssertFalse(target.bool(forKey: UserDefaultsMigrator.migrationFlagKey()))

        source.set(0.4, forKey: "userPreferredVolume")
        let second = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )
        guard case .migrated = second else {
            return XCTFail("Expected retry to succeed, got \(second)")
        }
        XCTAssertEqual(target.double(forKey: "userPreferredVolume"), 0.4)
    }

    func testExistingCurrentValueWinsWithoutCopyingWholeDomain() {
        let source = makeDefaults(prefix: "defaults-migration-existing-source")
        let target = makeDefaults(prefix: "defaults-migration-existing-target")
        source.set(0.2, forKey: "userPreferredVolume")
        target.set(0.9, forKey: "userPreferredVolume")

        _ = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(target.double(forKey: "userPreferredVolume"), 0.9)
    }

    func testValidCurrentValueWinsEvenWhenLegacyValueIsInvalid() {
        let source = makeDefaults(prefix: "defaults-migration-invalid-source-valid-target")
        let target = makeDefaults(prefix: "defaults-migration-invalid-source-valid-target-result")
        source.set("loud", forKey: "userPreferredVolume")
        target.set(0.65, forKey: "userPreferredVolume")

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        guard case .migrated = result else {
            return XCTFail("A valid destination must not be blocked by corrupt legacy data")
        }
        XCTAssertEqual(target.double(forKey: "userPreferredVolume"), 0.65)
    }

    func testInvalidCurrentValueIsReplacedByValidLegacyValue() {
        let source = makeDefaults(prefix: "defaults-migration-valid-source-invalid-target")
        let target = makeDefaults(prefix: "defaults-migration-valid-source-invalid-target-result")
        source.set(0.35, forKey: "userPreferredVolume")
        target.set("loud", forKey: "userPreferredVolume")

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        guard case .migrated(let keys) = result else {
            return XCTFail("A valid legacy value should repair an invalid destination")
        }
        XCTAssertTrue(keys.contains("userPreferredVolume"))
        XCTAssertEqual(target.double(forKey: "userPreferredVolume"), 0.35)
    }

    func testFutureTargetWithoutSourceIsPreservedAndMigrationRemainsPending() {
        let source = makeDefaults(prefix: "defaults-migration-future-no-source")
        let target = makeDefaults(prefix: "defaults-migration-future-no-source-target")
        let futureEnvelope = Data(#"{"version":999,"preferences":{}}"#.utf8)
        target.set(futureEnvelope, forKey: AppPreferencesStore.envelopeKey)

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(
            result,
            .retryRequired(
                invalidKeys: [AppPreferencesStore.envelopeKey],
                failedKeys: []
            )
        )
        XCTAssertEqual(target.data(forKey: AppPreferencesStore.envelopeKey), futureEnvelope)
        XCTAssertNil(target.object(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testFutureTargetIsNotReplacedByValidV1SourceEnvelope() throws {
        let source = makeDefaults(prefix: "defaults-migration-v1-source-future-target")
        let target = makeDefaults(prefix: "defaults-migration-v1-source-future-target-result")
        let v1 = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "preferences": [
                "volume": 0.5,
                "playbackRate": 1.0,
                "playbackMode": "shuffle",
                "playbackScope": ["kind": "queue"],
            ],
        ])
        let future = Data(#"{"version":999,"preferences":{"keep":true}}"#.utf8)
        source.set(v1, forKey: AppPreferencesStore.envelopeKey)
        target.set(future, forKey: AppPreferencesStore.envelopeKey)

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(
            result,
            .retryRequired(
                invalidKeys: [AppPreferencesStore.envelopeKey],
                failedKeys: []
            )
        )
        XCTAssertEqual(target.data(forKey: AppPreferencesStore.envelopeKey), future)
        XCTAssertNil(target.object(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testOversizedTargetWithoutSourceIsPreservedAndMigrationRemainsPending() {
        let source = makeDefaults(prefix: "defaults-migration-oversized-no-source")
        let target = makeDefaults(prefix: "defaults-migration-oversized-no-source-target")
        let oversizedEnvelope = Data(repeating: 0xA5, count: 64 * 1_024 + 1)
        target.set(oversizedEnvelope, forKey: AppPreferencesStore.envelopeKey)

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(
            result,
            .retryRequired(
                invalidKeys: [AppPreferencesStore.envelopeKey],
                failedKeys: []
            )
        )
        XCTAssertEqual(target.data(forKey: AppPreferencesStore.envelopeKey), oversizedEnvelope)
        XCTAssertNil(target.object(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testInvalidSourceDoesNotDestroyUnrecognizedTarget() {
        let source = makeDefaults(prefix: "defaults-migration-invalid-envelope-source")
        let target = makeDefaults(prefix: "defaults-migration-invalid-envelope-target")
        let futureEnvelope = Data(#"{"version":7,"preferences":{}}"#.utf8)
        target.set(futureEnvelope, forKey: AppPreferencesStore.envelopeKey)
        source.set(Data(#"{"version":8}"#.utf8), forKey: AppPreferencesStore.envelopeKey)

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(
            result,
            .retryRequired(
                invalidKeys: [AppPreferencesStore.envelopeKey],
                failedKeys: []
            )
        )
        XCTAssertEqual(target.data(forKey: AppPreferencesStore.envelopeKey), futureEnvelope)
        XCTAssertNil(target.object(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testReplacementFailureRollsBackEveryPreviouslyWrittenPreference() {
        let source = makeDefaults(prefix: "defaults-migration-rollback-source")
        let target = makeRejectingDefaults(prefix: "defaults-migration-rollback-target")
        source.set(0.35, forKey: "userPreferredVolume")
        source.set(1.25, forKey: "userPlaybackRate")
        target.set("original-volume", forKey: "userPreferredVolume")
        target.set("original-rate", forKey: "userPlaybackRate")
        target.rejectedKey = "userPlaybackRate"

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(
            result,
            .retryRequired(invalidKeys: [], failedKeys: ["userPlaybackRate"])
        )
        XCTAssertEqual(target.string(forKey: "userPreferredVolume"), "original-volume")
        XCTAssertEqual(target.string(forKey: "userPlaybackRate"), "original-rate")
        XCTAssertNil(target.object(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testSuccessfulReplacementCommitsAllValuesBeforeCompletionMarker() {
        let source = makeDefaults(prefix: "defaults-migration-atomic-success-source")
        let target = makeDefaults(prefix: "defaults-migration-atomic-success-target")
        source.set(0.35, forKey: "userPreferredVolume")
        source.set(1.25, forKey: "userPlaybackRate")
        target.set("original-volume", forKey: "userPreferredVolume")
        target.set("original-rate", forKey: "userPlaybackRate")

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        guard case .migrated(let keys) = result else {
            return XCTFail("Expected an atomic successful replacement, got \(result)")
        }
        XCTAssertTrue(keys.contains("userPreferredVolume"))
        XCTAssertTrue(keys.contains("userPlaybackRate"))
        XCTAssertEqual(target.double(forKey: "userPreferredVolume"), 0.35)
        XCTAssertEqual(target.double(forKey: "userPlaybackRate"), 1.25)
        XCTAssertTrue(target.bool(forKey: UserDefaultsMigrator.migrationFlagKey()))
    }

    func testObsoleteRMSVolumeCacheIsRemovedAndNeverMigrated() {
        let source = makeDefaults(prefix: "defaults-migration-obsolete-source")
        let target = makeDefaults(prefix: "defaults-migration-obsolete-target")
        source.set(["/music/song.mp3": -12.0], forKey: "volumeNormalizationCache")
        target.set(["/music/current.mp3": -9.0], forKey: "volumeNormalizationCache")

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: "current.bundle",
            currentDefaults: target,
            legacyDefaults: source
        )

        guard case .migrated(let keys) = result else {
            return XCTFail("Obsolete derived data should not block preference migration")
        }
        XCTAssertFalse(keys.contains("volumeNormalizationCache"))
        XCTAssertNil(target.object(forKey: "volumeNormalizationCache"))
        XCTAssertFalse(UserDefaultsMigrator.allowedKeys.contains("volumeNormalizationCache"))
    }

    func testRunningUnderLegacyBundleDoesNothing() {
        let source = makeDefaults(prefix: "defaults-migration-same-source")
        let target = makeDefaults(prefix: "defaults-migration-same-target")
        source.set(0.2, forKey: "userPreferredVolume")

        let result = UserDefaultsMigrator.migrateFromLegacyBundleIdentifierIfNeeded(
            currentBundleIdentifier: UserDefaultsMigrator.legacyBundleIdentifier,
            currentDefaults: target,
            legacyDefaults: source
        )

        XCTAssertEqual(result, .skippedCurrentBundle)
        XCTAssertNil(target.object(forKey: "userPreferredVolume"))
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeRejectingDefaults(prefix: String) -> RejectingUserDefaults {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = RejectingUserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

private final class RejectingUserDefaults: UserDefaults {
    var rejectedKey: String?

    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != rejectedKey else { return }
        super.set(value, forKey: defaultName)
    }
}
