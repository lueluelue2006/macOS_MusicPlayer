import Foundation
import AppKit

enum RegressionTests {
    private static let runFlagKey = "MUSICPLAYER_RUN_REGRESSION_TESTS"
    private static let exitFlagKey = "MUSICPLAYER_EXIT_AFTER_REGRESSION_TESTS"

    private final class ThreadSafeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

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

    @discardableResult
    static func runAll() async -> Bool {
        print("\n🧪 Starting Regression Tests...")
        print(String(repeating: "=", count: 58))

        var passed = 0
        var failed = 0

        let tests: [(String, () async -> Bool)] = [
            ("PathKey migration incremental trigger", testPathKeyMigrationIncrementalTrigger),
            ("Ephemeral playback persist-state isolation", testEphemeralPlaybackPersistStateIsolation),
            ("Playback scope restore from playlist", testPlaybackScopeRestoreFromPlaylist),
            ("Queue restore keeps saved index", testQueueRestoreKeepsSavedIndex),
            ("Playlist manager rejects negative indices", testPlaylistManagerRejectsNegativeIndices),
            ("Queue shuffle does not repeat direct selection", testQueueShuffleDoesNotRepeatDirectSelection),
            ("Restore probe failure does not auto-advance", testRestoreProbeFailureDoesNotAutoAdvance),
            ("Delete-current sequential fallback keeps next item", testDeleteCurrentSequentialFallbackKeepsNextItem),
            ("Playback weight white tier preserves green default", testPlaybackWeightWhiteTierPreservesGreenDefault)
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
        return failed == 0
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

            let manager = PlaylistManager(disablePersistence: true)
            defaults.set("playlist", forKey: kindKey)
            defaults.set(playlist.id.uuidString, forKey: playlistIDKey)

            await manager.restorePlaybackScopeIfNeeded(playlistsStore: store)

            let scopeIsPlaylist = await MainActor.run {
                manager.playbackScope == .playlist(playlist.id)
            }
            let queueContainsTrack = await MainActor.run {
                manager.audioFiles.contains(where: { PathKey.canonical(for: $0.url) == PathKey.canonical(for: trackURL) })
            }

            await manager.waitForBackgroundRestoreWorkForTesting()
            await MetadataCache.shared.remove(for: trackURL)
            await DurationCache.shared.remove(for: trackURL)
            try? await Task.sleep(nanoseconds: 700_000_000)
            return scopeIsPlaylist && queueContainsTrack
        } catch {
            print("   playback scope test error: \(error)")
            return false
        }
    }

    private static func testQueueRestoreKeepsSavedIndex() async -> Bool {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("musicplayer-regression-queue-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let urls = try (0..<3).map { idx -> URL in
                let url = tempRoot.appendingPathComponent("track-\(idx).mp3", isDirectory: false)
                try Data("x".utf8).write(to: url)
                return url
            }
            let playlistURL = tempRoot.appendingPathComponent("playlist.json", isDirectory: false)
            let payload: [String: Any] = [
                "paths": urls.map(\.path),
                "currentIndex": 2
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: playlistURL, options: .atomic)

            let manager = PlaylistManager(
                playlistFileURLOverride: playlistURL,
                disablePersistence: true
            )
            await manager.loadSavedPlaylist()
            await manager.waitForBackgroundRestoreWorkForTesting()
            let passed = await MainActor.run {
                manager.audioFiles.count == 3 && manager.currentIndex == 2
            }
            for url in urls {
                await MetadataCache.shared.remove(for: url)
                await DurationCache.shared.remove(for: url)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            return passed
        } catch {
            print("   queue restore index test error: \(error)")
            return false
        }
    }

    private static func testPlaylistManagerRejectsNegativeIndices() async -> Bool {
        let manager = PlaylistManager(disablePersistence: true)
        let url = URL(fileURLWithPath: "/tmp/musicplayer-regression-negative-\(UUID().uuidString).mp3")
        let file = AudioFile(
            url: url,
            metadata: AudioMetadata(title: "x", artist: "x", album: "x", year: nil, genre: nil, artwork: nil)
        )

        manager.audioFiles = [file]
        let selected = manager.selectFile(at: -1)
        manager.removeFile(at: -1)

        return selected == nil && manager.audioFiles.count == 1 && manager.currentIndex == 0
    }

