import Foundation
import AppKit

enum RegressionTests {
    private static let runFlagKey = "MUSICPLAYER_RUN_REGRESSION_TESTS"
    private static let exitFlagKey = "MUSICPLAYER_EXIT_AFTER_REGRESSION_TESTS"

    static func runIfEnabled() async {
        let env = ProcessInfo.processInfo.environment
        guard env[runFlagKey] == "1" else { return }
        await runAll()
        if env[exitFlagKey] == "1" {
            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
    }

    static func runAll() async {
        print("\n🧪 Starting Regression Tests...")
        print(String(repeating: "=", count: 58))

        var passed = 0
        var failed = 0

        let tests: [(String, () async -> Bool)] = [
            ("PathKey migration incremental trigger", testPathKeyMigrationIncrementalTrigger),
            ("Ephemeral playback persist-state isolation", testEphemeralPlaybackPersistStateIsolation),
            ("Playback scope restore from playlist", testPlaybackScopeRestoreFromPlaylist)
        ]

        for (name, test) in tests {
            let ok = await test()
            if ok {
                passed += 1
                print("✅ \(name)")
            } else {
                failed += 1
                print("❌ \(name)")
            }
        }

        print(String(repeating: "-", count: 58))
        print("Regression Result: \(passed) passed, \(failed) failed")
        if failed == 0 {
            print("🎉 All regression tests passed")
        } else {
            print("⚠️ Regression failures detected")
        }
    }

    private static func testPathKeyMigrationIncrementalTrigger() async -> Bool {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("musicplayer-regression-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            let mixedDir = tempRoot
                .appendingPathComponent("CaseFolder", isDirectory: true)
                .appendingPathComponent("SubFolder", isDirectory: true)
            try fm.createDirectory(at: mixedDir, withIntermediateDirectories: true)

            let songURL = mixedDir.appendingPathComponent("TestSong.mp3", isDirectory: false)
            fm.createFile(atPath: songURL.path, contents: Data("ok".utf8))

            let canonical = PathKey.canonical(for: songURL)
            let legacy = canonical.lowercased()

            let metadataURL = tempRoot.appendingPathComponent("metadata-cache.json", isDirectory: false)
            let payload: [String: Any] = [
                "version": 1,
                "entries": [
                    legacy: [
                        "title": "T",
                        "artist": "A",
                        "album": "B",
                        "fileSize": 2,
                        "mtimeNs": 1
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: metadataURL, options: .atomic)

            let first = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
                baseDirectory: tempRoot,
                previousStateData: nil
            )
            guard first.didRun, first.migrationResult.failedFiles.isEmpty else { return false }

            let migratedData = try Data(contentsOf: metadataURL)
            guard let root = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any],
                  let entries = root["entries"] as? [String: Any],
                  entries[canonical] != nil,
                  entries[legacy] == nil
            else {
                return false
            }

            guard let state = first.savedStateData else { return false }

            let second = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
                baseDirectory: tempRoot,
                previousStateData: state
            )
            guard second.didRun == false else { return false }

            let playlistURL = tempRoot.appendingPathComponent("playlist.json", isDirectory: false)
            let playlistPayload: [String: Any] = ["paths": [], "currentIndex": 0]
            let playlistData = try JSONSerialization.data(withJSONObject: playlistPayload, options: [])
            try playlistData.write(to: playlistURL, options: .atomic)

            let third = PathKeyDiskMigrator.debugRunIncrementalMigrationForTesting(
                baseDirectory: tempRoot,
                previousStateData: state
            )
            guard third.didRun else { return false }
            return third.migrationResult.failedFiles.isEmpty
        } catch {
            print("   migration test error: \(error)")
            return false
        }
    }

    private static func testEphemeralPlaybackPersistStateIsolation() async -> Bool {
        let player = await MainActor.run { AudioPlayer() }
        await MainActor.run {
            player.persistPlaybackState = true
        }

        let missingURL = URL(fileURLWithPath: "/tmp/musicplayer-regression-missing-\(UUID().uuidString).mp3")
        let file = AudioFile(
            url: missingURL,
            metadata: AudioMetadata(title: "x", artist: "x", album: "x", year: nil, genre: nil, artwork: nil)
        )

        await MainActor.run {
            player.play(file, persist: false)
        }

        try? await Task.sleep(nanoseconds: 700_000_000)

        let stillPersistent = await MainActor.run { player.persistPlaybackState }
        await MainActor.run {
            player.stopAndClearCurrent(clearLastPlayed: false)
        }
        return stillPersistent
    }

    private static func testPlaybackScopeRestoreFromPlaylist() async -> Bool {
        let defaults = UserDefaults.standard
        let kindKey = "userPlaybackScopeKind"
        let playlistIDKey = "userPlaybackScopePlaylistID"

        let originalKind = defaults.string(forKey: kindKey)
        let originalPlaylistID = defaults.string(forKey: playlistIDKey)
        defer {
            if let originalKind {
                defaults.set(originalKind, forKey: kindKey)
            } else {
                defaults.removeObject(forKey: kindKey)
            }
            if let originalPlaylistID {
                defaults.set(originalPlaylistID, forKey: playlistIDKey)
            } else {
                defaults.removeObject(forKey: playlistIDKey)
            }
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("musicplayer-regression-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let trackURL = tempRoot.appendingPathComponent("scope-test.mp3", isDirectory: false)
            fm.createFile(atPath: trackURL.path, contents: Data("x".utf8))

            let playlist = UserPlaylist(name: "Regression", tracks: [.init(path: trackURL.path)])
            let store = await MainActor.run { () -> PlaylistsStore in
                let instance = PlaylistsStore()
                instance.debugSetPlaylistsForTesting([playlist], selectedID: playlist.id)
                return instance
            }

            let manager = PlaylistManager()
            defaults.set("playlist", forKey: kindKey)
            defaults.set(playlist.id.uuidString, forKey: playlistIDKey)

            await manager.restorePlaybackScopeIfNeeded(playlistsStore: store)

            let scopeIsPlaylist = await MainActor.run {
                manager.playbackScope == .playlist(playlist.id)
            }
            let queueContainsTrack = await MainActor.run {
                manager.audioFiles.contains(where: { PathKey.canonical(for: $0.url) == PathKey.canonical(for: trackURL) })
            }

            return scopeIsPlaylist && queueContainsTrack
        } catch {
            print("   playback scope test error: \(error)")
            return false
        }
    }
}
