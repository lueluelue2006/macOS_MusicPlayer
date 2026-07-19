import Foundation

enum UserDefaultsMigrator {
    /// Legacy bundle identifier used by released builds before the unique
    /// reverse-DNS bundle identifier was introduced.
    static let legacyBundleIdentifier = "com.musicplayer.macos"
    private static let obsoleteDerivedKeys = ["volumeNormalizationCache"]

    enum MigrationResult: Equatable {
        case skippedCurrentBundle
        case alreadyCompleted
        case migrated(keys: [String])
        case retryRequired(invalidKeys: [String], failedKeys: [String])
    }

    private enum ValueRule {
        case boolean
        case integer(ClosedRange<Int>)
        case finiteNumber(ClosedRange<Double>?)
        case string(maximumUTF8Bytes: Int, allowed: Set<String>? = nil)
        case data(maximumBytes: Int)
        case appPreferencesJSONData(maximumBytes: Int)
        case versionedJSONData(maximumBytes: Int, supportedVersions: ClosedRange<Int>)
        case stringArray(maximumCount: Int, maximumUTF8BytesPerItem: Int)
    }

    private struct AllowedPreference {
        let key: String
        let rule: ValueRule
    }

    private struct PlannedReplacement {
        let key: String
        let sourceValue: Any
        let originalValue: Any?
    }

    private struct VersionProbe: Decodable {
        let version: Int?
    }

    private struct AppPreferencesEnvelopeV1: Decodable {
        struct Preferences: Decodable {
            struct Scope: Decodable {
                enum Kind: String, Decodable { case queue, playlist }

                let kind: Kind
                let playlistID: UUID?

                private enum CodingKeys: String, CodingKey {
                    case kind, playlistID
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    kind = try container.decode(Kind.self, forKey: .kind)
                    playlistID = try container.decodeIfPresent(UUID.self, forKey: .playlistID)
                    switch kind {
                    case .queue:
                        guard playlistID == nil else {
                            throw DecodingError.dataCorruptedError(
                                forKey: .playlistID,
                                in: container,
                                debugDescription: "Queue scope must not carry a playlist ID"
                            )
                        }
                    case .playlist:
                        guard playlistID != nil else {
                            throw DecodingError.keyNotFound(
                                CodingKeys.playlistID,
                                .init(
                                    codingPath: decoder.codingPath,
                                    debugDescription: "Playlist scope requires a playlist ID"
                                )
                            )
                        }
                    }
                }
            }

            let volume: Float
            let playbackRate: Float
            let playbackMode: AppPreferencesStore.PlaybackMode
            let playbackScope: Scope
        }

        let version: Int
        let preferences: Preferences
    }

    private struct AppPreferencesEnvelopeV2: Decodable {
        let version: Int
        let preferences: AppPreferencesStore.Preferences
    }

