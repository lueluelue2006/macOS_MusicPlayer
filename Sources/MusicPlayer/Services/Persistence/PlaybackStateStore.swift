import Foundation

/// Manages persistence of playback state (last played file and progress).
///
/// Design:
/// - Encapsulates UserDefaults access for playback state
/// - Supports "persistent" vs "temporary" playback modes
/// - Thread-safe via UserDefaults synchronization
final class PlaybackStateStore {
    struct State: Equatable {
        let filePath: String
        let lastPlayedTime: TimeInterval
    }

    private let userDefaults: UserDefaults
    private let disablesPersistence: Bool
    private let lastPlayedFilePathKey = "lastPlayedFilePath"
    private let lastPlayedFileTimeKey = "lastPlayedFileTime"

    init(
        userDefaults: UserDefaults = .standard,
        disablesPersistence: Bool = false
    ) {
        self.userDefaults = userDefaults
        self.disablesPersistence = disablesPersistence
    }

    // MARK: - Read

    func loadState() -> State? {
        guard !disablesPersistence else { return nil }
        guard let filePath = userDefaults.string(forKey: lastPlayedFilePathKey) else {
            return nil
        }
        let lastPlayedTime = userDefaults.double(forKey: lastPlayedFileTimeKey)
        return State(filePath: filePath, lastPlayedTime: lastPlayedTime)
    }

    // MARK: - Write

    func saveFile(_ url: URL, initialTime: TimeInterval? = nil) {
        guard !disablesPersistence else { return }
        userDefaults.set(url.path, forKey: lastPlayedFilePathKey)
        if let time = initialTime {
            userDefaults.set(max(0, time), forKey: lastPlayedFileTimeKey)
        }
    }

    func saveProgress(_ time: TimeInterval) {
        guard !disablesPersistence else { return }
        userDefaults.set(time, forKey: lastPlayedFileTimeKey)
    }

    // MARK: - Clear

    func clearIfMatching(_ url: URL) {
        guard !disablesPersistence else { return }
        guard let savedPath = userDefaults.string(forKey: lastPlayedFilePathKey) else { return }
        guard PathKey.canonical(path: savedPath) == PathKey.canonical(for: url) else { return }
        userDefaults.removeObject(forKey: lastPlayedFilePathKey)
        userDefaults.removeObject(forKey: lastPlayedFileTimeKey)
    }

    func clearAll() {
        guard !disablesPersistence else { return }
        userDefaults.removeObject(forKey: lastPlayedFilePathKey)
        userDefaults.removeObject(forKey: lastPlayedFileTimeKey)
    }
}
