import CryptoKit
import Darwin
import Foundation
import SQLite3

enum LibraryBootstrapIssue: Error, Equatable, LocalizedError, Sendable {
    case sourceUnreadable(String)
    case sourceOversized(String)
    case sourceCorrupt(String)
    case sourceFuture(name: String, version: Int)
    case importVerificationFailed
    case authoritySwitchFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let name): return "旧版存储 \(name) 无法安全读取"
        case .sourceOversized(let name): return "旧版存储 \(name) 超过安全上限"
        case .sourceCorrupt(let name): return "旧版存储 \(name) 已损坏"
        case .sourceFuture(let name, let version): return "旧版存储 \(name) 的版本 \(version) 过新"
        case .importVerificationFailed: return "SQLite 迁移后的语义校验失败"
        case .authoritySwitchFailed(let code): return "SQLite 权威切换失败（errno \(code)）"
        }
    }
}

struct LibraryBootstrapResult {
    let database: LibraryDatabase?
    let migratedLegacyData: Bool
    let legacyFallbackIssue: LibraryBootstrapIssue?

    var usesSQLiteAuthority: Bool { database != nil }
}

struct LibraryBootstrapRecoveryResult: Sendable {
    let diagnosticDatabaseURL: URL
}

/// Creates the authoritative Library database before any runtime store starts.
/// A final `Library.sqlite` filename is the sole authority marker; partially
/// built `.importing` files can never compete with the legacy backend.
enum LibraryBootstrap {
    static let databaseFileName = "Library.sqlite"
    static let recoveryManifestFileName = "Library.recovery-manifest.json"
    private static let maximumLegacyBytes = 16 * 1_024 * 1_024
    private static let maximumDefaultsEnvelopeBytes = 64 * 1_024

    private struct RecoveryManifest: Codable {
        enum Phase: String, Codable {
            case archiving
            case archived
        }

        let version: Int
        let diagnosticFileName: String
        let phase: Phase
    }

    static func open(
        environment: PersistenceEnvironment,
        now: Date = Date(),
        directorySyncOverride: ((URL) -> Int32)? = nil
    ) -> LibraryBootstrapResult {
        do {
            let directory = try environment.prepareApplicationSupportDirectory()
            _ = try resumeRecoveryIfPresent(
                in: directory,
                directorySyncOverride: directorySyncOverride
            )
            let finalURL = directory.appendingPathComponent(databaseFileName, isDirectory: false)
            switch ownedRegularFileState(at: finalURL) {
            case .regular(let status):
                guard status.st_size > 0 else {
                    throw LibraryBootstrapIssue.sourceCorrupt(databaseFileName)
                }
                let database: LibraryDatabase
                do {
                    // The production configuration performs quick_check plus
                    // foreign_key_check before an existing writable authority
                    // is returned to runtime stores.
                    database = try LibraryDatabase(fileURL: finalURL)
                } catch {
                    throw LibraryBootstrapIssue.sourceCorrupt(databaseFileName)
                }
                return LibraryBootstrapResult(
                    database: database,
                    migratedLegacyData: false,
                    legacyFallbackIssue: nil
                )
            case .unsafe:
                throw LibraryBootstrapIssue.sourceUnreadable(databaseFileName)
            case .missing:
                break
            }
            // A crash or manual file removal can leave WAL/SHM files without the
            // main database. They are never valid input for a new authority.
            try removeOwnedDatabaseSidecars(at: finalURL)

            let legacy = try readLegacyImage(environment: environment, now: now)
            let importingURL = directory.appendingPathComponent(
                databaseFileName + ".importing",
                isDirectory: false
            )
            try removeOwnedImportArtifacts(at: importingURL)

            var configuration = LibraryDatabase.productionConfiguration
            configuration.journalMode = .delete
            configuration.durability = .full
            let importing = try LibraryDatabase(
                fileURL: importingURL,
                configuration: configuration
            )
            do {
                try importing.importInitialState(
                    queue: legacy.queue,
                    playlists: legacy.playlists,
                    weights: legacy.weights,
                    playbackSession: legacy.playbackSession,
                    sources: legacy.sources
                )
                guard try importing.quickCheck() else {
                    throw LibraryBootstrapIssue.importVerificationFailed
                }
                try verify(importing, matches: legacy)
                importing.close()
                try switchAuthority(
                    from: importingURL,
                    to: finalURL,
                    directorySyncOverride: directorySyncOverride
                )
                let database = try LibraryDatabase(fileURL: finalURL)
                return LibraryBootstrapResult(
                    database: database,
                    migratedLegacyData: !legacy.sources.isEmpty,
                    legacyFallbackIssue: nil
                )
            } catch {
                importing.close()
                try? removeOwnedImportArtifacts(at: importingURL)
                // A successful rename without a directory durability receipt is
                // deliberately not opened in this process. The next launch can
                // retry from whichever final name survived the crash boundary.
                throw error
            }
        } catch let issue as LibraryBootstrapIssue {
            return LibraryBootstrapResult(
                database: nil,
                migratedLegacyData: false,
                legacyFallbackIssue: issue
            )
        } catch {
            PersistenceLogger.log("初始化 Library.sqlite 失败：\(error.localizedDescription)")
            return LibraryBootstrapResult(
                database: nil,
                migratedLegacyData: false,
                legacyFallbackIssue: .importVerificationFailed
            )
        }
    }