    /// This is intentionally an explicit product-owned list. AppKit and future
    /// frameworks may add arbitrary values to a preferences domain; those must
    /// never be copied merely because they happen to be present.
    private static let allowlist: [AllowedPreference] = [
        .init(
            key: AppPreferencesStore.envelopeKey,
            rule: .appPreferencesJSONData(maximumBytes: 64 * 1_024)
        ),
        .init(
            key: PlaybackStateStore.envelopeKey,
            rule: .versionedJSONData(
                maximumBytes: 64 * 1_024,
                supportedVersions: PlaybackStateStore.formatVersion ... PlaybackStateStore.formatVersion
            )
        ),
        .init(
            key: SearchSortState.envelopeKey,
            rule: .versionedJSONData(
                maximumBytes: 256 * 1_024,
                supportedVersions: SearchSortState.formatVersion ... SearchSortState.formatVersion
            )
        ),
        .init(key: SearchSortState.legacyKey, rule: .data(maximumBytes: 1_048_576)),
        .init(
            key: "pathKeyMigrationState",
            rule: .versionedJSONData(maximumBytes: 2_097_152, supportedVersions: 1...3)
        ),

        .init(key: "userPreferredVolume", rule: .finiteNumber(0...1)),
        .init(key: "userPlaybackRate", rule: .finiteNumber(0.5...2)),
        .init(key: "userPreferredPlaybackRate", rule: .finiteNumber(0.5...2)),
        .init(key: "userPlaybackMode", rule: .string(
            maximumUTF8Bytes: 32,
            allowed: ["shuffle", "repeatOne"]
        )),
        .init(key: "userLoopingEnabled", rule: .boolean),
        .init(key: "userShuffleEnabled", rule: .boolean),
        .init(key: "userPlaybackScopeKind", rule: .string(
            maximumUTF8Bytes: 32,
            allowed: ["queue", "playlist"]
        )),
        .init(key: "userPlaybackScopePlaylistID", rule: .string(
            maximumUTF8Bytes: 64
        )),
        .init(key: "lastPlayedFilePath", rule: .string(maximumUTF8Bytes: 16_384)),
        .init(key: "lastPlayedFileTime", rule: .finiteNumber(0...Double.greatestFiniteMagnitude)),

        .init(key: "userNormalizationEnabled", rule: .boolean),
        .init(key: "userImmersivePlaybackEnabled", rule: .boolean),
        .init(key: "userAnalyzeVolumesDuringPlayback", rule: .boolean),
        .init(key: "userAutoPreanalyzeVolumesWhenIdle", rule: .boolean),
        .init(key: "userNormalizationTargetLUFS", rule: .finiteNumber(-30 ... -8)),
        .init(key: "userNormalizationFadeDuration", rule: .finiteNumber(0...1.5)),
        .init(key: "userRequireVolumeAnalysisBeforePlayback", rule: .boolean),

        .init(key: "userScanSubfoldersEnabled", rule: .boolean),
        .init(key: "userNotifyOnDeviceSwitch", rule: .boolean),
        .init(key: "userNotifyDeviceSwitchSilent", rule: .boolean),
        .init(key: "userColorSchemeOverride", rule: .integer(0...2)),
        .init(key: "userPlaylistPanelMode", rule: .integer(0...1)),
        .init(key: "compactRootPane", rule: .integer(0...1)),
        .init(key: "ipcDebugEnabled", rule: .boolean),
        .init(key: "savedPlaylistIndex", rule: .integer(0...Int.max)),

        // Explicit AppKit keys retained for window continuity across the one
        // historical bundle-identifier migration.
        .init(key: "NSWindow Frame main", rule: .string(maximumUTF8Bytes: 1_024)),
        .init(
            key: "NSSplitView Subview Frames main, SidebarNavigationSplitView",
            rule: .stringArray(maximumCount: 8, maximumUTF8BytesPerItem: 1_024)
        ),
        .init(key: "NSNavPanelExpandedSizeForOpenMode", rule: .string(maximumUTF8Bytes: 256)),
        .init(key: "NSOSPLastRootDirectory", rule: .data(maximumBytes: 1_048_576)),
    ]

    static var allowedKeys: Set<String> {
        Set(allowlist.map(\.key))
    }

    static func migrationFlagKey(for legacyIdentifier: String = legacyBundleIdentifier) -> String {
        "didMigrateUserDefaultsFrom_\(legacyIdentifier)"
    }

