import Foundation

enum UserDefaultsMigrator {
    /// Legacy bundle identifier used by older builds of this project.
    /// We migrate its UserDefaults keys into the current bundle id on first launch after upgrade.
    static let legacyBundleIdentifier = "com.musicplayer.macos"

    private static var migrationFlagKey: String {
        "didMigrateUserDefaultsFrom_\(legacyBundleIdentifier)"
    }

    static func migrateFromLegacyBundleIdentifierIfNeeded(currentBundleIdentifier: String?) {
        // If we're still running under the legacy bundle id, there's nothing to migrate.
        guard currentBundleIdentifier != legacyBundleIdentifier else { return }

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationFlagKey) { return }

        guard let legacy = UserDefaults(suiteName: legacyBundleIdentifier) else {
            defaults.set(true, forKey: migrationFlagKey)
            return
        }

        let legacyValues = legacy.dictionaryRepresentation()
        if legacyValues.isEmpty {
            defaults.set(true, forKey: migrationFlagKey)
            return
        }

        for (key, value) in legacyValues {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        defaults.set(true, forKey: migrationFlagKey)
    }
}