    /// Explicitly archives an unreadable active authority and installs a new,
    /// verified empty database. This is never called during normal bootstrap:
    /// the product UI must obtain a deliberate user confirmation first.
    static func recoverCorruptAuthorityStartingEmpty(
        environment: PersistenceEnvironment,
        directorySyncOverride: ((URL) -> Int32)? = nil
    ) throws -> LibraryBootstrapRecoveryResult {
        let directory = try environment.prepareApplicationSupportDirectory()
        if let resumed = try resumeRecoveryIfPresent(
            in: directory,
            directorySyncOverride: directorySyncOverride
        ) {
            return LibraryBootstrapRecoveryResult(diagnosticDatabaseURL: resumed)
        }
        let finalURL = directory.appendingPathComponent(databaseFileName, isDirectory: false)
        guard case .regular = ownedRegularFileState(at: finalURL) else {
            throw LibraryBootstrapIssue.sourceUnreadable(databaseFileName)
        }

        let diagnosticURL = directory.appendingPathComponent(
            "Library.corrupted.\(UUID().uuidString).sqlite",
            isDirectory: false
        )
        let manifest = RecoveryManifest(
            version: 1,
            diagnosticFileName: diagnosticURL.lastPathComponent,
            phase: .archiving
        )
        try writeRecoveryManifest(
            manifest,
            in: directory,
            replacing: false,
            directorySyncOverride: directorySyncOverride
        )
        let completedDiagnostic = try continueRecovery(
            manifest,
            in: directory,
            directorySyncOverride: directorySyncOverride
        )
        return LibraryBootstrapRecoveryResult(diagnosticDatabaseURL: completedDiagnostic)
    }

    private static func resumeRecoveryIfPresent(
        in directory: URL,
        directorySyncOverride: ((URL) -> Int32)?
    ) throws -> URL? {
        let manifestURL = directory.appendingPathComponent(
            recoveryManifestFileName,
            isDirectory: false
        )
        switch ownedRegularFileState(at: manifestURL) {
        case .missing:
            return nil
        case .unsafe:
            throw LibraryBootstrapIssue.sourceUnreadable(recoveryManifestFileName)
        case .regular(let status):
            guard status.st_size > 0, status.st_size <= maximumDefaultsEnvelopeBytes,
                  let source = try readSourceIfPresent(
                      manifestURL,
                      name: recoveryManifestFileName
                  ),
                  let manifest = try? JSONDecoder().decode(
                      RecoveryManifest.self,
                      from: source.data
                  ),
                  isValidRecoveryManifest(manifest) else {
                throw LibraryBootstrapIssue.sourceCorrupt(recoveryManifestFileName)
            }
            return try continueRecovery(
                manifest,
                in: directory,
                directorySyncOverride: directorySyncOverride
            )
        }
    }

    private static func continueRecovery(
        _ initialManifest: RecoveryManifest,
        in directory: URL,
        directorySyncOverride: ((URL) -> Int32)?
    ) throws -> URL {
        guard isValidRecoveryManifest(initialManifest) else {
            throw LibraryBootstrapIssue.sourceCorrupt(recoveryManifestFileName)
        }
        var manifest = initialManifest
        let finalURL = directory.appendingPathComponent(databaseFileName, isDirectory: false)
        let diagnosticURL = directory.appendingPathComponent(
            manifest.diagnosticFileName,
            isDirectory: false
        )
        let recoveringURL = directory.appendingPathComponent(
            databaseFileName + ".recovering",
            isDirectory: false
        )

        if manifest.phase == .archiving {
            let sourceFamily = sqliteFamily(at: finalURL)
            let diagnosticFamily = sqliteFamily(at: diagnosticURL)
            for (index, pair) in zip(sourceFamily, diagnosticFamily).enumerated() {
                switch (ownedRegularFileState(at: pair.0), ownedRegularFileState(at: pair.1)) {
                case (.regular, .missing):
                    guard renamex_np(
                        pair.0.path,
                        pair.1.path,
                        UInt32(RENAME_EXCL)
                    ) == 0 else {
                        throw LibraryBootstrapIssue.authoritySwitchFailed(errno)
                    }
                case (.missing, .regular):
                    break
                case (.missing, .missing):
                    guard index != 0 else {
                        throw LibraryBootstrapIssue.sourceUnreadable(databaseFileName)
                    }
                case (.unsafe, _), (_, .unsafe), (.regular, .regular):
                    throw LibraryBootstrapIssue.sourceUnreadable(recoveryManifestFileName)
                }
            }
            guard case .regular = ownedRegularFileState(at: diagnosticURL) else {
                throw LibraryBootstrapIssue.sourceUnreadable(diagnosticURL.lastPathComponent)
            }
            try requireDirectorySync(directory, override: directorySyncOverride)
            manifest = RecoveryManifest(
                version: 1,
                diagnosticFileName: manifest.diagnosticFileName,
                phase: .archived
            )
            try writeRecoveryManifest(
                manifest,
                in: directory,
                replacing: true,
                directorySyncOverride: directorySyncOverride
            )
        }

        guard case .regular = ownedRegularFileState(at: diagnosticURL) else {
            throw LibraryBootstrapIssue.sourceUnreadable(diagnosticURL.lastPathComponent)
        }

        switch ownedRegularFileState(at: finalURL) {
        case .regular(let status) where status.st_size > 0:
            if let existing = try? LibraryDatabase(fileURL: finalURL) {
                let isHealthy = existing.accessMode == .writable
                    && ((try? existing.quickCheck()) == true)
                existing.close()
                if isHealthy {
                    try removeRecoveryManifest(
                        in: directory,
                        directorySyncOverride: directorySyncOverride
                    )
                    return diagnosticURL
                }
            }
            try removeOwnedFamily(
                at: finalURL,
                directorySyncOverride: directorySyncOverride
            )
        case .regular:
            try removeOwnedFamily(
                at: finalURL,
                directorySyncOverride: directorySyncOverride
            )
        case .unsafe:
            throw LibraryBootstrapIssue.sourceUnreadable(databaseFileName)
        case .missing:
            break
        }

        try removeOwnedImportArtifacts(at: recoveringURL)
        try buildVerifiedEmptyDatabase(at: recoveringURL)
        try switchAuthority(
            from: recoveringURL,
            to: finalURL,
            directorySyncOverride: directorySyncOverride
        )
        let verified = try LibraryDatabase(fileURL: finalURL)
        let isHealthy = verified.accessMode == .writable
            && ((try? verified.quickCheck()) == true)
        verified.close()
        guard isHealthy else {
            throw LibraryBootstrapIssue.importVerificationFailed
        }
        try removeRecoveryManifest(
            in: directory,
            directorySyncOverride: directorySyncOverride
        )
        return diagnosticURL
    }