    @discardableResult
    static func migrateFromLegacyBundleIdentifierIfNeeded(
        currentBundleIdentifier: String?,
        currentDefaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = nil,
        legacyIdentifier: String = legacyBundleIdentifier
    ) -> MigrationResult {
        obsoleteDerivedKeys.forEach(currentDefaults.removeObject(forKey:))
        guard currentBundleIdentifier != legacyIdentifier else {
            return .skippedCurrentBundle
        }

        let flagKey = migrationFlagKey(for: legacyIdentifier)
        if currentDefaults.bool(forKey: flagKey) {
            return .alreadyCompleted
        }

        let source: UserDefaults?
        if let legacyDefaults {
            source = legacyDefaults
        } else {
            source = UserDefaults(suiteName: legacyIdentifier)
        }
        let sourceValues = source?.dictionaryRepresentation() ?? [:]
        var replacements: [PlannedReplacement] = []
        var invalidKeys: [String] = []

        // Preflight the complete migration before mutating the destination.
        // This prevents one bad legacy value from leaving a partially migrated
        // preference domain and, crucially, preserves unknown/future target data.
        for entry in allowlist {
            let currentValue = currentDefaults.object(forKey: entry.key)
            if let currentValue, validate(currentValue, using: entry.rule) {
                // A valid destination wins even if stale legacy data is corrupt.
                continue
            }
            if currentValue != nil, isStructuredDataRule(entry.rule) {
                // Unknown, future, corrupt, or oversized structured target data
                // is protected byte-for-byte. A legacy source must never repair
                // it by replacement because this process cannot prove which
                // schema owns the newer destination.
                invalidKeys.append(entry.key)
                continue
            }

            guard let sourceValue = sourceValues[entry.key] else {
                // An absent value on both sides is expected. An existing target
                // that this version does not understand must remain untouched
                // and keeps the migration retryable for a newer build.
                if currentValue != nil {
                    invalidKeys.append(entry.key)
                }
                continue
            }
            guard validate(sourceValue, using: entry.rule) else {
                invalidKeys.append(entry.key)
                continue
            }

            replacements.append(
                PlannedReplacement(
                    key: entry.key,
                    sourceValue: sourceValue,
                    originalValue: currentValue
                )
            )
        }

        guard invalidKeys.isEmpty else {
            return .retryRequired(
                invalidKeys: invalidKeys.sorted(),
                failedKeys: []
            )
        }

        var committedReplacements: [PlannedReplacement] = []
        for replacement in replacements {
            currentDefaults.set(replacement.sourceValue, forKey: replacement.key)
            guard let stored = currentDefaults.object(forKey: replacement.key),
                  propertyListValuesEqual(replacement.sourceValue, stored) else {
                rollback(
                    committedReplacements + [replacement],
                    in: currentDefaults
                )
                return .retryRequired(invalidKeys: [], failedKeys: [replacement.key])
            }
            committedReplacements.append(replacement)
        }

        let originalFlagValue = currentDefaults.object(forKey: flagKey)
        currentDefaults.set(true, forKey: flagKey)
        guard let storedFlag = currentDefaults.object(forKey: flagKey),
              validate(storedFlag, using: .boolean),
              (storedFlag as? NSNumber)?.boolValue == true else {
            restore(originalFlagValue, forKey: flagKey, in: currentDefaults)
            rollback(committedReplacements, in: currentDefaults)
            return .retryRequired(invalidKeys: [], failedKeys: [flagKey])
        }
        return .migrated(keys: replacements.map(\.key).sorted())
    }

    private static func rollback(
        _ replacements: [PlannedReplacement],
        in defaults: UserDefaults
    ) {
        for replacement in replacements.reversed() {
            restore(replacement.originalValue, forKey: replacement.key, in: defaults)
        }
    }

    private static func restore(
        _ value: Any?,
        forKey key: String,
        in defaults: UserDefaults
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func validate(_ value: Any, using rule: ValueRule) -> Bool {
        switch rule {
        case .boolean:
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()

        case .integer(let range):
            guard let number = strictNumber(value) else { return false }
            let double = number.doubleValue
            guard double.isFinite,
                  double.rounded(.towardZero) == double,
                  double >= Double(Int.min),
                  double <= Double(Int.max) else { return false }
            return range.contains(Int(double))

        case .finiteNumber(let range):
            guard let number = strictNumber(value) else { return false }
            let double = number.doubleValue
            guard double.isFinite else { return false }
            return range?.contains(double) ?? true

        case .string(let maximumUTF8Bytes, let allowed):
            guard let string = value as? String,
                  string.utf8.count <= maximumUTF8Bytes else { return false }
            return allowed?.contains(string) ?? true

        case .data(let maximumBytes):
            guard let data = value as? Data else { return false }
            return data.count <= maximumBytes

        case .appPreferencesJSONData(let maximumBytes):
            guard let data = value as? Data,
                  data.count <= maximumBytes,
                  let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
                  let version = probe.version else { return false }
            switch version {
            case 1:
                return (try? JSONDecoder().decode(
                    AppPreferencesEnvelopeV1.self,
                    from: data
                ))?.version == 1
            case AppPreferencesStore.formatVersion:
                return (try? JSONDecoder().decode(
                    AppPreferencesEnvelopeV2.self,
                    from: data
                ))?.version == AppPreferencesStore.formatVersion
            default:
                return false
            }

        case .versionedJSONData(let maximumBytes, let supportedVersions):
            guard let data = value as? Data,
                  data.count <= maximumBytes,
                  let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
                  let version = probe.version else { return false }
            return supportedVersions.contains(version)

        case .stringArray(let maximumCount, let maximumUTF8BytesPerItem):
            guard let values = value as? [String], values.count <= maximumCount else {
                return false
            }
            return values.allSatisfy { $0.utf8.count <= maximumUTF8BytesPerItem }

        }
    }

    private static func isStructuredDataRule(_ rule: ValueRule) -> Bool {
        switch rule {
        case .appPreferencesJSONData, .versionedJSONData:
            return true
        default:
            return false
        }
    }

    private static func strictNumber(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func propertyListValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as AnyObject).isEqual(rhs)
    }
}
