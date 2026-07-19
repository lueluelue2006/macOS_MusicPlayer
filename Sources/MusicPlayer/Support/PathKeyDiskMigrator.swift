import Foundation
import Darwin

enum PathKeyDiskMigrator {
    private static let migrationStateDefaultsKey = "pathKeyMigrationState"
    private static let migrationVersion = 3
    private static let maximumMigratedFileBytes = 16 * 1_024 * 1_024
    private static let maximumDerivedCacheFileBytes = 8 * 1_024 * 1_024
    private static let maximumPathBytes = 16 * 1_024
    private static let maximumDerivedCacheEntries = 8_192
    private static let maximumVolumeEntries = 20_000
    private static let maximumQueueEntries = 100_000
    private static let maximumQueueAggregatePathBytes = 12 * 1_024 * 1_024
    private static let maximumQueueWeightRekeys = 4_096
    private static let maximumWeightPlaylistCount = 2_000
    private static let maximumWeightEntriesPerPlaylist = 50_000
    private static let maximumWeightEntries = 100_000
    private static let maximumWeightAggregatePathBytes = 12 * 1_024 * 1_024
    private static let maximumUserPlaylistCount = 2_000
    private static let maximumUserPlaylistTrackCount = 50_000
    private static let maximumCleanupIntentCount = 10_000
    private static let maximumPlaylistNameBytes = 512
    private static let maximumUserPlaylistAggregatePathBytes = 8 * 1_024 * 1_024
    private static let maximumDirectoryEntries = 16_384
    private static let maximumResolverCacheDirectories = 256
    private static let trackedFiles: [String] = [
        "metadata-cache.json",
        "duration-cache.json",
        "volume-cache.json",
        "playback-weights.json",
        "playlist.json",
        "user-playlists.json"
    ]

    private struct MetadataCacheV1: Decodable {
        let version: Int
        let entries: [String: MetadataEntryV1]
    }

    private struct MetadataEntryV1: Decodable {
        let title: String
        let artist: String
        let album: String
        let fileSize: Int64
        let mtimeNs: Int64
    }

    private struct MetadataCacheV2: Decodable {
        let version: Int
        let entries: [String: MetadataEntryV2]
    }

    private struct MetadataEntryV2: Decodable {
        let title: String
        let artist: String
        let album: String
        let year: String?
        let genre: String?
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
        let lastAccessedAt: Int64
    }

    private struct DurationCacheV2: Decodable {
        let version: Int
        let entries: [String: DurationEntryV2]
    }

    private struct DurationEntryV2: Decodable {
        let durationSeconds: Double
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
    }

    private struct DurationCacheV3: Decodable {
        let version: Int
        let entries: [String: DurationEntryV3]
    }

    private struct DurationEntryV3: Decodable {
        let durationSeconds: Double
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
        let lastAccessedAt: Int64
    }

    private struct VolumeCacheV4: Decodable {
        let version: Int
        let entriesByPath: [String: VolumeEntryV4]
    }

    private struct VolumeEntryV4: Decodable {
        let integratedLoudnessLUFS: Float?
        let truePeakDbTP: Float?
        let estimatedTruePeakDbTP: Float?
        let samplePeakDbFS: Float
        let estimatedTruePeakSource: EstimatedTruePeakSource?
        let analyzedFrameCount: Int64
        let sampleRate: Double
        let algorithmIdentifier: String?
        let algorithmVersion: Int
        let fileSize: Int64?
        let modificationTimeNanoseconds: Int64?
        let fileIdentifier: UInt64?
        let updatedAt: TimeInterval
        let lastUsedAt: TimeInterval?
    }

    private struct WeightCacheFile: Decodable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    private struct StoredFileSignature: Decodable {
        let pathKey: String
        let size: Int64
        let modificationTimeNanoseconds: Int64
        let inode: UInt64?
        let fileResourceIdentifier: String?
        let volumeIdentifier: String?
    }

    private struct QueueSnapshotFile: Decodable {
        struct Track: Decodable {
            let path: String
            let signature: StoredFileSignature?
        }

        struct WeightRekey: Decodable {
            let oldPath: String
            let newPath: String
        }

        let version: Int
        let tracks: [Track]?
        let paths: [String]
        let currentIndex: Int
        let pendingWeightRekeys: [WeightRekey]?
    }

    private struct UserPlaylistFileV1: Decodable {
        let version: Int
        let playlists: [UserPlaylist]
    }