    private static func testQueueShuffleDoesNotRepeatDirectSelection() async -> Bool {
        let manager = PlaylistManager(disablePersistence: true)
        let files = (0..<4).map { idx in
            AudioFile(
                url: URL(fileURLWithPath: "/tmp/musicplayer-regression-shuffle-\(idx)-\(UUID().uuidString).mp3"),
                metadata: AudioMetadata(title: "\(idx)", artist: "x", album: "x", year: nil, genre: nil, artwork: nil)
            )
        }
        manager.audioFiles = files
        manager.currentIndex = 1

        guard let next = manager.peekNextFile(isShuffling: true) else { return false }
        return next.url != files[1].url
    }

    private static func testRestoreProbeFailureDoesNotAutoAdvance() async -> Bool {
        let player = await MainActor.run { AudioPlayer() }
        let missingURL = URL(fileURLWithPath: "/tmp/musicplayer-regression-restore-missing-\(UUID().uuidString).mp3")
        let file = AudioFile(
            url: missingURL,
            metadata: AudioMetadata(title: "missing", artist: "x", album: "x", year: nil, genre: nil, artwork: nil)
        )

        let flag = ThreadSafeFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: .audioPlayerDidFinish,
            object: nil,
            queue: .main
        ) { _ in
            flag.set()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            Task { @MainActor in
                player.stopAndClearCurrent(clearLastPlayed: false)
            }
        }

        await MainActor.run {
            player.play(file, autostart: false, bypassConfirm: true)
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        return !flag.get()
    }

    private static func testDeleteCurrentSequentialFallbackKeepsNextItem() async -> Bool {
        let manager = PlaylistManager(disablePersistence: true)
        let files = (0..<3).map { idx in
            AudioFile(
                url: URL(fileURLWithPath: "/tmp/musicplayer-regression-delete-\(idx)-\(UUID().uuidString).mp3"),
                metadata: AudioMetadata(title: "\(idx)", artist: "x", album: "x", year: nil, genre: nil, artwork: nil)
            )
        }
        manager.audioFiles = files
        manager.currentIndex = 0
        manager.removeFile(at: 0)

        guard let next = manager.nextFileAfterRemovingQueueItem(atDeletedIndex: 0) else {
            return false
        }
        return next.url == files[1].url && manager.currentIndex == 0
    }

    private static func testPlaybackWeightWhiteTierPreservesGreenDefault() async -> Bool {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("musicplayer-regression-weights-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let weights = PlaybackWeights(cacheFileURLOverride: tempRoot.appendingPathComponent("playback-weights.json"))
        let url = URL(fileURLWithPath: "/tmp/musicplayer-regression-weight-\(UUID().uuidString).mp3")
        let playlistID = UUID()

        guard PlaybackWeights.Level.allCases.prefix(2).elementsEqual([.white, .green]) else { return false }
        guard weights.level(for: url, scope: .queue) == .green else { return false }
        guard PlaybackWeights.Level.white.rawValue == -1,
              PlaybackWeights.Level.green.rawValue == 0,
              PlaybackWeights.Level.white.multiplier == 0.5,
              PlaybackWeights.Level.green.multiplier == 1.0
        else { return false }

        weights.setLevel(.white, for: url, scope: .queue)
        guard weights.level(for: url, scope: .queue) == .white else { return false }

        weights.setLevel(.green, for: url, scope: .queue)
        guard weights.level(for: url, scope: .queue) == .green else { return false }

        weights.setLevel(.white, for: url, scope: .playlist(playlistID))
        let sync = weights.syncPlaylistOverridesToQueue(from: playlistID)
        return sync.total == 1 &&
            sync.changed == 1 &&
            weights.level(for: url, scope: .queue) == .white
    }
}
