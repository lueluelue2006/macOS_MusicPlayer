import Foundation

enum PathKeyDiskMigrator {
    private static let migrationStateDefaultsKey = "pathKeyMigrationState"
    private static let migrationVersion = 2
    private static let trackedFiles: [String] = [
        "metadata-cache.json",
        "duration-cache.json",
        "volume-cache.json",
        "playback-weights.json",
        "playlist.json",
        "user-playlists.json"
    ]

    static func migrateLegacyLowercasedKeysIfNeeded() {
        guard let appSupport = appSupportDirectory() else { return }

        let beforeState = computeMigrationState(baseDirectory: appSupport)
        if let saved = loadMigrationState(), saved == beforeState {
            return
        }

        let result = migrateLegacyLowercasedKeys(baseDirectory: appSupport)
        if !result.failedFiles.isEmpty {
            PersistenceLogger.log("路径键迁移未完成，失败文件: \(result.failedFiles.joined(separator: ", "))")
            return
        }

        let afterState = computeMigrationState(baseDirectory: appSupport)
        saveMigrationState(afterState)
    }

    @discardableResult
    static func migrateLegacyLowercasedKeys() -> MigrationResult {
        guard let appSupport = appSupportDirectory() else {
            return MigrationResult(changedFiles: 0, changedEntries: 0, failedFiles: [])
        }

        let result = migrateLegacyLowercasedKeys(baseDirectory: appSupport)
        if result.failedFiles.isEmpty {
            saveMigrationState(computeMigrationState(baseDirectory: appSupport))
        }
        return result
    }

    private static func migrateLegacyLowercasedKeys(baseDirectory: URL) -> MigrationResult {
        var resolverCache: [String: [String]] = [:]
        var changedFiles = 0
        var changedEntries = 0
        var failedFiles: [String] = []

        for task in migrationTasks(baseDirectory: baseDirectory) {
            switch task.run(&resolverCache) {
            case .unchanged:
                break
            case .changed(let entries):
                changedFiles += 1
                changedEntries += entries
            case .failed(let fileName):
                failedFiles.append(fileName)
            }
        }

        if changedFiles > 0 {
            PersistenceLogger.log("路径键迁移完成：修改文件 \(changedFiles) 个，迁移条目 \(changedEntries) 条")
        }

        return MigrationResult(changedFiles: changedFiles, changedEntries: changedEntries, failedFiles: failedFiles)
    }

