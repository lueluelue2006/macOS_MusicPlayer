import Foundation

/// Bounded disk-backed cache for metadata that is inexpensive to rebuild.
/// User-authored media and playlists are never stored or modified here.
actor MetadataCache {
    static let shared = MetadataCache(cacheFileURLOverride: isolatedTestCacheURL())

    private static let cacheFileName = "metadata-cache.json"
    private static let formatVersion = 2
    private static let legacyFormatVersion = 1
    private static let accessRefreshInterval: TimeInterval = 24 * 60 * 60
    static let derivedVariant = "metadata-v2"
    static let derivedMigrationMarkerKey = "metadata-cache-json-v2-to-derived-v1"
    private static let migrationBatchSize = 128

    private let cacheFileURLOverride: URL?
    private let derivedStore: DerivedCacheStore?
    private let legacyMigrationURLOverride: URL?
    private let limits: DerivedCacheLimits
    private let now: @Sendable () -> Date
    private let saveDebounce: TimeInterval
    private let maximumSaveLatency: TimeInterval

    init(
        cacheFileURLOverride: URL? = nil,
        limits: DerivedCacheLimits = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        saveDebounce: TimeInterval = 0.75,
        maximumSaveLatency: TimeInterval = 5,
        derivedStoreOverride: DerivedCacheStore? = nil,
        legacyMigrationURLOverride: URL? = nil
    ) {
        self.cacheFileURLOverride = cacheFileURLOverride
        derivedStore = cacheFileURLOverride == nil
            ? (derivedStoreOverride ?? DerivedCacheStore.shared)
            : nil
        self.legacyMigrationURLOverride = legacyMigrationURLOverride
        self.limits = limits
        self.now = now
        self.saveDebounce = max(0.01, saveDebounce)
        self.maximumSaveLatency = max(self.saveDebounce, maximumSaveLatency)
    }

    private struct CacheFile: Codable {
        let version: Int
        let entries: [String: Entry]
        let rejectedEntryCount: Int

        private enum CodingKeys: String, CodingKey {
            case version
            case entries
        }

        init(version: Int, entries: [String: Entry]) {
            self.version = version
            self.entries = entries
            self.rejectedEntryCount = 0
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            let lossy = try container.decode(
                DerivedCacheLossyDictionary<Entry>.self,
                forKey: .entries
            )
            entries = lossy.values
            rejectedEntryCount = lossy.rejectedValueCount
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(entries, forKey: .entries)
        }
    }

    private struct CacheVersionProbe: Codable {
        let version: Int?
    }

    private struct Entry: Codable, Equatable {
        let title: String
        let artist: String
        let album: String
        let year: String?
        let genre: String?
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
        var lastAccessedAt: Int64
    }

    private struct DerivedPayload: Codable, Equatable {
        let version: Int
        let title: String
        let artist: String
        let album: String
        let year: String?
        let genre: String?
    }

    private struct FileSignature: Equatable {
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
    }

    private var isLoaded = false
    private var entries: [String: Entry] = [:]
    private var mutationGeneration: UInt64 = 0
    private var persistedGeneration: UInt64 = 0
    private var pendingSaveTask: Task<Void, Never>?
    private var pendingSaveID: UUID?
    private var firstDirtyAt: Date?
    private var retryAttempt = 0
    private var pendingPrunedEntryCount = 0
    private var blockedQuarantineReason: DerivedCacheQuarantineReason?
    private var blockedPersistenceError: DerivedCachePersistenceError?
    private var didAttemptDerivedMigration = false

    nonisolated static func key(for url: URL) -> String {
        PathKey.canonical(for: url)
    }

    nonisolated static func legacyKey(for url: URL) -> String {
        PathKey.legacy(for: url)
    }

    func cachedMetadataIfValid(
        for url: URL,
        snapshot: FileValidationSnapshot? = nil
    ) -> AudioMetadata? {
        if let derivedStore {
            ensureDerivedMigrationIfNeeded(using: derivedStore)
            return cachedDerivedMetadataIfValid(
                for: url,
                snapshot: snapshot,
                store: derivedStore
            )
        }
        loadIfNeeded()

        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        var matchedKey = key
        guard var entry: Entry = {
            if let exact = entries[key] {
                return exact
            }
            guard legacyKey != key, let legacy = entries[legacyKey] else {
                return nil
            }
            entries[key] = legacy
            entries.removeValue(forKey: legacyKey)
            matchedKey = key
            recordMutation()
            return legacy
        }() else { return nil }

        guard let current = fileSignature(for: url, snapshot: snapshot) else {
            entries.removeValue(forKey: matchedKey)
            recordMutation()
            return nil
        }

        let expected = FileSignature(
            fileSize: entry.fileSize,
            mtimeNs: entry.mtimeNs,
            inode: entry.inode
        )
        guard current == expected, isCacheable(entry) else {
            entries.removeValue(forKey: matchedKey)
            recordMutation()
            return nil
        }

        let accessTime = Int64(now().timeIntervalSince1970.rounded(.down))
        if accessTime - entry.lastAccessedAt >= Int64(Self.accessRefreshInterval) {
            entry.lastAccessedAt = accessTime
            entries[matchedKey] = entry
            recordMutation()
        }

        return AudioMetadata(
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            year: entry.year,
            genre: entry.genre,
            artwork: nil
        )
    }

    /// The historical name is retained for call-site compatibility; v2 stores
    /// every lightweight textual field, including year and genre.
    func storeBasicMetadata(
        _ metadata: AudioMetadata,
        for url: URL,
        snapshot: FileValidationSnapshot? = nil
    ) {
        if let derivedStore {
            ensureDerivedMigrationIfNeeded(using: derivedStore)
            storeDerivedMetadata(
                metadata,
                for: url,
                snapshot: snapshot,
                store: derivedStore
            )
            return
        }
        loadIfNeeded()
        guard isCacheable(metadata) else {
            removeEntryWithoutLoading(for: url)
            return
        }
        guard let signature = fileSignature(for: url, snapshot: snapshot) else { return }

        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        let entry = Entry(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            year: metadata.year,
            genre: metadata.genre,
            fileSize: signature.fileSize,
            mtimeNs: signature.mtimeNs,
            inode: signature.inode,
            lastAccessedAt: Int64(now().timeIntervalSince1970.rounded(.down))
        )

        if entries[key] != entry || (legacyKey != key && entries[legacyKey] != nil) {
            entries[key] = entry
            if legacyKey != key {
                entries.removeValue(forKey: legacyKey)
            }
            recordMutation()
            enforceEntryLimitIfNeeded()
        }
    }

    func remove(for url: URL) {
        if let derivedStore {
            ensureDerivedMigrationIfNeeded(using: derivedStore)
            removeDerivedMetadata(for: url, store: derivedStore)
            return
        }
        loadIfNeeded()
        removeEntryWithoutLoading(for: url)
    }

    /// Clears the in-memory cache and schedules an atomic empty snapshot.
    /// User-facing commands should prefer `clearPersistence()` so they can
    /// report a real disk result rather than optimistic success.
    func removeAll() {
        if let derivedStore {
            ensureDerivedMigrationIfNeeded(using: derivedStore)
            if case .failure(let error) = derivedStore.clear(.metadata) {
                PersistenceLogger.log("清空元数据 SQLite 派生缓存失败：\(error.localizedDescription)")
            }
            return
        }
        loadIfNeeded()
        guard !entries.isEmpty else { return }
        pendingPrunedEntryCount += entries.count
        entries.removeAll(keepingCapacity: false)
        recordMutation()
    }

    @discardableResult
    func flushPersistence() -> Result<DerivedCacheFlushReport, DerivedCachePersistenceError> {
        if let derivedStore {
            ensureDerivedMigrationIfNeeded(using: derivedStore)
            return flushDerivedPersistence(derivedStore)
        }
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            return .success(
                DerivedCacheFlushReport(
                    wroteFile: false,
                    entryCount: entries.count,
                    prunedEntryCount: 0
                )
            )
        }
        return flushPersistenceInternal(cancelPending: true, retryOnFailure: false)
    }

    @discardableResult
    func clearPersistence() -> Result<DerivedCacheClearReport, DerivedCachePersistenceError> {
        if let derivedStore {
            ensureDerivedMigrationIfNeeded(using: derivedStore)
            switch derivedStore.clear(.metadata) {
            case .success(let report):
                return .success(
                    DerivedCacheClearReport(
                        removedEntryCount: report.removedEntryCount,
                        quarantinedFileCount: 0
                    )
                )
            case .failure(let error):
                return .failure(mapDerivedStoreError(error))
            }
        }
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            let removedEntryCount = entries.count
            entries.removeAll(keepingCapacity: false)
            mutationGeneration &+= 1
            persistedGeneration = mutationGeneration
            firstDirtyAt = nil
            retryAttempt = 0
            pendingPrunedEntryCount = 0
            return .success(
                DerivedCacheClearReport(
                    removedEntryCount: removedEntryCount,
                    quarantinedFileCount: 0
                )
            )
        }
        cancelPendingSave()

        var quarantinedFileCount = 0
        if let reason = blockedQuarantineReason, let url = rawCacheFileURL(), FileManager.default.fileExists(atPath: url.path) {
            do {
                try DerivedCacheFileIO.quarantine(url, reason: reason, now: now())
                quarantinedFileCount = 1
                blockedQuarantineReason = nil
                blockedPersistenceError = nil
            } catch let error as DerivedCachePersistenceError {
                return .failure(error)
            } catch {
                return .failure(.quarantineFailed(error.localizedDescription))
            }
        }

        guard let url = cacheFileURL() else {
            if mutationGeneration != persistedGeneration { scheduleSave() }
            return .failure(.storageUnavailable)
        }

        let emptyData: Data
        do {
            emptyData = try encodedData(entries: [:])
            try DerivedCacheFileIO.atomicWrite(emptyData, to: url)
        } catch let error as DerivedCachePersistenceError {
            if mutationGeneration != persistedGeneration { scheduleSave() }
            return .failure(error)
        } catch {
            if mutationGeneration != persistedGeneration { scheduleSave() }
            return .failure(.writeFailed(error.localizedDescription))
        }

        let removedEntryCount = entries.count
        entries.removeAll(keepingCapacity: false)
        mutationGeneration &+= 1
        persistedGeneration = mutationGeneration
        firstDirtyAt = nil
        retryAttempt = 0
        pendingPrunedEntryCount = 0
        blockedQuarantineReason = nil
        blockedPersistenceError = nil
        return .success(
            DerivedCacheClearReport(
                removedEntryCount: removedEntryCount,
                quarantinedFileCount: quarantinedFileCount
            )
        )
    }

    internal func flushForTesting() {
        _ = flushPersistence()
    }

    // MARK: - Incremental SQLite backend

    private func cachedDerivedMetadataIfValid(
        for url: URL,
        snapshot: FileValidationSnapshot?,
        store: DerivedCacheStore
    ) -> AudioMetadata? {
        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        guard let signature = fileSignature(for: url, snapshot: snapshot) else {
            removeDerivedMetadata(for: url, store: store)
            return nil
        }
        let identity = derivedIdentity(signature)

        if let record = store.record(
            kind: .metadata,
            key: key,
            variant: Self.derivedVariant,
            matching: identity
        ) {
            guard let metadata = metadata(fromDerivedRecord: record) else {
                deleteDerivedRecord(key: key, store: store)
                return nil
            }
            return metadata
        }

        guard legacyKey != key,
              let legacyRecord = store.record(
                kind: .metadata,
                key: legacyKey,
                variant: Self.derivedVariant,
                matching: identity
              ) else { return nil }
        guard let metadata = metadata(fromDerivedRecord: legacyRecord) else {
            deleteDerivedRecord(key: legacyKey, store: store)
            return nil
        }

        let generation = store.generation(for: .metadata)
        let canonical = DerivedCacheStore.Record(
            kind: .metadata,
            key: key,
            variant: Self.derivedVariant,
            payload: legacyRecord.payload,
            fileIdentity: legacyRecord.fileIdentity,
            updatedAt: legacyRecord.updatedAt,
            lastAccessedAt: legacyRecord.lastAccessedAt
        )
        let result = store.enqueue([
            .upsert(canonical, expectedGeneration: generation),
            .delete(
                kind: .metadata,
                key: legacyKey,
                variant: Self.derivedVariant,
                expectedGeneration: generation
            )
        ])
        if case .failure(let error) = result {
            PersistenceLogger.log("迁移元数据 SQLite 路径键失败：\(error.localizedDescription)")
        }
        return metadata
    }

    private func storeDerivedMetadata(
        _ metadata: AudioMetadata,
        for url: URL,
        snapshot: FileValidationSnapshot?,
        store: DerivedCacheStore
    ) {
        guard isCacheable(metadata),
              let signature = fileSignature(for: url, snapshot: snapshot),
              let payload = try? encodedDerivedPayload(metadata) else {
            removeDerivedMetadata(for: url, store: store)
            return
        }

        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        let timestamp = now().timeIntervalSince1970
        guard timestamp.isFinite else { return }
        let generation = store.generation(for: .metadata)
        let record = DerivedCacheStore.Record(
            kind: .metadata,
            key: key,
            variant: Self.derivedVariant,
            payload: payload,
            fileIdentity: derivedIdentity(signature),
            updatedAt: timestamp,
            lastAccessedAt: timestamp
        )
        var mutations: [DerivedCacheStore.Mutation] = [
            .upsert(record, expectedGeneration: generation)
        ]
        if legacyKey != key {
            mutations.append(
                .delete(
                    kind: .metadata,
                    key: legacyKey,
                    variant: Self.derivedVariant,
                    expectedGeneration: generation
                )
            )
        }
        if case .failure(let error) = store.enqueue(mutations) {
            PersistenceLogger.log("保存元数据 SQLite 派生缓存失败：\(error.localizedDescription)")
        }
    }

    private func removeDerivedMetadata(for url: URL, store: DerivedCacheStore) {
        let generation = store.generation(for: .metadata)
        var seen = Set<String>()
        let mutations = [Self.key(for: url), Self.legacyKey(for: url)].compactMap {
            key -> DerivedCacheStore.Mutation? in
            guard seen.insert(key).inserted else { return nil }
            return .delete(
                kind: .metadata,
                key: key,
                variant: Self.derivedVariant,
                expectedGeneration: generation
            )
        }
        if case .failure(let error) = store.enqueue(mutations) {
            PersistenceLogger.log("删除元数据 SQLite 派生缓存失败：\(error.localizedDescription)")
        }
    }

    private func deleteDerivedRecord(key: String, store: DerivedCacheStore) {
        let generation = store.generation(for: .metadata)
        if case .failure(let error) = store.enqueue([
            .delete(
                kind: .metadata,
                key: key,
                variant: Self.derivedVariant,
                expectedGeneration: generation
            )
        ]) {
            PersistenceLogger.log("清理损坏的元数据 SQLite 记录失败：\(error.localizedDescription)")
        }
    }

    private func flushDerivedPersistence(
        _ store: DerivedCacheStore
    ) -> Result<DerivedCacheFlushReport, DerivedCachePersistenceError> {
        switch store.flush() {
        case .success(let report):
            return .success(
                DerivedCacheFlushReport(
                    wroteFile: report.wroteDatabase,
                    entryCount: store.persistedEntryCount(for: .metadata),
                    prunedEntryCount: report.prunedEntryCount
                )
            )
        case .failure(let error):
            return .failure(mapDerivedStoreError(error))
        }
    }

    private func metadata(fromDerivedRecord record: DerivedCacheStore.Record) -> AudioMetadata? {
        guard let payload = try? JSONDecoder().decode(DerivedPayload.self, from: record.payload),
              payload.version == Self.formatVersion else { return nil }
        let metadata = AudioMetadata(
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            year: payload.year,
            genre: payload.genre,
            artwork: nil
        )
        return isCacheable(metadata) ? metadata : nil
    }

    private func encodedDerivedPayload(_ metadata: AudioMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            DerivedPayload(
                version: Self.formatVersion,
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                year: metadata.year,
                genre: metadata.genre
            )
        )
    }

    private func derivedIdentity(_ signature: FileSignature) -> DerivedCacheStore.FileIdentity {
        DerivedCacheStore.FileIdentity(
            fileSize: signature.fileSize,
            modificationTimeNanoseconds: signature.mtimeNs,
            fileIdentifier: signature.inode
        )
    }

    private func mapDerivedStoreError(
        _ error: DerivedCacheStore.StoreError
    ) -> DerivedCachePersistenceError {
        switch error {
        case .storageUnavailable:
            return .storageUnavailable
        case .invalidKey, .invalidVariant, .payloadTooLarge, .invalidRecord,
             .invalidMigrationMarker, .staleGeneration:
            return .encodeFailed(error.localizedDescription)
        case .readOnly, .databaseFailure:
            return .writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Legacy JSON to SQLite migration

    private func ensureDerivedMigrationIfNeeded(using store: DerivedCacheStore) {
        guard !didAttemptDerivedMigration else { return }
        didAttemptDerivedMigration = true
        guard let sourceURL = legacyMigrationFileURL(),
              FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        if let marker = store.migrationMarker(for: Self.derivedMigrationMarkerKey) {
            cleanupMigratedLegacyFileIfMatching(marker, at: sourceURL)
            return
        }

        guard let data = readBoundedLegacyMigrationData(at: sourceURL),
              let probe = try? JSONDecoder().decode(CacheVersionProbe.self, from: data),
              probe.version == Self.formatVersion,
              let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            // Unknown, corrupt and future cache files are deliberately preserved.
            // They are derived data, but a downgrade must not silently destroy
            // bytes written by a newer application version.
            return
        }

        var rejectedCount = decoded.rejectedEntryCount
        var normalized = normalizeAndValidate(decoded.entries, rejectedCount: &rejectedCount)
        if normalized.count > limits.maximumEntries {
            let keep = normalized.sorted { lhs, rhs in
                if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
            }.prefix(limits.lowWatermark)
            normalized = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        let generation = store.generation(for: .metadata)
        var batch: [DerivedCacheStore.Mutation] = []
        batch.reserveCapacity(Self.migrationBatchSize)
        for key in normalized.keys.sorted() {
            guard let entry = normalized[key],
                  let payload = try? encodedDerivedPayload(
                    AudioMetadata(
                        title: entry.title,
                        artist: entry.artist,
                        album: entry.album,
                        year: entry.year,
                        genre: entry.genre,
                        artwork: nil
                    )
                  ) else { continue }
            let timestamp = TimeInterval(entry.lastAccessedAt)
            let record = DerivedCacheStore.Record(
                kind: .metadata,
                key: key,
                variant: Self.derivedVariant,
                payload: payload,
                fileIdentity: DerivedCacheStore.FileIdentity(
                    fileSize: entry.fileSize,
                    modificationTimeNanoseconds: entry.mtimeNs,
                    fileIdentifier: entry.inode
                ),
                updatedAt: timestamp,
                lastAccessedAt: timestamp
            )
            batch.append(.upsert(record, expectedGeneration: generation))
            if batch.count == Self.migrationBatchSize {
                guard case .success = store.enqueue(batch) else { return }
                batch.removeAll(keepingCapacity: true)
            }
        }

        let marker = DerivedCacheStore.MigrationMarker(
            key: Self.derivedMigrationMarkerKey,
            sourceFingerprint: Self.migrationFingerprint(data),
            completedAt: now().timeIntervalSince1970
        )
        guard case .success = store.enqueue(batch, migrationMarkers: [marker]),
              case .success = store.flush(),
              store.migrationMarker(for: marker.key) == marker else { return }
        cleanupMigratedLegacyFileIfMatching(marker, at: sourceURL)
    }

    private func legacyMigrationFileURL() -> URL? {
        if let legacyMigrationURLOverride { return legacyMigrationURLOverride }
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("MusicPlayer", isDirectory: true)
            .appendingPathComponent(Self.cacheFileName, isDirectory: false)
    }

    private func readBoundedLegacyMigrationData(at url: URL) -> Data? {
        do {
            guard try DerivedCacheFileIO.fileSize(at: url) <= limits.maximumFileBytes else {
                return nil
            }
            return try DerivedCacheFileIO.readBoundedRegularFile(
                at: url,
                maximumBytes: limits.maximumFileBytes
            )
        } catch {
            return nil
        }
    }

    private func cleanupMigratedLegacyFileIfMatching(
        _ marker: DerivedCacheStore.MigrationMarker,
        at sourceURL: URL
    ) {
        guard let current = readBoundedLegacyMigrationData(at: sourceURL),
              Self.migrationFingerprint(current) == marker.sourceFingerprint else { return }
        do {
            try FileManager.default.removeItem(at: sourceURL)
        } catch {
            PersistenceLogger.log("清理已迁移的元数据 JSON 缓存失败：\(error.localizedDescription)")
        }
    }

    nonisolated private static func migrationFingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "fnv1a64:%016llx:%d", hash, data.count)
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        // A nil override now means SQLite (or a bounded session-only fallback
        // when the shared store could not initialize), never the old production
        // JSON path. Explicit overrides retain the deterministic legacy backend.
        guard cacheFileURLOverride != nil else { return }
        guard let url = rawCacheFileURL() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            if try DerivedCacheFileIO.fileSize(at: url) > limits.maximumFileBytes {
                quarantineAndReset(url: url, reason: .oversized)
                return
            }
        } catch {
            quarantineAndReset(url: url, reason: .corrupt)
            return
        }

        let data: Data
        do {
            data = try DerivedCacheFileIO.readBoundedRegularFile(
                at: url,
                maximumBytes: limits.maximumFileBytes
            )
        } catch {
            quarantineAndReset(url: url, reason: .corrupt)
            return
        }

        guard let probe = try? JSONDecoder().decode(CacheVersionProbe.self, from: data),
              let version = probe.version else {
            quarantineAndReset(url: url, reason: .corrupt)
            return
        }

        if version > Self.formatVersion {
            quarantineAndReset(url: url, reason: .future(version: version))
            return
        }

        if version == Self.legacyFormatVersion {
            // v1 lacks year, genre and inode. Treat it as a recognized derived
            // cache invalidation so the existing hydration path rebuilds v2.
            quarantineAndReset(url: url, reason: .legacy(version: version))
            return
        }

        guard version == Self.formatVersion,
              let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            quarantineAndReset(url: url, reason: .corrupt)
            return
        }

        var rejectedCount = decoded.rejectedEntryCount
        let normalized = normalizeAndValidate(decoded.entries, rejectedCount: &rejectedCount)
        entries = normalized
        if entries.count > limits.maximumEntries {
            rejectedCount += pruneOldest(to: limits.lowWatermark)
        }

        if rejectedCount > 0 || normalized != decoded.entries {
            pendingPrunedEntryCount += rejectedCount
            recordMutation()
        }
    }

    private func quarantineAndReset(url: URL, reason: DerivedCacheQuarantineReason) {
        entries.removeAll(keepingCapacity: false)
        do {
            try DerivedCacheFileIO.quarantine(url, reason: reason, now: now())
            blockedQuarantineReason = nil
            blockedPersistenceError = nil
            recordMutation()
            PersistenceLogger.log("元数据派生缓存已隔离并准备重建（\(reason)）")
        } catch let error as DerivedCachePersistenceError {
            blockedQuarantineReason = reason
            blockedPersistenceError = error
            PersistenceLogger.log("元数据派生缓存隔离失败：\(error.localizedDescription)")
        } catch {
            blockedQuarantineReason = reason
            blockedPersistenceError = .quarantineFailed(error.localizedDescription)
            PersistenceLogger.log("元数据派生缓存隔离失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Saving

    private func recordMutation(schedule: Bool = true) {
        mutationGeneration &+= 1
        if firstDirtyAt == nil {
            firstDirtyAt = Date()
        }
        if schedule {
            retryAttempt = 0
            scheduleSave()
        }
    }

    private func scheduleSave() {
        guard cacheFileURLOverride != nil else { return }
        guard blockedPersistenceError == nil else { return }
        pendingSaveTask?.cancel()

        let now = Date()
        let firstDirtyAt = self.firstDirtyAt ?? now
        let trailingDeadline = now.addingTimeInterval(saveDebounce)
        let maximumDeadline = firstDirtyAt.addingTimeInterval(maximumSaveLatency)
        let deadline = min(trailingDeadline, maximumDeadline)
        let delay = max(0.01, deadline.timeIntervalSince(now))
        let saveID = UUID()
        pendingSaveID = saveID
        pendingSaveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.runScheduledSave(id: saveID)
        }
    }

    private func runScheduledSave(id: UUID) {
        guard pendingSaveID == id else { return }
        pendingSaveTask = nil
        pendingSaveID = nil
        _ = flushPersistenceInternal(cancelPending: false, retryOnFailure: true)
    }

    private func scheduleRetry() {
        guard blockedPersistenceError == nil else { return }
        guard retryAttempt < 3 else { return }
        pendingSaveTask?.cancel()
        let delays: [TimeInterval] = [2, 10, 60]
        let delay = delays[retryAttempt]
        retryAttempt += 1
        let saveID = UUID()
        pendingSaveID = saveID
        pendingSaveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.runScheduledSave(id: saveID)
        }
    }

    private func cancelPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        pendingSaveID = nil
    }

    private func flushPersistenceInternal(
        cancelPending: Bool,
        retryOnFailure: Bool
    ) -> Result<DerivedCacheFlushReport, DerivedCachePersistenceError> {
        if cancelPending {
            cancelPendingSave()
        }

        if let blockedPersistenceError {
            return .failure(blockedPersistenceError)
        }

        guard mutationGeneration != persistedGeneration else {
            return .success(
                DerivedCacheFlushReport(
                    wroteFile: false,
                    entryCount: entries.count,
                    prunedEntryCount: 0
                )
            )
        }
        guard let url = cacheFileURL() else {
            return .failure(.storageUnavailable)
        }

        let data: Data
        do {
            data = try makeEncodedDataFittingLimit()
            try DerivedCacheFileIO.atomicWrite(data, to: url)
        } catch let error as DerivedCachePersistenceError {
            PersistenceLogger.log("保存元数据派生缓存失败：\(error.localizedDescription)")
            if retryOnFailure { scheduleRetry() }
            return .failure(error)
        } catch {
            let wrapped = DerivedCachePersistenceError.writeFailed(error.localizedDescription)
            PersistenceLogger.log("保存元数据派生缓存失败：\(wrapped.localizedDescription)")
            if retryOnFailure { scheduleRetry() }
            return .failure(wrapped)
        }

        let prunedEntryCount = pendingPrunedEntryCount
        persistedGeneration = mutationGeneration
        pendingPrunedEntryCount = 0
        firstDirtyAt = nil
        retryAttempt = 0
        return .success(
            DerivedCacheFlushReport(
                wroteFile: true,
                entryCount: entries.count,
                prunedEntryCount: prunedEntryCount
            )
        )
    }

    private func makeEncodedDataFittingLimit() throws -> Data {
        enforceEntryLimitIfNeeded(schedule: false)

        while true {
            let data = try encodedData(entries: entries)
            if data.count <= limits.maximumFileBytes {
                return data
            }

            guard !entries.isEmpty else {
                throw DerivedCachePersistenceError.encodeFailed("空缓存仍超过容量限制")
            }
            let reduction = max(1, entries.count / 8)
            let removed = pruneOldest(to: max(0, entries.count - reduction))
            pendingPrunedEntryCount += removed
            mutationGeneration &+= 1
        }
    }

    private func encodedData(entries: [String: Entry]) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(
                CacheFile(version: Self.formatVersion, entries: entries)
            )
        } catch {
            throw DerivedCachePersistenceError.encodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Entries

    private func enforceEntryLimitIfNeeded(schedule: Bool = true) {
        guard entries.count > limits.maximumEntries else { return }
        let removed = pruneOldest(to: limits.lowWatermark)
        guard removed > 0 else { return }
        pendingPrunedEntryCount += removed
        recordMutation(schedule: schedule)
    }

    @discardableResult
    private func pruneOldest(to targetCount: Int) -> Int {
        let targetCount = max(0, targetCount)
        guard entries.count > targetCount else { return 0 }
        let removeCount = entries.count - targetCount
        let oldest = entries.sorted { lhs, rhs in
            if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                return lhs.key < rhs.key
            }
            return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
        }
        for item in oldest.prefix(removeCount) {
            entries.removeValue(forKey: item.key)
        }
        return removeCount
    }

    private func removeEntryWithoutLoading(for url: URL) {
        var removed = false
        for key in [Self.key(for: url), Self.legacyKey(for: url)] {
            if entries.removeValue(forKey: key) != nil {
                removed = true
            }
        }
        if removed {
            pendingPrunedEntryCount += 1
            recordMutation()
        }
    }

    private func normalizeAndValidate(
        _ raw: [String: Entry],
        rejectedCount: inout Int
    ) -> [String: Entry] {
        var normalized: [String: Entry] = [:]
        normalized.reserveCapacity(min(raw.count, limits.maximumEntries))
        for path in raw.keys.sorted() {
            guard let entry = raw[path], entry.fileSize >= 0, isCacheable(entry) else {
                rejectedCount += 1
                continue
            }
            let key = PathKey.canonical(path: path)
            if let existing = normalized[key] {
                if entry.lastAccessedAt > existing.lastAccessedAt {
                    normalized[key] = entry
                }
                rejectedCount += 1
            } else {
                normalized[key] = entry
            }
        }
        return normalized
    }

    private func isCacheable(_ metadata: AudioMetadata) -> Bool {
        fieldsAreBounded(metadata.title, metadata.artist, metadata.album, metadata.year ?? "", metadata.genre ?? "")
            && !looksCorrupted(metadata.title)
            && !looksCorrupted(metadata.artist)
            && !looksCorrupted(metadata.album)
            && !looksCorrupted(metadata.year ?? "")
            && !looksCorrupted(metadata.genre ?? "")
    }

    private func isCacheable(_ entry: Entry) -> Bool {
        fieldsAreBounded(entry.title, entry.artist, entry.album, entry.year ?? "", entry.genre ?? "")
            && !looksCorrupted(entry.title)
            && !looksCorrupted(entry.artist)
            && !looksCorrupted(entry.album)
            && !looksCorrupted(entry.year ?? "")
            && !looksCorrupted(entry.genre ?? "")
    }

    private func looksCorrupted(_ value: String) -> Bool {
        value.contains("\u{FFFD}")
    }

    private func fieldsAreBounded(_ values: String...) -> Bool {
        var aggregateBytes = 0
        for value in values {
            let count = value.utf8.count
            guard count <= 16 * 1_024 else { return false }
            aggregateBytes += count
            guard aggregateBytes <= 32 * 1_024 else { return false }
        }
        return true
    }

    // MARK: - Paths and signatures

    private func rawCacheFileURL() -> URL? {
        cacheFileURLOverride
    }

    private func cacheFileURL() -> URL? {
        guard let url = rawCacheFileURL() else { return nil }
        do {
            try DerivedCacheFileIO.ensureParentDirectory(for: url)
            return url
        } catch {
            return nil
        }
    }

    nonisolated private static func isolatedTestCacheURL() -> URL? {
        let process = ProcessInfo.processInfo
        let environment = process.environment
        let isRegressionRun = environment["MUSICPLAYER_RUN_REGRESSION_TESTS"] == "1"
        let isTestProcess =
            environment["XCTestConfigurationFilePath"] != nil
            || process.processName.localizedCaseInsensitiveContains("test")
            || process.processName.localizedCaseInsensitiveContains("xctest")
        guard isRegressionRun || isTestProcess else { return nil }

        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicplayer-metadata-cache-\(process.processIdentifier).json",
            isDirectory: false
        )
    }

    private func fileSignature(
        for url: URL,
        snapshot: FileValidationSnapshot?
    ) -> FileSignature? {
        if let snapshot {
            guard snapshot.exists else { return nil }
            return FileSignature(
                fileSize: snapshot.fileSize,
                mtimeNs: snapshot.mtimeNs,
                inode: snapshot.inode
            )
        }

        let loaded = FileValidationSnapshot.load(for: url)
        guard loaded.exists else { return nil }
        return FileSignature(
            fileSize: loaded.fileSize,
            mtimeNs: loaded.mtimeNs,
            inode: loaded.inode
        )
    }
}