    private static func buildVerifiedEmptyDatabase(at url: URL) throws {
        var configuration = LibraryDatabase.productionConfiguration
        configuration.journalMode = .delete
        configuration.durability = .full
        let recovering = try LibraryDatabase(fileURL: url, configuration: configuration)
        do {
            try recovering.importInitialState(
                queue: LibraryQueueSnapshot(
                    revision: 0,
                    entries: [],
                    currentEntryID: nil,
                    pendingRekeys: []
                ),
                playlists: LibraryPlaylistsSnapshot(
                    revision: 0,
                    playlists: [],
                    pendingCleanup: []
                ),
                weights: LibraryWeightsSnapshot(
                    revision: 0,
                    queueLevels: [:],
                    playlistLevels: [:]
                ),
                playbackSession: nil,
                sources: []
            )
            guard try recovering.quickCheck() else {
                throw LibraryBootstrapIssue.importVerificationFailed
            }
            recovering.close()
        } catch {
            recovering.close()
            throw error
        }
    }

    private static func isValidRecoveryManifest(_ manifest: RecoveryManifest) -> Bool {
        manifest.version == 1
            && manifest.diagnosticFileName.utf8.count <= 255
            && !manifest.diagnosticFileName.contains("/")
            && manifest.diagnosticFileName.hasPrefix("Library.corrupted.")
            && manifest.diagnosticFileName.hasSuffix(".sqlite")
    }