    private static func appSupportDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("MusicPlayer", isDirectory: true)
    }

    private static func computeMigrationState(baseDirectory: URL) -> MigrationState {
        var signatures: [String: FileSignature] = [:]
        signatures.reserveCapacity(trackedFiles.count)

        for fileName in trackedFiles {
            let fileURL = baseDirectory.appendingPathComponent(fileName, isDirectory: false)
            signatures[fileName] = fileSignature(of: fileURL)
        }

        return MigrationState(version: migrationVersion, fileSignatures: signatures)
    }

    private static func fileSignature(of fileURL: URL) -> FileSignature {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        do {
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(values.fileSize ?? -1)
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let mtimeNs = Int64((mtime * 1_000_000_000.0).rounded())
            return .present(size: size, mtimeNs: mtimeNs)
        } catch {
            return .missing
        }
    }

    private static func loadMigrationState() -> MigrationState? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: migrationStateDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(MigrationState.self, from: data)
    }

    private static func saveMigrationState(_ state: MigrationState) {
        let defaults = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: migrationStateDefaultsKey)
    }

    private static func migrationTasks(baseDirectory: URL) -> [MigrationTask] {
        [
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("metadata-cache.json", isDirectory: false)) { fileURL, cache in
                migratePathMapFile(at: fileURL, mapKey: "entries", resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("duration-cache.json", isDirectory: false)) { fileURL, cache in
                migratePathMapFile(at: fileURL, mapKey: "entries", resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("volume-cache.json", isDirectory: false)) { fileURL, cache in
                migratePathMapFile(at: fileURL, mapKey: "loudnessDbByPath", resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("playback-weights.json", isDirectory: false)) { fileURL, cache in
                migratePlaybackWeightsFile(at: fileURL, resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("playlist.json", isDirectory: false)) { fileURL, cache in
                migratePlaylistSnapshotFile(at: fileURL, resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("user-playlists.json", isDirectory: false)) { fileURL, cache in
                migrateUserPlaylistsFile(at: fileURL, resolverCache: &cache)
            }
        ]
    }

    private static func migratePathMapFile(
        at url: URL,
        mapKey: String,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unchanged }
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawMap = root[mapKey] as? [String: Any]
        else {
            return .failed(fileName: url.lastPathComponent)
        }

        let (migratedMap, changedEntries) = migratePathMap(rawMap, resolverCache: &resolverCache)
        guard changedEntries > 0 else { return .unchanged }

        root[mapKey] = migratedMap
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    private static func migratePlaybackWeightsFile(
        at url: URL,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unchanged }
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failed(fileName: url.lastPathComponent)
        }

        var changedEntries = 0

        if let queueLevels = root["queueLevels"] as? [String: Any] {
            let (migratedQueue, changes) = migratePathMap(queueLevels, resolverCache: &resolverCache)
            if changes > 0 {
                root["queueLevels"] = migratedQueue
                changedEntries += changes
            }
        }

        if let playlistLevels = root["playlistLevels"] as? [String: Any] {
            var updatedPlaylistLevels = playlistLevels
            var playlistChangedEntries = 0
            for (playlistID, rawValue) in playlistLevels {
                guard let levelMap = rawValue as? [String: Any] else { continue }
                let (migratedMap, changes) = migratePathMap(levelMap, resolverCache: &resolverCache)
                if changes > 0 {
                    updatedPlaylistLevels[playlistID] = migratedMap
                    playlistChangedEntries += changes
                }
            }
            if playlistChangedEntries > 0 {
                root["playlistLevels"] = updatedPlaylistLevels
                changedEntries += playlistChangedEntries
            }
        }

        guard changedEntries > 0 else { return .unchanged }
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    private static func migratePlaylistSnapshotFile(
        at url: URL,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unchanged }
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let paths = root["paths"] as? [String]
        else {
            return .failed(fileName: url.lastPathComponent)
        }

        let (migratedPaths, changes) = migratePathArray(paths, resolverCache: &resolverCache)
        guard changes > 0 else { return .unchanged }

        root["paths"] = migratedPaths
        return writeJSON(root, to: url, changedEntries: changes)
    }

    private static func migrateUserPlaylistsFile(
        at url: URL,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unchanged }
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawPlaylists = root["playlists"] as? [[String: Any]]
        else {
            return .failed(fileName: url.lastPathComponent)
        }

        var playlists = rawPlaylists
        var changedEntries = 0

        for index in playlists.indices {
            guard let tracks = playlists[index]["tracks"] as? [[String: Any]] else { continue }
            var seen = Set<String>()
            var migratedTracks: [[String: Any]] = []
            migratedTracks.reserveCapacity(tracks.count)
            var playlistChanged = false

            for var track in tracks {
                guard let rawPath = track["path"] as? String else {
                    migratedTracks.append(track)
                    continue
                }

                let migratedPath = migratePathKey(rawPath, resolverCache: &resolverCache)
                if migratedPath != rawPath {
                    track["path"] = migratedPath
                    changedEntries += 1
                    playlistChanged = true
                }

                let dedupKey = PathKey.canonical(path: migratedPath)
                if seen.insert(dedupKey).inserted {
                    migratedTracks.append(track)
                } else {
                    changedEntries += 1
                    playlistChanged = true
                }
            }

            if playlistChanged {
                playlists[index]["tracks"] = migratedTracks
            }
        }

        guard changedEntries > 0 else { return .unchanged }
        root["playlists"] = playlists
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL, changedEntries: Int) -> MigrationFileResult {
        guard JSONSerialization.isValidJSONObject(object),
              let output = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return .failed(fileName: url.lastPathComponent)
        }
        do {
            try output.write(to: url, options: .atomic)
            return .changed(entries: changedEntries)
        } catch {
            return .failed(fileName: url.lastPathComponent)
        }
    }

    private static func migratePathMap(
        _ rawMap: [String: Any],
        resolverCache: inout [String: [String]]
    ) -> ([String: Any], Int) {
        guard !rawMap.isEmpty else { return (rawMap, 0) }

        let orderedKeys = rawMap.keys.sorted { lhs, rhs in
            let lLegacy = isLegacyLowercasedKey(lhs)
            let rLegacy = isLegacyLowercasedKey(rhs)
            if lLegacy == rLegacy {
                return lhs < rhs
            }
            return !lLegacy && rLegacy
        }

        var migrated: [String: Any] = [:]
        migrated.reserveCapacity(rawMap.count)
        var changedEntries = 0

        for key in orderedKeys {
            guard let value = rawMap[key] else { continue }
            let migratedKey = migratePathKey(key, resolverCache: &resolverCache)
            if migratedKey != key {
                changedEntries += 1
            }

            if migrated[migratedKey] == nil {
                migrated[migratedKey] = value
            } else if migratedKey != key {
                changedEntries += 1
            }
        }

        if migrated.count != rawMap.count {
            changedEntries += abs(rawMap.count - migrated.count)
        }

        return (migrated, changedEntries)
    }

    private static func migratePathArray(
        _ rawPaths: [String],
        resolverCache: inout [String: [String]]
    ) -> ([String], Int) {
        guard !rawPaths.isEmpty else { return (rawPaths, 0) }

        var migrated: [String] = []
        migrated.reserveCapacity(rawPaths.count)
        var seen = Set<String>()
        var changedEntries = 0

        for path in rawPaths {
            let migratedPath = migratePathKey(path, resolverCache: &resolverCache)
            if migratedPath != path {
                changedEntries += 1
            }

            let dedupKey = PathKey.canonical(path: migratedPath)
            if seen.insert(dedupKey).inserted {
                migrated.append(migratedPath)
            } else {
                changedEntries += 1
            }
        }

        return (migrated, changedEntries)
    }

    private static func migratePathKey(_ rawPath: String, resolverCache: inout [String: [String]]) -> String {
        let standardized = PathKey.canonical(path: rawPath)
        guard standardized.hasPrefix("/") else { return standardized }
        guard isLegacyLowercasedKey(standardized) else { return standardized }

        let resolved = resolvePathPreservingCasePrefix(standardized, resolverCache: &resolverCache)
        return PathKey.canonical(path: resolved)
    }

    private static func resolvePathPreservingCasePrefix(
        _ absolutePath: String,
        resolverCache: inout [String: [String]]
    ) -> String {
        let normalized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let components = URL(fileURLWithPath: normalized).pathComponents
        guard components.count > 1 else { return normalized }

        var currentPath = "/"
        let all = Array(components.dropFirst())
        var index = 0

        while index < all.count {
            let component = all[index]
            guard let matched = resolveComponent(
                component,
                inDirectory: currentPath,
                resolverCache: &resolverCache
            ) else {
                let remaining = all[index...].joined(separator: "/")
                if currentPath == "/" {
                    return "/" + remaining
                }
                return (currentPath as NSString).appendingPathComponent(remaining)
            }
            currentPath = (currentPath as NSString).appendingPathComponent(matched)
            index += 1
        }

        return currentPath
    }

    private static func resolveComponent(
        _ component: String,
        inDirectory directory: String,
        resolverCache: inout [String: [String]]
    ) -> String? {
        let entries: [String]
        if let cached = resolverCache[directory] {
            entries = cached
        } else {
            guard let fetched = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            resolverCache[directory] = fetched
            entries = fetched
        }

        if entries.contains(component) {
            return component
        }

        return entries.first {
            $0.compare(component, options: [.caseInsensitive, .widthInsensitive], range: nil, locale: nil) == .orderedSame
        }
    }

    private static func isLegacyLowercasedKey(_ key: String) -> Bool {
        key == key.lowercased()
    }
}

extension PathKeyDiskMigrator {
    struct MigrationResult {
        let changedFiles: Int
        let changedEntries: Int
        let failedFiles: [String]
    }

    private struct MigrationState: Codable, Equatable {
        let version: Int
        let fileSignatures: [String: FileSignature]
    }

    private enum FileSignature: Codable, Equatable {
        case missing
        case present(size: Int64, mtimeNs: Int64)
    }

    private struct MigrationTask {
        let fileURL: URL
        let body: (_ url: URL, _ resolverCache: inout [String: [String]]) -> MigrationFileResult

        func run(_ resolverCache: inout [String: [String]]) -> MigrationFileResult {
            body(fileURL, &resolverCache)
        }
    }

    private enum MigrationFileResult {
        case unchanged
        case changed(entries: Int)
        case failed(fileName: String)
    }
}