    private struct UserPlaylistFileV2: Decodable {
        let version: Int
        let storeRevision: UInt64
        let playlists: [UserPlaylist]
        let pendingCleanup: [PlaylistCleanupIntent]
    }

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
        var info = stat()
        guard lstat(fileURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            return .missing
        }
        let mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
        return .present(size: Int64(info.st_size), mtimeNs: mtimeNs)
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
                migratePathMapFile(at: fileURL, mapKey: "entries", maxSupportedVersion: 2, resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("duration-cache.json", isDirectory: false)) { fileURL, cache in
                migratePathMapFile(at: fileURL, mapKey: "entries", maxSupportedVersion: 3, resolverCache: &cache)
            },
            MigrationTask(fileURL: baseDirectory.appendingPathComponent("volume-cache.json", isDirectory: false)) { fileURL, cache in
                migrateVolumeCacheFile(at: fileURL, resolverCache: &cache)
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
        maxSupportedVersion: Int,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard let data = boundedRegularFileData(at: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawMap = root[mapKey] as? [String: Any]
        else {
            return .unchanged
        }

        // Only mutate schemas owned by a known implementation. Missing, zero,
        // negative, and future versions remain byte-for-byte untouched.
        guard let version = root["version"] as? Int,
              (1 ... maxSupportedVersion).contains(version),
              validatePathMapFile(
                data,
                fileName: url.lastPathComponent,
                version: version
              ) else { return .unchanged }

        let (migratedMap, changedEntries) = migratePathMap(rawMap, resolverCache: &resolverCache)
        guard changedEntries > 0 else { return .unchanged }

        root[mapKey] = migratedMap
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    private static func migrateVolumeCacheFile(
        at url: URL,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard let data = boundedRegularFileData(at: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["version"] as? Int == 4,
              let entries = root["entriesByPath"] as? [String: Any],
              validateVolumeCache(data) else {
            // RMS v2/v3 data is intentionally left for VolumeAnalysisStore to
            // invalidate, and future/unknown schemas remain byte-for-byte intact.
            return .unchanged
        }

        let (migrated, changedEntries) = migratePathMap(
            entries,
            resolverCache: &resolverCache
        )
        guard changedEntries > 0 else { return .unchanged }
        root["entriesByPath"] = migrated
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    private static func migratePlaybackWeightsFile(
        at url: URL,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard let data = boundedRegularFileData(at: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .unchanged
        }

        guard let version = root["version"] as? Int,
              (1 ... 3).contains(version),
              validateWeightCache(data) else { return .unchanged }

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
        guard let data = boundedRegularFileData(at: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .unchanged
        }

        guard let version = root["version"] as? Int,
              (1 ... 2).contains(version),
              validateQueueSnapshot(data) else { return .unchanged }

        var changedEntries = 0

        // Migrate tracks if present (v1 schema)
        if let tracks = root["tracks"] as? [[String: Any]] {
            var migratedTracks: [[String: Any]] = []
            migratedTracks.reserveCapacity(tracks.count)

            for var track in tracks {
                guard let rawPath = track["path"] as? String else {
                    migratedTracks.append(track)
                    continue
                }

                let migratedPath = migratePathKey(rawPath, resolverCache: &resolverCache)
                var trackChanged = false

                if migratedPath != rawPath {
                    track["path"] = migratedPath
                    changedEntries += 1
                    trackChanged = true
                }

                // Synchronize signature.pathKey if signature exists
                if var sig = track["signature"] as? [String: Any],
                   let sigPathKey = sig["pathKey"] as? String {
                    if sigPathKey != migratedPath {
                        sig["pathKey"] = migratedPath
                        track["signature"] = sig
                        if !trackChanged {
                            changedEntries += 1
                            trackChanged = true
                        }
                    }
                }

                migratedTracks.append(track)
            }

            if changedEntries > 0 {
                root["tracks"] = migratedTracks
            }
        }

        // Migrate legacy paths array (preserving duplicates and order)
        if let paths = root["paths"] as? [String] {
            var migratedPaths: [String] = []
            migratedPaths.reserveCapacity(paths.count)
            var pathChanges = 0

            for path in paths {
                let migratedPath = migratePathKey(path, resolverCache: &resolverCache)
                if migratedPath != path {
                    pathChanges += 1
                }
                migratedPaths.append(migratedPath)
            }

            if pathChanges > 0 {
                root["paths"] = migratedPaths
                changedEntries += pathChanges
            }
        }

        if var rekeys = root["pendingWeightRekeys"] as? [[String: Any]] {
            var rekeysChanged = false
            for index in rekeys.indices {
                for key in ["oldPath", "newPath"] {
                    guard let path = rekeys[index][key] as? String else { continue }
                    let migrated = migratePathKey(path, resolverCache: &resolverCache)
                    if migrated != path {
                        rekeys[index][key] = migrated
                        changedEntries += 1
                        rekeysChanged = true
                    }
                }
            }
            if rekeysChanged {
                root["pendingWeightRekeys"] = rekeys
            }
        }

        guard changedEntries > 0 else { return .unchanged }
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    private static func migrateUserPlaylistsFile(
        at url: URL,
        resolverCache: inout [String: [String]]
    ) -> MigrationFileResult {
        guard let data = boundedRegularFileData(at: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .unchanged
        }

        guard let version = root["version"] as? Int,
              (1 ... 2).contains(version),
              validateUserPlaylistFile(data) else { return .unchanged }

        guard let rawPlaylists = root["playlists"] as? [[String: Any]] else {
            return .failed(fileName: url.lastPathComponent)
        }

        var playlists = rawPlaylists
        var changedEntries = 0

        for index in playlists.indices {
            guard let tracks = playlists[index]["tracks"] as? [[String: Any]] else { continue }
            var migratedTracks: [[String: Any]] = []
            migratedTracks.reserveCapacity(tracks.count)
            var playlistChanged = false

            for var track in tracks {
                guard let rawPath = track["path"] as? String else {
                    migratedTracks.append(track)
                    continue
                }

                let migratedPath = migratePathKey(rawPath, resolverCache: &resolverCache)
                var trackChanged = false

                if migratedPath != rawPath {
                    track["path"] = migratedPath
                    changedEntries += 1
                    playlistChanged = true
                    trackChanged = true
                }

                // Synchronize signature.pathKey if signature exists
                if var sig = track["signature"] as? [String: Any],
                   let sigPathKey = sig["pathKey"] as? String {
                    if sigPathKey != migratedPath {
                        sig["pathKey"] = migratedPath
                        track["signature"] = sig
                        if !trackChanged {
                            changedEntries += 1
                            playlistChanged = true
                            trackChanged = true
                        }
                    }
                }

                // Stable track IDs make same-path records distinct user data.
                // Preserve order and multiplicity while migrating only paths.
                migratedTracks.append(track)
            }

            if playlistChanged {
                playlists[index]["tracks"] = migratedTracks
            }
        }

        if var cleanupIntents = root["pendingCleanup"] as? [[String: Any]] {
            var cleanupChanged = false
            for index in cleanupIntents.indices {
                if let paths = cleanupIntents[index]["trackPaths"] as? [String] {
                    let migrated = paths.map { migratePathKey($0, resolverCache: &resolverCache) }
                    let changes = zip(paths, migrated).filter { pair in
                        pair.0 != pair.1
                    }.count
                    if changes > 0 {
                        cleanupIntents[index]["trackPaths"] = migrated
                        changedEntries += changes
                        cleanupChanged = true
                    }
                }
                if var relocations = cleanupIntents[index]["trackRelocations"] as? [[String: Any]] {
                    var relocationChanged = false
                    for relocationIndex in relocations.indices {
                        for key in ["oldPath", "newPath"] {
                            guard let path = relocations[relocationIndex][key] as? String else { continue }
                            let migrated = migratePathKey(path, resolverCache: &resolverCache)
                            if migrated != path {
                                relocations[relocationIndex][key] = migrated
                                changedEntries += 1
                                relocationChanged = true
                            }
                        }
                    }
                    if relocationChanged {
                        cleanupIntents[index]["trackRelocations"] = relocations
                        cleanupChanged = true
                    }
                }
            }
            if cleanupChanged {
                root["pendingCleanup"] = cleanupIntents
            }
        }

        guard changedEntries > 0 else { return .unchanged }
        root["playlists"] = playlists
        return writeJSON(root, to: url, changedEntries: changedEntries)
    }

    // The path migrator runs before the owning stores load. It must therefore
    // prove that a document is one of their complete, bounded schemas before it
    // serializes anything; otherwise a shallow rewrite could turn the original
    // diagnostic evidence into a different corruption.
    private static func validatePathMapFile(
        _ data: Data,
        fileName: String,
        version: Int
    ) -> Bool {
        guard data.count <= maximumDerivedCacheFileBytes else { return false }

        switch (fileName, version) {
        case ("metadata-cache.json", 1):
            guard let file = try? JSONDecoder().decode(MetadataCacheV1.self, from: data),
                  file.version == version,
                  validateMapPaths(
                    Array(file.entries.keys),
                    maximumEntries: maximumDerivedCacheEntries,
                    maximumAggregateBytes: maximumDerivedCacheFileBytes
                  ) else { return false }
            return file.entries.values.allSatisfy { entry in
                entry.fileSize >= 0
                    && validateMetadataFields(entry.title, entry.artist, entry.album)
            }

        case ("metadata-cache.json", 2):
            guard let file = try? JSONDecoder().decode(MetadataCacheV2.self, from: data),
                  file.version == version,
                  validateMapPaths(
                    Array(file.entries.keys),
                    maximumEntries: maximumDerivedCacheEntries,
                    maximumAggregateBytes: maximumDerivedCacheFileBytes
                  ) else { return false }
            return file.entries.values.allSatisfy { entry in
                entry.fileSize >= 0
                    && validateMetadataFields(
                        entry.title,
                        entry.artist,
                        entry.album,
                        entry.year ?? "",
                        entry.genre ?? ""
                    )
            }

        case ("duration-cache.json", 2):
            guard let file = try? JSONDecoder().decode(DurationCacheV2.self, from: data),
                  file.version == version,
                  validateMapPaths(
                    Array(file.entries.keys),
                    maximumEntries: maximumDerivedCacheEntries,
                    maximumAggregateBytes: maximumDerivedCacheFileBytes
                  ) else { return false }
            return file.entries.values.allSatisfy {
                $0.durationSeconds.isFinite && $0.durationSeconds > 0 && $0.fileSize >= 0
            }

        case ("duration-cache.json", 3):
            guard let file = try? JSONDecoder().decode(DurationCacheV3.self, from: data),
                  file.version == version,
                  validateMapPaths(
                    Array(file.entries.keys),
                    maximumEntries: maximumDerivedCacheEntries,
                    maximumAggregateBytes: maximumDerivedCacheFileBytes
                  ) else { return false }
            return file.entries.values.allSatisfy {
                $0.durationSeconds.isFinite && $0.durationSeconds > 0 && $0.fileSize >= 0
            }

        default:
            return false
        }
    }

    private static func validateMetadataFields(_ fields: String...) -> Bool {
        var aggregateBytes = 0
        for field in fields {
            let byteCount = field.utf8.count
            guard byteCount <= maximumPathBytes,
                  !field.utf8.contains(0),
                  !field.contains("\u{FFFD}") else { return false }
            let (next, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
            guard !overflow, next <= 32 * 1_024 else { return false }
            aggregateBytes = next
        }
        return true
    }

    private static func validateVolumeCache(_ data: Data) -> Bool {
        guard data.count <= maximumMigratedFileBytes,
              let file = try? JSONDecoder().decode(VolumeCacheV4.self, from: data),
              file.version == 4,
              validateMapPaths(
                Array(file.entriesByPath.keys),
                maximumEntries: maximumVolumeEntries,
                maximumAggregateBytes: maximumUserPlaylistAggregatePathBytes
              ) else { return false }

        return file.entriesByPath.values.allSatisfy { entry in
            let peak = entry.estimatedTruePeakDbTP ?? entry.truePeakDbTP
            return entry.integratedLoudnessLUFS?.isFinite != false
                && peak?.isFinite == true
                && entry.samplePeakDbFS.isFinite
                && entry.analyzedFrameCount > 0
                && entry.sampleRate.isFinite
                && entry.sampleRate > 0
                && entry.algorithmIdentifier == LoudnessAlgorithm.identifier
                && entry.algorithmVersion == LoudnessAlgorithm.version
                && (entry.fileSize.map { $0 >= 0 } ?? false)
                && entry.modificationTimeNanoseconds != nil
                && entry.updatedAt.isFinite
                && entry.lastUsedAt?.isFinite != false
        }
    }

    private static func validateWeightCache(_ data: Data) -> Bool {
        guard data.count <= maximumMigratedFileBytes,
              let file = try? JSONDecoder().decode(WeightCacheFile.self, from: data),
              (1 ... 3).contains(file.version),
              file.queueLevels.count <= maximumQueueEntries,
              file.playlistLevels.count <= maximumWeightPlaylistCount else { return false }

        let allowedValues = file.version == 1
            ? -1 ... 4
            : PlaybackWeights.Level.minimumStoredRawValue ... PlaybackWeights.Level.maximumStoredRawValue
        var totalEntries = 0
        var aggregatePathBytes = 0

        func validateLevelMap(_ levels: [String: Int], maximumEntries: Int) -> Bool {
            guard levels.count <= maximumEntries else { return false }
            var canonicalPaths = Set<String>()
            canonicalPaths.reserveCapacity(levels.count)
            for (path, rawValue) in levels {
                guard isValidAbsolutePath(path),
                      allowedValues.contains(rawValue),
                      canonicalPaths.insert(PathKey.canonical(path: path)).inserted else {
                    return false
                }
                let (nextEntries, entryOverflow) = totalEntries.addingReportingOverflow(1)
                let (nextBytes, byteOverflow) = aggregatePathBytes.addingReportingOverflow(path.utf8.count)
                guard !entryOverflow,
                      !byteOverflow,
                      nextEntries <= maximumWeightEntries,
                      nextBytes <= maximumWeightAggregatePathBytes else { return false }
                totalEntries = nextEntries
                aggregatePathBytes = nextBytes
            }
            return true
        }

        guard validateLevelMap(file.queueLevels, maximumEntries: maximumQueueEntries) else {
            return false
        }
        var playlistIDs = Set<UUID>()
        playlistIDs.reserveCapacity(file.playlistLevels.count)
        for (rawID, levels) in file.playlistLevels {
            guard let id = UUID(uuidString: rawID),
                  playlistIDs.insert(id).inserted,
                  validateLevelMap(levels, maximumEntries: maximumWeightEntriesPerPlaylist) else {
                return false
            }
        }
        return true
    }

    private static func validateQueueSnapshot(_ data: Data) -> Bool {
        guard data.count <= maximumMigratedFileBytes,
              let file = try? JSONDecoder().decode(QueueSnapshotFile.self, from: data),
              (1 ... 2).contains(file.version),
              file.paths.count <= maximumQueueEntries,
              (file.tracks?.count ?? 0) <= maximumQueueEntries else { return false }

        let records: [QueueSnapshotFile.Track]
        if let tracks = file.tracks, !tracks.isEmpty || file.paths.isEmpty {
            records = tracks
        } else {
            records = file.paths.map { QueueSnapshotFile.Track(path: $0, signature: nil) }
        }
        guard records.count <= maximumQueueEntries,
              file.currentIndex >= 0,
              records.isEmpty ? file.currentIndex == 0 : file.currentIndex < records.count else {
            return false
        }

        if file.version == 2 {
            guard file.tracks != nil else { return false }
            if !file.paths.isEmpty, file.paths != file.tracks?.map(\.path) { return false }
        } else if let tracks = file.tracks,
                  !tracks.isEmpty,
                  !file.paths.isEmpty,
                  tracks.map(\.path) != file.paths {
            return false
        }

        var aggregatePathBytes = 0
        func consumePath(_ path: String, requiresAbsolute: Bool = true) -> Bool {
            guard isValidBoundedString(path),
                  !requiresAbsolute || path.hasPrefix("/") else { return false }
            let (next, overflow) = aggregatePathBytes.addingReportingOverflow(path.utf8.count)
            guard !overflow, next <= maximumQueueAggregatePathBytes else { return false }
            aggregatePathBytes = next
            return true
        }

        for track in file.tracks ?? [] {
            guard consumePath(track.path) else { return false }
            if let signature = track.signature {
                guard signature.size >= 0,
                      consumePath(signature.pathKey),
                      validateAuxiliaryIdentifier(signature.fileResourceIdentifier),
                      validateAuxiliaryIdentifier(signature.volumeIdentifier) else { return false }
                for identifier in [signature.fileResourceIdentifier, signature.volumeIdentifier].compactMap({ $0 }) {
                    let (next, overflow) = aggregatePathBytes.addingReportingOverflow(identifier.utf8.count)
                    guard !overflow, next <= maximumQueueAggregatePathBytes else { return false }
                    aggregatePathBytes = next
                }
            }
        }
        for path in file.paths where !consumePath(path) { return false }

        let rekeys = file.pendingWeightRekeys ?? []
        guard rekeys.count <= maximumQueueWeightRekeys else { return false }
        for rekey in rekeys {
            guard consumePath(rekey.oldPath), consumePath(rekey.newPath) else { return false }
        }
        return true
    }

    private static func validateUserPlaylistFile(_ data: Data) -> Bool {
        guard data.count <= maximumMigratedFileBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = root["version"] as? Int else { return false }

        switch version {
        case 1:
            guard let file = try? JSONDecoder().decode(UserPlaylistFileV1.self, from: data),
                  file.version == 1 else { return false }
            return validateUserPlaylists(file.playlists, cleanup: [], storeRevision: 0)
        case 2:
            guard let file = try? JSONDecoder().decode(UserPlaylistFileV2.self, from: data),
                  file.version == 2 else { return false }
            return validateUserPlaylists(
                file.playlists,
                cleanup: file.pendingCleanup,
                storeRevision: file.storeRevision
            )
        default:
            return false
        }
    }

    private static func validateUserPlaylists(
        _ playlists: [UserPlaylist],
        cleanup: [PlaylistCleanupIntent],
        storeRevision: UInt64
    ) -> Bool {
        guard storeRevision < UInt64.max,
              playlists.count <= maximumUserPlaylistCount,
              cleanup.count <= maximumCleanupIntentCount else { return false }

        var playlistIDs = Set<UUID>()
        var trackIDs = Set<UUID>()
        var intentIDs = Set<UUID>()
        var trackCount = 0
        var aggregatePathBytes = 0

        func consumePath(_ path: String) -> Bool {
            guard isValidAbsolutePath(path) else { return false }
            let (next, overflow) = aggregatePathBytes.addingReportingOverflow(path.utf8.count)
            guard !overflow, next <= maximumUserPlaylistAggregatePathBytes else { return false }
            aggregatePathBytes = next
            return true
        }

        func consumeIdentifier(_ identifier: String?) -> Bool {
            guard validateAuxiliaryIdentifier(identifier) else { return false }
            guard let identifier else { return true }
            let (next, overflow) = aggregatePathBytes.addingReportingOverflow(identifier.utf8.count)
            guard !overflow, next <= maximumUserPlaylistAggregatePathBytes else { return false }
            aggregatePathBytes = next
            return true
        }

        for playlist in playlists {
            let name = playlist.name
            guard playlistIDs.insert(playlist.id).inserted,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= maximumPlaylistNameBytes,
                  !name.utf8.contains(0),
                  playlist.createdAt.timeIntervalSince1970.isFinite,
                  playlist.updatedAt.timeIntervalSince1970.isFinite else { return false }
            let (nextTrackCount, overflow) = trackCount.addingReportingOverflow(playlist.tracks.count)
            guard !overflow, nextTrackCount <= maximumUserPlaylistTrackCount else { return false }
            trackCount = nextTrackCount

            for track in playlist.tracks {
                guard trackIDs.insert(track.id).inserted,
                      consumePath(track.path) else { return false }
                if let signature = track.signature {
                    guard signature.size >= 0,
                          consumePath(signature.pathKey),
                          consumeIdentifier(signature.fileResourceIdentifier),
                          consumeIdentifier(signature.volumeIdentifier) else { return false }
                }
            }
        }

        for intent in cleanup {
            guard intentIDs.insert(intent.id).inserted,
                  intent.createdAt.timeIntervalSince1970.isFinite,
                  (intent.trackIDs?.count ?? 0) <= maximumUserPlaylistTrackCount else {
                return false
            }
            if intent.kind == .deletePlaylist, playlistIDs.contains(intent.playlistID) {
                return false
            }
            if let ids = intent.trackIDs, Set(ids).count != ids.count { return false }
            for path in intent.trackPaths where !consumePath(path) { return false }

            switch intent.kind {
            case .deletePlaylist:
                guard intent.trackRelocations == nil else { return false }
            case .removeTracks:
                guard intent.trackRelocations == nil,
                      intent.trackIDs == nil || intent.trackIDs?.count == intent.trackPaths.count else {
                    return false
                }
            case .relocateTracks:
                guard let relocations = intent.trackRelocations,
                      !relocations.isEmpty,
                      relocations.count == intent.trackPaths.count,
                      intent.trackIDs == nil || intent.trackIDs?.count == relocations.count else {
                    return false
                }
                let oldPathKeys = Set(intent.trackPaths.map { PathKey.canonical(path: $0) })
                for relocation in relocations {
                    guard consumePath(relocation.oldPath),
                          consumePath(relocation.newPath),
                          oldPathKeys.contains(PathKey.canonical(path: relocation.oldPath)) else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func validateMapPaths(
        _ paths: [String],
        maximumEntries: Int,
        maximumAggregateBytes: Int
    ) -> Bool {
        guard paths.count <= maximumEntries else { return false }
        var aggregateBytes = 0
        var canonicalPaths = Set<String>()
        canonicalPaths.reserveCapacity(paths.count)
        for path in paths {
            guard isValidAbsolutePath(path),
                  canonicalPaths.insert(PathKey.canonical(path: path)).inserted else { return false }
            let (next, overflow) = aggregateBytes.addingReportingOverflow(path.utf8.count)
            guard !overflow, next <= maximumAggregateBytes else { return false }
            aggregateBytes = next
        }
        return true
    }

    private static func isValidAbsolutePath(_ path: String) -> Bool {
        isValidBoundedString(path) && path.hasPrefix("/")
    }

    private static func isValidBoundedString(_ value: String) -> Bool {
        let byteCount = value.utf8.count
        return byteCount > 0
            && byteCount <= maximumPathBytes
            && !value.utf8.contains(0)
    }

    private static func validateAuxiliaryIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumPathBytes && !value.utf8.contains(0)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL, changedEntries: Int) -> MigrationFileResult {
        guard JSONSerialization.isValidJSONObject(object),
              let output = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return .failed(fileName: url.lastPathComponent)
        }
        do {
            guard output.count <= maximumMigratedFileBytes else {
                return .failed(fileName: url.lastPathComponent)
            }
            try DerivedCacheFileIO.atomicWrite(output, to: url)
            return .changed(entries: changedEntries)
        } catch {
            return .failed(fileName: url.lastPathComponent)
        }
    }

    private static func boundedRegularFileData(at url: URL) -> Data? {
        try? DerivedCacheFileIO.readBoundedRegularFile(
            at: url,
            maximumBytes: maximumMigratedFileBytes
        )
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
            guard let fetched = boundedDirectoryEntries(atPath: directory) else { return nil }
            if resolverCache.count < maximumResolverCacheDirectories {
                resolverCache[directory] = fetched
            }
            entries = fetched
        }

        let matches = entries.filter {
            $0.compare(component, options: [.caseInsensitive, .widthInsensitive], range: nil, locale: nil) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func boundedDirectoryEntries(atPath path: String) -> [String]? {
        // Case recovery is read-only and must traverse legitimate aliases such
        // as macOS `/var` -> `/private/var`; the hard entry cap keeps even an
        // attacker-controlled destination memory-stable.
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else { return nil }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }
        defer { closedir(stream) }

        var entries: [String] = []
        entries.reserveCapacity(min(256, maximumDirectoryEntries))
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(item.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard entries.count < maximumDirectoryEntries else { return nil }
            entries.append(name)
        }
        return entries
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

extension PathKeyDiskMigrator {
    struct DebugIncrementalRunResult {
        let didRun: Bool
        let migrationResult: MigrationResult
        let savedStateData: Data?
    }

    static func debugRunIncrementalMigrationForTesting(
        baseDirectory: URL,
        previousStateData: Data?
    ) -> DebugIncrementalRunResult {
        let beforeState = computeMigrationState(baseDirectory: baseDirectory)
        let previousState = previousStateData.flatMap { try? JSONDecoder().decode(MigrationState.self, from: $0) }

        if let previousState, previousState == beforeState {
            return DebugIncrementalRunResult(
                didRun: false,
                migrationResult: MigrationResult(changedFiles: 0, changedEntries: 0, failedFiles: []),
                savedStateData: previousStateData
            )
        }

        let result = migrateLegacyLowercasedKeys(baseDirectory: baseDirectory)
        guard result.failedFiles.isEmpty else {
            return DebugIncrementalRunResult(didRun: true, migrationResult: result, savedStateData: previousStateData)
        }

        let afterState = computeMigrationState(baseDirectory: baseDirectory)
        let stateData = try? JSONEncoder().encode(afterState)
        return DebugIncrementalRunResult(didRun: true, migrationResult: result, savedStateData: stateData)
    }
}