    private static func writeRecoveryManifest(
        _ manifest: RecoveryManifest,
        in directory: URL,
        replacing: Bool,
        directorySyncOverride: ((URL) -> Int32)?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumDefaultsEnvelopeBytes else {
            throw LibraryBootstrapIssue.sourceOversized(recoveryManifestFileName)
        }
        let destination = directory.appendingPathComponent(
            recoveryManifestFileName,
            isDirectory: false
        )
        let temporary = directory.appendingPathComponent(
            ".\(recoveryManifestFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try writeExclusiveFile(data, to: temporary)
        var temporaryExists = true
        defer {
            if temporaryExists { _ = unlink(temporary.path) }
        }

        if replacing {
            guard case .regular = ownedRegularFileState(at: destination),
                  Darwin.rename(temporary.path, destination.path) == 0 else {
                throw LibraryBootstrapIssue.authoritySwitchFailed(errno)
            }
        } else {
            guard renamex_np(
                temporary.path,
                destination.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw LibraryBootstrapIssue.authoritySwitchFailed(errno)
            }
        }
        temporaryExists = false
        try requireDirectorySync(directory, override: directorySyncOverride)
    }

    private static func removeRecoveryManifest(
        in directory: URL,
        directorySyncOverride: ((URL) -> Int32)?
    ) throws {
        let url = directory.appendingPathComponent(
            recoveryManifestFileName,
            isDirectory: false
        )
        guard case .regular = ownedRegularFileState(at: url),
              unlink(url.path) == 0 else {
            throw LibraryBootstrapIssue.sourceUnreadable(recoveryManifestFileName)
        }
        try requireDirectorySync(directory, override: directorySyncOverride)
    }

    private static func writeExclusiveFile(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw LibraryBootstrapIssue.authoritySwitchFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        guard writeAll(data, descriptor: descriptor), fsync(descriptor) == 0 else {
            throw LibraryBootstrapIssue.authoritySwitchFailed(errno == 0 ? EIO : errno)
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func removeOwnedFamily(
        at mainURL: URL,
        directorySyncOverride: ((URL) -> Int32)?
    ) throws {
        var removedAny = false
        for member in sqliteFamily(at: mainURL) {
            switch ownedRegularFileState(at: member) {
            case .missing:
                continue
            case .unsafe:
                throw LibraryBootstrapIssue.sourceUnreadable(member.lastPathComponent)
            case .regular:
                guard unlink(member.path) == 0 else {
                    throw LibraryBootstrapIssue.sourceUnreadable(member.lastPathComponent)
                }
                removedAny = true
            }
        }
        if removedAny {
            try requireDirectorySync(
                mainURL.deletingLastPathComponent(),
                override: directorySyncOverride
            )
        }
    }

    private static func requireDirectorySync(
        _ directory: URL,
        override: ((URL) -> Int32)?
    ) throws {
        let code = override?(directory) ?? synchronizeDirectory(directory)
        guard code == 0 else {
            throw LibraryBootstrapIssue.authoritySwitchFailed(code)
        }
    }

    // MARK: - Legacy decoding

    private struct LegacyImage {
        let queue: LibraryQueueSnapshot
        let playlists: LibraryPlaylistsSnapshot
        let weights: LibraryWeightsSnapshot
        let playbackSession: LibraryPlaybackSession?
        let sources: [LibraryMigrationSource]
    }

    private struct LegacySessionDecodeResult {
        let session: LibraryPlaybackSession?
        let usedScatteredScope: Bool
    }

    private struct LegacyQueueDecodeResult {
        let queue: LibraryQueueSnapshot
        let defaultsReceiptData: Data?
    }

    private struct LegacyScopeResolution {
        let playlistID: UUID?
        let usedScatteredDefaults: Bool
    }

    private struct SourceFile {
        let name: String
        let data: Data
        let version: Int?
        let modificationTimeNanoseconds: Int64
    }

    private struct DefaultsQueueReceiptPayload: Encodable {
        let version = 1
        let paths: [String]
        let currentIndex: Int
    }

    private struct LegacyQueueFile: Decodable {
        struct Track: Decodable {
            let path: String
            let signature: FileSignature?

            init(path: String, signature: FileSignature?) {
                self.path = path
                self.signature = signature
            }
        }
        struct Rekey: Decodable {
            let oldPath: String
            let newPath: String

            init(oldPath: String, newPath: String) {
                self.oldPath = oldPath
                self.newPath = newPath
            }
        }
        let version: Int?
        let tracks: [Track]?
        let paths: [String]
        let currentIndex: Int
        let pendingWeightRekeys: [Rekey]?

        private enum CodingKeys: String, CodingKey {
            case version, tracks, paths, currentIndex, pendingWeightRekeys
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
            tracks = try container.decodeIfPresent([Track].self, forKey: .tracks)
            paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
            currentIndex = try container.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
            pendingWeightRekeys = try container.decodeIfPresent(
                [Rekey].self,
                forKey: .pendingWeightRekeys
            )
        }

        init(
            version: Int?,
            tracks: [Track]?,
            paths: [String],
            currentIndex: Int,
            pendingWeightRekeys: [Rekey]?
        ) {
            self.version = version
            self.tracks = tracks
            self.paths = paths
            self.currentIndex = currentIndex
            self.pendingWeightRekeys = pendingWeightRekeys
        }
    }

    private struct LegacyPlaylistsFile: Decodable {
        struct Playlist: Decodable {
            struct Track: Decodable {
                let id: UUID?
                let path: String
                let signature: FileSignature?
            }
            let id: UUID
            let name: String
            let tracks: [Track]
            let createdAt: Date
            let updatedAt: Date
        }
        let version: Int
        let storeRevision: UInt64?
        let playlists: [Playlist]
        let pendingCleanup: [PlaylistCleanupIntent]?
    }

    private struct LegacyWeightsFile: Decodable {
        let version: Int
        let queueLevels: [String: Int]
        let playlistLevels: [String: [String: Int]]
    }

    private struct LegacyPlaybackEnvelope: Decodable {
        struct State: Decodable {
            let filePath: String
            let lastPlayedTime: TimeInterval
        }
        let version: Int
        let state: State
    }

    private struct LegacyPreferencesEnvelope: Decodable {
        struct Preferences: Decodable {
            struct Scope: Decodable {
                enum Kind: String, Decodable {
                    case queue
                    case playlist
                }

                let kind: Kind
                let playlistID: UUID?

                private enum CodingKeys: String, CodingKey {
                    case kind
                    case playlistID
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
                                DecodingError.Context(
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

    /// v2 deliberately omits playback scope, but the envelope still has to be
    /// structurally valid before it can suppress older scattered scope keys.
    private struct CurrentPreferencesEnvelope: Decodable {
        let version: Int
        let preferences: AppPreferencesStore.Preferences
    }

    private static func readLegacyImage(
        environment: PersistenceEnvironment,
        now: Date
    ) throws -> LegacyImage {
        let root = environment.applicationSupportURL
        var receipts: [LibraryMigrationSource] = []

        let queueSource = try readSourceIfPresent(
            root.appendingPathComponent("playlist.json"),
            name: "queue-v2"
        )
        let queueResult = try decodeQueue(
            queueSource,
            defaults: environment.userDefaults,
            now: now
        )
        let queue = queueResult.queue
        if let queueSource {
            receipts.append(receipt(queueSource, version: queueSource.version, now: now))
        } else if let data = queueResult.defaultsReceiptData {
            receipts.append(
                defaultsReceipt(
                    name: "queue-defaults",
                    data: data,
                    version: 1,
                    now: now
                )
            )
        }

        let playlistsSource = try readSourceIfPresent(
            root.appendingPathComponent("user-playlists.json"),
            name: "playlists-v2"
        )
        let playlists = try decodePlaylists(playlistsSource)
        if let playlistsSource {
            receipts.append(receipt(playlistsSource, version: playlistsSource.version, now: now))
        }

        let weightsSource = try readSourceIfPresent(
            root.appendingPathComponent("playback-weights.json"),
            name: "weights-v3"
        )
        let weights = try decodeWeights(weightsSource)
        if let weightsSource {
            receipts.append(receipt(weightsSource, version: weightsSource.version, now: now))
        }

        let playbackData = environment.userDefaults.data(forKey: PlaybackStateStore.envelopeKey)
        let preferencesData = environment.userDefaults.data(forKey: AppPreferencesStore.envelopeKey)
        let sessionResult = try decodeSession(
            playbackData: playbackData,
            preferencesData: preferencesData,
            legacyDefaults: environment.userDefaults,
            queue: queue,
            playlists: playlists
        )
        if let playbackData {
            receipts.append(
                defaultsReceipt(
                    name: "playback-state-v1",
                    data: playbackData,
                    version: (try? JSONDecoder().decode(
                        VersionProbe.self,
                        from: playbackData
                    ))?.version,
                    now: now
                )
            )
        }
        if let preferencesData {
            receipts.append(
                defaultsReceipt(
                    name: "app-preferences",
                    data: preferencesData,
                    version: (try? JSONDecoder().decode(
                        VersionProbe.self,
                        from: preferencesData
                    ))?.version,
                    now: now
                )
            )
        }
        if sessionResult.usedScatteredScope,
           let scatteredScopeData = scatteredScopeReceiptData(environment.userDefaults) {
            receipts.append(
                defaultsReceipt(
                    name: "playback-scope-defaults",
                    data: scatteredScopeData,
                    version: nil,
                    now: now
                )
            )
        }
        return LegacyImage(
            queue: queue,
            playlists: playlists,
            weights: weights,
            playbackSession: sessionResult.session,
            sources: receipts
        )
    }

    private static func readSourceIfPresent(_ url: URL, name: String) throws -> SourceFile? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LibraryBootstrapIssue.sourceUnreadable(name)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw LibraryBootstrapIssue.sourceUnreadable(name)
        }
        guard before.st_size <= maximumLegacyBytes else {
            throw LibraryBootstrapIssue.sourceOversized(name)
        }
        guard let byteCount = Int(exactly: before.st_size),
              let data = readExactly(descriptor: descriptor, byteCount: byteCount) else {
            throw LibraryBootstrapIssue.sourceUnreadable(name)
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              stableSourceIdentity(before, after) else {
            throw LibraryBootstrapIssue.sourceUnreadable(name)
        }
        let version = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.version
        return SourceFile(
            name: name,
            data: data,
            version: version,
            modificationTimeNanoseconds: modificationTimeNanoseconds(after)
        )
    }

    private struct VersionProbe: Decodable { let version: Int? }

    private static func decodeQueue(
        _ source: SourceFile?,
        defaults: UserDefaults,
        now: Date
    ) throws -> LegacyQueueDecodeResult {
        let decoded: LegacyQueueFile
        let seedData: Data
        let sourceDate: Date
        let defaultsReceiptData: Data?
        if let source {
            guard let queue = try? JSONDecoder().decode(LegacyQueueFile.self, from: source.data) else {
                throw LibraryBootstrapIssue.sourceCorrupt(source.name)
            }
            if let version = queue.version, version > 2 {
                throw LibraryBootstrapIssue.sourceFuture(name: source.name, version: version)
            }
            guard queue.version == nil || queue.version == 1 || queue.version == 2 else {
                throw LibraryBootstrapIssue.sourceCorrupt(source.name)
            }
            decoded = queue
            seedData = source.data
            defaultsReceiptData = nil
            sourceDate = Date(
                timeIntervalSince1970: Double(source.modificationTimeNanoseconds) / 1_000_000_000
            )
        } else if let paths = defaults.stringArray(forKey: "savedPlaylistPaths"), !paths.isEmpty {
            let index = defaults.integer(forKey: "savedPlaylistIndex")
            decoded = LegacyQueueFile(
                version: nil,
                tracks: nil,
                paths: paths,
                currentIndex: index,
                pendingWeightRekeys: nil
            )
            seedData = (try? JSONEncoder().encode(paths)) ?? Data()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let encodedReceipt = try? encoder.encode(
                DefaultsQueueReceiptPayload(paths: paths, currentIndex: index)
            ) else {
                throw LibraryBootstrapIssue.sourceCorrupt("queue-defaults")
            }
            defaultsReceiptData = encodedReceipt
            sourceDate = now
        } else {
            return LegacyQueueDecodeResult(
                queue: LibraryQueueSnapshot(
                    revision: 0,
                    entries: [],
                    currentEntryID: nil,
                    pendingRekeys: []
                ),
                defaultsReceiptData: nil
            )
        }

        let records: [LegacyQueueFile.Track]
        if let tracks = decoded.tracks, !tracks.isEmpty || decoded.paths.isEmpty {
            records = tracks
        } else {
            records = decoded.paths.map { .init(path: $0, signature: nil) }
        }
        guard records.count <= 100_000,
              decoded.currentIndex >= 0,
              (records.isEmpty ? decoded.currentIndex == 0 : decoded.currentIndex < records.count) else {
            throw LibraryBootstrapIssue.sourceCorrupt(source?.name ?? "legacy-defaults-queue")
        }
        let seed = SHA256.hash(data: seedData).map { String(format: "%02x", $0) }.joined()
        let entries = records.enumerated().map { index, record in
            LibraryQueueEntry(
                id: deterministicUUID("queue|\(seed)|\(index)|\(record.path)"),
                sortKey: Int64(index) * 1_024,
                path: record.path,
                signature: record.signature,
                locationID: nil,
                relativePath: nil
            )
        }
        let rekeys = (decoded.pendingWeightRekeys ?? []).enumerated().map { index, rekey in
            LibraryQueueRekeyIntent(
                id: deterministicUUID(
                    "queue-rekey|\(seed)|\(index)|\(rekey.oldPath)|\(rekey.newPath)"
                ),
                oldPath: rekey.oldPath,
                newPath: rekey.newPath,
                createdAt: sourceDate
            )
        }
        return LegacyQueueDecodeResult(
            queue: LibraryQueueSnapshot(
                revision: 1,
                entries: entries,
                currentEntryID: entries.indices.contains(decoded.currentIndex)
                    ? entries[decoded.currentIndex].id
                    : nil,
                pendingRekeys: rekeys
            ),
            defaultsReceiptData: defaultsReceiptData
        )
    }

    private static func decodePlaylists(
        _ source: SourceFile?
    ) throws -> LibraryPlaylistsSnapshot {
        guard let source else {
            return LibraryPlaylistsSnapshot(revision: 0, playlists: [], pendingCleanup: [])
        }
        guard let decoded = try? JSONDecoder().decode(LegacyPlaylistsFile.self, from: source.data) else {
            throw LibraryBootstrapIssue.sourceCorrupt(source.name)
        }
        if decoded.version > 2 {
            throw LibraryBootstrapIssue.sourceFuture(name: source.name, version: decoded.version)
        }
        guard decoded.version == 1 || decoded.version == 2 else {
            throw LibraryBootstrapIssue.sourceCorrupt(source.name)
        }
        let seed = SHA256.hash(data: source.data).map { String(format: "%02x", $0) }.joined()
        let playlists = decoded.playlists.enumerated().map { playlistIndex, raw in
            let tracks = raw.tracks.enumerated().map { trackIndex, track in
                UserPlaylist.Track(
                    id: track.id ?? deterministicUUID(
                        "playlist-track|\(seed)|\(raw.id.uuidString)|\(playlistIndex)|\(trackIndex)|\(track.path)"
                    ),
                    path: track.path,
                    signature: track.signature
                )
            }
            return UserPlaylist(
                id: raw.id,
                name: raw.name,
                tracks: tracks,
                createdAt: raw.createdAt,
                updatedAt: raw.updatedAt
            )
        }
        return LibraryPlaylistsSnapshot(
            revision: decoded.storeRevision ?? (playlists.isEmpty ? 0 : 1),
            playlists: playlists,
            pendingCleanup: decoded.pendingCleanup ?? []
        )
    }

    private static func decodeWeights(_ source: SourceFile?) throws -> LibraryWeightsSnapshot {
        guard let source else {
            return LibraryWeightsSnapshot(revision: 0, queueLevels: [:], playlistLevels: [:])
        }
        guard let decoded = try? JSONDecoder().decode(LegacyWeightsFile.self, from: source.data) else {
            throw LibraryBootstrapIssue.sourceCorrupt(source.name)
        }
        if decoded.version > 3 {
            throw LibraryBootstrapIssue.sourceFuture(name: source.name, version: decoded.version)
        }
        guard (1...3).contains(decoded.version) else {
            throw LibraryBootstrapIssue.sourceCorrupt(source.name)
        }
        let transform: (Int) -> Int = decoded.version == 1
            ? { max(-1, min(4, $0)) + 1 }
            : { max(0, min(5, $0)) }
        func normalize(_ raw: [String: Int]) -> [String: Int] {
            var output: [String: Int] = [:]
            for key in raw.keys.sorted() {
                guard let rawValue = raw[key] else { continue }
                let value = transform(rawValue)
                if value != PlaybackWeights.Level.defaultLevel.rawValue {
                    output[PathKey.canonical(path: key)] = value
                }
            }
            return output
        }
        var playlists: [UUID: [String: Int]] = [:]
        for (rawID, levels) in decoded.playlistLevels {
            guard let id = UUID(uuidString: rawID) else { continue }
            let normalized = normalize(levels)
            if !normalized.isEmpty { playlists[id] = normalized }
        }
        return LibraryWeightsSnapshot(
            revision: 1,
            queueLevels: normalize(decoded.queueLevels),
            playlistLevels: playlists
        )
    }

    private static func decodeSession(
        playbackData: Data?,
        preferencesData: Data?,
        legacyDefaults: UserDefaults,
        queue: LibraryQueueSnapshot,
        playlists: LibraryPlaylistsSnapshot
    ) throws -> LegacySessionDecodeResult {
        let scopeResolution = try legacyPlaybackScope(
            preferencesData: preferencesData,
            defaults: legacyDefaults
        )
        guard let playbackData else {
            return LegacySessionDecodeResult(
                session: nil,
                usedScatteredScope: scopeResolution.usedScatteredDefaults
            )
        }
        guard playbackData.count <= maximumDefaultsEnvelopeBytes else {
            throw LibraryBootstrapIssue.sourceOversized("playback-state-v1")
        }
        guard
              let playback = try? JSONDecoder().decode(
                LegacyPlaybackEnvelope.self,
                from: playbackData
              ) else {
            throw LibraryBootstrapIssue.sourceCorrupt("playback-state-v1")
        }
        if playback.version > 1 {
            throw LibraryBootstrapIssue.sourceFuture(
                name: "playback-state-v1",
                version: playback.version
            )
        }
        guard playback.version == 1 else {
            throw LibraryBootstrapIssue.sourceCorrupt("playback-state-v1")
        }
        let canonical = PathKey.canonical(path: playback.state.filePath)
        let queueEntry = queue.entries.first { PathKey.canonical(path: $0.path) == canonical }

        var scope: LibraryPlaybackSession.Scope = .queue
        var playlistID: UUID?
        var scopeTrackID: UUID?
        if let selectedID = scopeResolution.playlistID,
           let playlist = playlists.playlists.first(where: { $0.id == selectedID }),
           let track = playlist.tracks.first(where: {
               PathKey.canonical(path: $0.path) == canonical
           }) {
            scope = .playlist
            playlistID = playlist.id
            scopeTrackID = track.id
        }
        let seconds = playback.state.lastPlayedTime.isFinite
            ? max(0, playback.state.lastPlayedTime)
            : 0
        let roundedMilliseconds = (seconds * 1_000).rounded()
        let positionMilliseconds: Int64
        if !roundedMilliseconds.isFinite
            || roundedMilliseconds >= Double(Int64.max) {
            positionMilliseconds = Int64.max
        } else {
            positionMilliseconds = Int64(roundedMilliseconds)
        }
        return LegacySessionDecodeResult(
            session: LibraryPlaybackSession(
                revision: 1,
                scope: scope,
                playlistID: playlistID,
                scopeTrackID: scopeTrackID,
                queueEntryID: queueEntry?.id,
                fallbackPath: playback.state.filePath,
                positionMilliseconds: positionMilliseconds
            ),
            usedScatteredScope: scopeResolution.usedScatteredDefaults
        )
    }

    /// v1 coherent preferences win over the older scattered keys. A current or
    /// future coherent envelope intentionally suppresses those stale keys; only
    /// an absent/corrupt envelope falls back to the pre-envelope representation.
    private static func legacyPlaybackScope(
        preferencesData: Data?,
        defaults: UserDefaults
    ) throws -> LegacyScopeResolution {
        if let preferencesData {
            guard preferencesData.count <= maximumDefaultsEnvelopeBytes else {
                throw LibraryBootstrapIssue.sourceOversized("app-preferences")
            }
            if let probe = try? JSONDecoder().decode(VersionProbe.self, from: preferencesData),
               let version = probe.version {
                if version > AppPreferencesStore.formatVersion {
                    throw LibraryBootstrapIssue.sourceFuture(
                        name: "app-preferences",
                        version: version
                    )
                }
                if version == AppPreferencesStore.formatVersion,
                   let envelope = try? JSONDecoder().decode(
                       CurrentPreferencesEnvelope.self,
                       from: preferencesData
                   ),
                   envelope.version == AppPreferencesStore.formatVersion {
                    return LegacyScopeResolution(
                        playlistID: nil,
                        usedScatteredDefaults: false
                    )
                }
                if version == 1,
                   let preferences = try? JSONDecoder().decode(
                        LegacyPreferencesEnvelope.self,
                        from: preferencesData
                   ) {
                    return LegacyScopeResolution(
                        playlistID: preferences.preferences.playbackScope.playlistID,
                        usedScatteredDefaults: false
                    )
                }
            }
            PersistenceLogger.log(
                "旧版播放器偏好 envelope 损坏，播放范围迁移回退到散落键"
            )
        }

        let rawKind = defaults.string(forKey: AppPreferencesStore.LegacyKey.scopeKind)
        let rawID = defaults.string(forKey: AppPreferencesStore.LegacyKey.scopePlaylistID)
        guard rawKind != nil || rawID != nil else {
            return LegacyScopeResolution(
                playlistID: nil,
                usedScatteredDefaults: false
            )
        }
        guard rawKind == "playlist", let rawID, let playlistID = UUID(uuidString: rawID) else {
            if rawKind != "queue" {
                PersistenceLogger.log("散落播放范围偏好无效，迁移为安全队列范围")
            }
            return LegacyScopeResolution(
                playlistID: nil,
                usedScatteredDefaults: true
            )
        }
        return LegacyScopeResolution(
            playlistID: playlistID,
            usedScatteredDefaults: true
        )
    }

    private static func scatteredScopeReceiptData(_ defaults: UserDefaults) -> Data? {
        let kind = defaults.string(forKey: AppPreferencesStore.LegacyKey.scopeKind)
        let playlistID = defaults.string(forKey: AppPreferencesStore.LegacyKey.scopePlaylistID)
        guard kind != nil || playlistID != nil else { return nil }
        return Data("kind=\(kind ?? "");playlistID=\(playlistID ?? "")".utf8)
    }

    private static func defaultsReceipt(
        name: String,
        data: Data,
        version: Int?,
        now: Date
    ) -> LibraryMigrationSource {
        LibraryMigrationSource(
            name: name,
            sourceVersion: version,
            byteCount: data.count,
            modificationTimeNanoseconds: 0,
            digest: SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined(),
            importedAt: now
        )
    }

    // MARK: - Verification and atomic switch

    private static func verify(
        _ database: LibraryDatabase,
        matches image: LegacyImage
    ) throws {
        let queue = try database.loadQueue()
        let playlists = try database.loadPlaylists()
        let weights = try database.loadWeights()
        let session = try database.loadPlaybackSession()
        guard queue == image.queue,
              playlists == image.playlists,
              weights == image.weights,
              session == image.playbackSession else {
            throw LibraryBootstrapIssue.importVerificationFailed
        }
        let storedReceipts = try readMigrationReceipts(at: database.fileURL)
        guard storedReceipts.count == image.sources.count else {
            throw LibraryBootstrapIssue.importVerificationFailed
        }
        let storedByName = Dictionary(uniqueKeysWithValues: storedReceipts.map { ($0.name, $0) })
        guard storedByName.count == storedReceipts.count,
              image.sources.allSatisfy({ source in
                  guard let stored = storedByName[source.name] else { return false }
                  return migrationReceiptsMatch(stored, source)
              }) else {
            throw LibraryBootstrapIssue.importVerificationFailed
        }
    }

    /// SQLite stores the timestamp as a binary64 Unix time, while Foundation
    /// stores Date relative to 2001.  The two conversions can differ by a few
    /// ULPs around modern dates even though they denote the same import event.
    /// All authority-bearing receipt fields remain exact; only this diagnostic
    /// timestamp is compared with a sub-millisecond representation tolerance.
    private static func migrationReceiptsMatch(
        _ lhs: LibraryMigrationSource,
        _ rhs: LibraryMigrationSource
    ) -> Bool {
        lhs.name == rhs.name
            && lhs.sourceVersion == rhs.sourceVersion
            && lhs.byteCount == rhs.byteCount
            && lhs.modificationTimeNanoseconds == rhs.modificationTimeNanoseconds
            && lhs.digest == rhs.digest
            && abs(
                lhs.importedAt.timeIntervalSince1970
                    - rhs.importedAt.timeIntervalSince1970
            ) <= 0.001
    }

    private static func switchAuthority(
        from source: URL,
        to destination: URL,
        directorySyncOverride: ((URL) -> Int32)? = nil
    ) throws {
        let result = renamex_np(
            source.path,
            destination.path,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else {
            throw LibraryBootstrapIssue.authoritySwitchFailed(errno)
        }
        let parent = destination.deletingLastPathComponent()
        let syncCode = directorySyncOverride?(parent) ?? synchronizeDirectory(parent)
        guard syncCode == 0 else {
            throw LibraryBootstrapIssue.authoritySwitchFailed(syncCode)
        }
    }

    private static func removeOwnedImportArtifacts(at url: URL) throws {
        for candidate in sqliteFamily(at: url) {
            switch ownedRegularFileState(at: candidate) {
            case .missing:
                continue
            case .unsafe:
                throw LibraryBootstrapIssue.sourceUnreadable(candidate.lastPathComponent)
            case .regular:
                guard unlink(candidate.path) == 0 else {
                    throw LibraryBootstrapIssue.sourceUnreadable(candidate.lastPathComponent)
                }
            }
        }
    }

    private static func sidecarURL(_ databaseURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false)
    }

    private static func removeOwnedDatabaseSidecars(at url: URL) throws {
        for candidate in sqliteFamily(at: url).dropFirst() {
            switch ownedRegularFileState(at: candidate) {
            case .missing:
                continue
            case .unsafe:
                throw LibraryBootstrapIssue.sourceUnreadable(candidate.lastPathComponent)
            case .regular:
                guard unlink(candidate.path) == 0 else {
                    throw LibraryBootstrapIssue.sourceUnreadable(candidate.lastPathComponent)
                }
            }
        }
    }

    private enum OwnedRegularFileState {
        case missing
        case regular(stat)
        case unsafe
    }

    private static let sqliteFamilySuffixes = ["", "-wal", "-shm", "-journal"]

    private static func sqliteFamily(at mainURL: URL) -> [URL] {
        sqliteFamilySuffixes.map {
            URL(fileURLWithPath: mainURL.path + $0, isDirectory: false)
        }
    }

    private static func ownedRegularFileState(at url: URL) -> OwnedRegularFileState {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return .unsafe
        }
        return .regular(status)
    }

    private static func synchronizeDirectory(_ directory: URL) -> Int32 {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return errno }
        defer { Darwin.close(descriptor) }
        return fsync(descriptor) == 0 ? 0 : errno
    }

    private static func receipt(
        _ source: SourceFile,
        version: Int?,
        now: Date
    ) -> LibraryMigrationSource {
        LibraryMigrationSource(
            name: source.name,
            sourceVersion: version,
            byteCount: source.data.count,
            modificationTimeNanoseconds: source.modificationTimeNanoseconds,
            digest: SHA256.hash(data: source.data).map { String(format: "%02x", $0) }.joined(),
            importedAt: now
        )
    }

    private static func readExactly(descriptor: Int32, byteCount: Int) -> Data? {
        var data = Data(count: byteCount)
        let completed = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return byteCount == 0 }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return completed ? data : nil
    }

    private static func stableSourceIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func readMigrationReceipts(at databaseURL: URL) throws -> [LibraryMigrationSource] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw LibraryBootstrapIssue.importVerificationFailed
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        let sql = """
        SELECT source_name, source_version, byte_count, mtime_ns, sha256, imported_at
        FROM migration_sources ORDER BY source_name
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LibraryBootstrapIssue.importVerificationFailed
        }
        defer { sqlite3_finalize(statement) }

        var receipts: [LibraryMigrationSource] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                      let rawName = sqlite3_column_text(statement, 0),
                      sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 4) == SQLITE_TEXT,
                      let rawDigest = sqlite3_column_text(statement, 4),
                      sqlite3_column_type(statement, 5) == SQLITE_FLOAT else {
                    throw LibraryBootstrapIssue.importVerificationFailed
                }
                let rawByteCount = sqlite3_column_int64(statement, 2)
                guard rawByteCount >= 0, let byteCount = Int(exactly: rawByteCount) else {
                    throw LibraryBootstrapIssue.importVerificationFailed
                }
                let sourceVersion: Int?
                if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                    sourceVersion = nil
                } else {
                    guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                          let version = Int(exactly: sqlite3_column_int64(statement, 1)) else {
                        throw LibraryBootstrapIssue.importVerificationFailed
                    }
                    sourceVersion = version
                }
                let importedAt = sqlite3_column_double(statement, 5)
                guard importedAt.isFinite else {
                    throw LibraryBootstrapIssue.importVerificationFailed
                }
                receipts.append(
                    LibraryMigrationSource(
                        name: String(cString: rawName),
                        sourceVersion: sourceVersion,
                        byteCount: byteCount,
                        modificationTimeNanoseconds: sqlite3_column_int64(statement, 3),
                        digest: String(cString: rawDigest),
                        importedAt: Date(timeIntervalSince1970: importedAt)
                    )
                )
            case SQLITE_DONE:
                return receipts
            default:
                throw LibraryBootstrapIssue.importVerificationFailed
            }
        }
    }

    private static func deterministicUUID(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func modificationTimeNanoseconds(_ status: stat) -> Int64 {
        let seconds = Int64(status.st_mtimespec.tv_sec)
        let nanoseconds = Int64(status.st_mtimespec.tv_nsec)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return 0 }
        return scaled.addingReportingOverflow(nanoseconds).overflow ? scaled : scaled + nanoseconds
    }
}
