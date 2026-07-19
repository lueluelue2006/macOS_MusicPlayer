import Foundation

/// Bounded disk-backed cache for audio duration. Every value is derived from
/// the source file and may be safely quarantined or rebuilt.
actor DurationCache {
    static let shared = DurationCache()

    private static let cacheFileName = "duration-cache.json"
    private static let formatVersion = 3
    private static let legacyFormatVersion = 2
    private static let accessRefreshInterval: TimeInterval = 24 * 60 * 60
    private static let derivedPayloadVersion = 1
    internal static let derivedVariant = "duration-v1"
    internal static let derivedMigrationMarkerKey = "duration-cache-json-to-derived-v1"

    private let cacheFileURLOverride: URL?
    private let derivedStore: DerivedCacheStore?
    private let legacyMigrationURLOverride: URL?
    private let limits: DerivedCacheLimits
    private let now: @Sendable () -> Date
    private let saveDebounce: TimeInterval
    private let maximumSaveLatency: TimeInterval

    init(
        cacheFileURLOverride: URL? = nil,
        derivedStoreOverride: DerivedCacheStore? = nil,
        legacyMigrationURLOverride: URL? = nil,
        limits: DerivedCacheLimits = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        saveDebounce: TimeInterval = 0.75,
        maximumSaveLatency: TimeInterval = 5
    ) {
        let resolvedDerivedStore = cacheFileURLOverride == nil
            ? (derivedStoreOverride ?? DerivedCacheStore.shared)
            : nil
        self.cacheFileURLOverride = cacheFileURLOverride
        self.derivedStore = resolvedDerivedStore
        self.legacyMigrationURLOverride = legacyMigrationURLOverride
        self.limits = limits
        self.now = now
        self.saveDebounce = max(0.01, saveDebounce)
        self.maximumSaveLatency = max(self.saveDebounce, maximumSaveLatency)
        self.derivedGeneration = resolvedDerivedStore?.generation(for: .duration) ?? 0
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

    private struct LegacyCacheFile: Decodable {
        let version: Int
        let entries: [String: LegacyEntry]
        let rejectedEntryCount: Int

        private enum CodingKeys: String, CodingKey {
            case version
            case entries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            let lossy = try container.decode(
                DerivedCacheLossyDictionary<LegacyEntry>.self,
                forKey: .entries
            )
            entries = lossy.values
            rejectedEntryCount = lossy.rejectedValueCount
        }
    }

    private struct CacheVersionProbe: Codable {
        let version: Int?
    }

    private struct Entry: Codable, Equatable {
        let durationSeconds: Double
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
        var lastAccessedAt: Int64
    }

    private struct LegacyEntry: Decodable {
        let durationSeconds: Double
        let fileSize: Int64
        let mtimeNs: Int64
        let inode: Int64?
    }

    private struct DerivedPayload: Codable, Equatable {
        let version: Int
        let durationSeconds: Double
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
    private var derivedGeneration: UInt64

    nonisolated static func key(for url: URL) -> String {
        PathKey.canonical(for: url)
    }

    nonisolated static func legacyKey(for url: URL) -> String {
        PathKey.legacy(for: url)
    }

    func cachedDurationIfValid(
        for url: URL,
        snapshot: FileValidationSnapshot? = nil
    ) -> TimeInterval? {
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            return cachedDerivedDurationIfValid(for: url, snapshot: snapshot)
        }

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
        guard current == expected, isValid(entry) else {
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

        return entry.durationSeconds
    }

    func storeDuration(
        _ duration: TimeInterval,
        for url: URL,
        snapshot: FileValidationSnapshot? = nil
    ) {
        loadIfNeeded()
        guard duration.isFinite, duration > 0 else { return }
        guard let signature = fileSignature(for: url, snapshot: snapshot) else { return }

        if cacheFileURLOverride == nil {
            storeDerivedDuration(duration, for: url, signature: signature)
            return
        }

        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        let entry = Entry(
            durationSeconds: duration,
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
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            removeDerivedEntry(for: url)
            return
        }
        removeEntryWithoutLoading(for: url)
    }

    func removeAll() {
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            clearDerivedEntries()
            return
        }
        guard !entries.isEmpty else { return }
        pendingPrunedEntryCount += entries.count
        entries.removeAll(keepingCapacity: false)
        recordMutation()
    }

    @discardableResult
    func flushPersistence() -> Result<DerivedCacheFlushReport, DerivedCachePersistenceError> {
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            return flushDerivedPersistence()
        }
        return flushPersistenceInternal(cancelPending: true, retryOnFailure: false)
    }

    @discardableResult
    func clearPersistence() -> Result<DerivedCacheClearReport, DerivedCachePersistenceError> {
        loadIfNeeded()
        if cacheFileURLOverride == nil {
            return clearDerivedPersistence()
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

    // MARK: - Incremental derived-store backend

    private func cachedDerivedDurationIfValid(
        for url: URL,
        snapshot: FileValidationSnapshot?
    ) -> TimeInterval? {
        guard let derivedStore else { return nil }
        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        guard let signature = fileSignature(for: url, snapshot: snapshot) else {
            removeDerivedKeys([key, legacyKey], store: derivedStore)
            return nil
        }
        let identity = derivedIdentity(signature)

        if let record = derivedStore.record(
            kind: .duration,
            key: key,
            variant: Self.derivedVariant,
            matching: identity,
            touch: true
        ) {
            return decodedDerivedDuration(from: record, store: derivedStore)
        }

        guard legacyKey != key,
              let legacyRecord = derivedStore.record(
                kind: .duration,
                key: legacyKey,
                variant: Self.derivedVariant,
                matching: identity,
                touch: true
              ),
              let duration = decodedDerivedDuration(
                from: legacyRecord,
                store: derivedStore,
                deleteIfInvalid: false
              ) else {
            return nil
        }

        let canonicalRecord = DerivedCacheStore.Record(
            kind: .duration,
            key: key,
            variant: Self.derivedVariant,
            payload: legacyRecord.payload,
            fileIdentity: legacyRecord.fileIdentity,
            updatedAt: legacyRecord.updatedAt,
            lastAccessedAt: legacyRecord.lastAccessedAt
        )
        let migrated = enqueueDerived(
            [
                .upsert(canonicalRecord, expectedGeneration: derivedGeneration),
                .delete(
                    kind: .duration,
                    key: legacyKey,
                    variant: Self.derivedVariant,
                    expectedGeneration: derivedGeneration
                )
            ],
            store: derivedStore
        )
        return migrated ? duration : nil
    }

    private func storeDerivedDuration(
        _ duration: TimeInterval,
        for url: URL,
        signature: FileSignature
    ) {
        guard let derivedStore,
              let payload = encodedDerivedPayload(duration: duration) else { return }
        let timestamp = now().timeIntervalSince1970
        guard timestamp.isFinite else { return }

        let key = Self.key(for: url)
        let legacyKey = Self.legacyKey(for: url)
        let record = DerivedCacheStore.Record(
            kind: .duration,
            key: key,
            variant: Self.derivedVariant,
            payload: payload,
            fileIdentity: derivedIdentity(signature),
            updatedAt: timestamp,
            lastAccessedAt: timestamp
        )
        var mutations: [DerivedCacheStore.Mutation] = [
            .upsert(record, expectedGeneration: derivedGeneration)
        ]
        if legacyKey != key {
            mutations.append(
                .delete(
                    kind: .duration,
                    key: legacyKey,
                    variant: Self.derivedVariant,
                    expectedGeneration: derivedGeneration
                )
            )
        }
        _ = enqueueDerived(mutations, store: derivedStore)
    }

    private func removeDerivedEntry(for url: URL) {
        guard let derivedStore else { return }
        removeDerivedKeys(
            [Self.key(for: url), Self.legacyKey(for: url)],
            store: derivedStore
        )
    }

    private func removeDerivedKeys(
        _ keys: [String],
        store: DerivedCacheStore
    ) {
        let mutations = Set(keys).map {
            DerivedCacheStore.Mutation.delete(
                kind: .duration,
                key: $0,
                variant: Self.derivedVariant,
                expectedGeneration: derivedGeneration
            )
        }
        _ = enqueueDerived(mutations, store: store)
    }

    private func clearDerivedEntries() {
        guard let derivedStore else { return }
        switch derivedStore.clear(.duration) {
        case .success:
            derivedGeneration = derivedStore.generation(for: .duration)
        case .failure(let error):
            PersistenceLogger.log("清空时长派生缓存失败：\(error.localizedDescription)")
        }
    }

    private func flushDerivedPersistence(
    ) -> Result<DerivedCacheFlushReport, DerivedCachePersistenceError> {
        guard let derivedStore else { return .failure(.storageUnavailable) }
        switch derivedStore.flush() {
        case .success(let report):
            return .success(
                DerivedCacheFlushReport(
                    wroteFile: report.wroteDatabase,
                    entryCount: derivedStore.persistedEntryCount(for: .duration),
                    prunedEntryCount: report.prunedEntryCount
                )
            )
        case .failure(let error):
            return .failure(derivedPersistenceError(error))
        }
    }

    private func clearDerivedPersistence(
    ) -> Result<DerivedCacheClearReport, DerivedCachePersistenceError> {
        guard let derivedStore else { return .failure(.storageUnavailable) }
        switch derivedStore.clear(.duration) {
        case .success(let report):
            derivedGeneration = derivedStore.generation(for: .duration)
            return .success(
                DerivedCacheClearReport(
                    removedEntryCount: report.removedEntryCount,
                    quarantinedFileCount: 0
                )
            )
        case .failure(let error):
            return .failure(derivedPersistenceError(error))
        }
    }

    private func enqueueDerived(
        _ mutations: [DerivedCacheStore.Mutation],
        store: DerivedCacheStore
    ) -> Bool {
        guard !mutations.isEmpty else { return true }
        switch store.enqueue(mutations) {
        case .success:
            return true
        case .failure(.staleGeneration(_, _, let actual)):
            derivedGeneration = actual
            return false
        case .failure(let error):
            PersistenceLogger.log("更新时长派生缓存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func decodedDerivedDuration(
        from record: DerivedCacheStore.Record,
        store: DerivedCacheStore,
        deleteIfInvalid: Bool = true
    ) -> TimeInterval? {
        guard let payload = try? JSONDecoder().decode(
            DerivedPayload.self,
            from: record.payload
        ),
              payload.version == Self.derivedPayloadVersion,
              payload.durationSeconds.isFinite,
              payload.durationSeconds > 0 else {
            if deleteIfInvalid {
                _ = enqueueDerived(
                    [
                        .delete(
                            kind: .duration,
                            key: record.key,
                            variant: record.variant,
                            expectedGeneration: derivedGeneration
                        )
                    ],
                    store: store
                )
            }
            return nil
        }
        return payload.durationSeconds
    }

    private func encodedDerivedPayload(duration: TimeInterval) -> Data? {
        try? JSONEncoder().encode(
            DerivedPayload(
                version: Self.derivedPayloadVersion,
                durationSeconds: duration
            )
        )
    }

    private func derivedIdentity(
        _ signature: FileSignature
    ) -> DerivedCacheStore.FileIdentity {
        DerivedCacheStore.FileIdentity(
            fileSize: signature.fileSize,
            modificationTimeNanoseconds: signature.mtimeNs,
            fileIdentifier: signature.inode
        )
    }

    private func derivedPersistenceError(
        _ error: DerivedCacheStore.StoreError
    ) -> DerivedCachePersistenceError {
        switch error {
        case .storageUnavailable:
            return .storageUnavailable
        default:
            return .writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        if cacheFileURLOverride == nil {
            migrateLegacyJSONToDerivedStoreIfNeeded()
            return
        }

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
            loadLegacyV2(data: data, url: url)
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

    private func migrateLegacyJSONToDerivedStoreIfNeeded() {
        guard let derivedStore else { return }
        let markerKey = Self.derivedMigrationMarkerKey
        guard derivedStore.migrationMarker(for: markerKey) == nil else { return }

        guard let legacyURL = legacyCacheFileURL() else {
            completeDerivedMigration(
                mutations: [],
                fingerprint: "legacy-location-unavailable",
                store: derivedStore
            )
            return
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            completeDerivedMigration(
                mutations: [],
                fingerprint: "missing",
                store: derivedStore
            )
            return
        }

        let data: Data
        do {
            data = try DerivedCacheFileIO.readBoundedRegularFile(
                at: legacyURL,
                maximumBytes: limits.maximumFileBytes
            )
        } catch {
            completeDerivedMigration(
                mutations: [],
                fingerprint: "unreadable-or-oversized",
                store: derivedStore
            )
            return
        }

        let fingerprint = Self.legacyFingerprint(data)
        guard let probe = try? JSONDecoder().decode(CacheVersionProbe.self, from: data),
              let version = probe.version else {
            completeDerivedMigration(
                mutations: [],
                fingerprint: "invalid:\(fingerprint)",
                store: derivedStore
            )
            return
        }

        let decodedEntries: [String: Entry]
        switch version {
        case Self.formatVersion:
            guard let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) else {
                completeDerivedMigration(
                    mutations: [],
                    fingerprint: "invalid-v3:\(fingerprint)",
                    store: derivedStore
                )
                return
            }
            var rejected = decoded.rejectedEntryCount
            decodedEntries = normalizedLegacyEntries(
                decoded.entries,
                rejectedCount: &rejected
            )

        case Self.legacyFormatVersion:
            guard let decoded = try? JSONDecoder().decode(LegacyCacheFile.self, from: data) else {
                completeDerivedMigration(
                    mutations: [],
                    fingerprint: "invalid-v2:\(fingerprint)",
                    store: derivedStore
                )
                return
            }
            let accessTime = Int64(now().timeIntervalSince1970.rounded(.down))
            var current: [String: Entry] = [:]
            current.reserveCapacity(min(decoded.entries.count, limits.maximumEntries))
            for (path, legacy) in decoded.entries {
                current[path] = Entry(
                    durationSeconds: legacy.durationSeconds,
                    fileSize: legacy.fileSize,
                    mtimeNs: legacy.mtimeNs,
                    inode: legacy.inode,
                    lastAccessedAt: accessTime
                )
            }
            var rejected = decoded.rejectedEntryCount
            decodedEntries = normalizedLegacyEntries(
                current,
                rejectedCount: &rejected
            )

        default:
            completeDerivedMigration(
                mutations: [],
                fingerprint: "unsupported-v\(version):\(fingerprint)",
                store: derivedStore
            )
            return
        }

        let mutations = decodedEntries.compactMap { key, entry -> DerivedCacheStore.Mutation? in
            guard let payload = encodedDerivedPayload(duration: entry.durationSeconds) else {
                return nil
            }
            let timestamp = TimeInterval(entry.lastAccessedAt)
            let record = DerivedCacheStore.Record(
                kind: .duration,
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
            return .upsert(record, expectedGeneration: derivedGeneration)
        }
        completeDerivedMigration(
            mutations: mutations,
            fingerprint: fingerprint,
            store: derivedStore,
            cleanupLegacyURL: legacyURL
        )
    }

    private func normalizedLegacyEntries(
        _ raw: [String: Entry],
        rejectedCount: inout Int
    ) -> [String: Entry] {
        var normalized: [String: Entry] = [:]
        normalized.reserveCapacity(min(raw.count, limits.maximumEntries))
        for path in raw.keys.sorted() {
            guard let entry = raw[path],
                  Self.isValidLegacyPath(path),
                  isValid(entry) else {
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

        guard normalized.count > limits.maximumEntries else { return normalized }
        let keepCount = min(limits.lowWatermark, normalized.count)
        let newest = normalized.sorted { lhs, rhs in
            if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                return lhs.key < rhs.key
            }
            return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
        }.prefix(keepCount)
        rejectedCount += normalized.count - newest.count
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    private func completeDerivedMigration(
        mutations: [DerivedCacheStore.Mutation],
        fingerprint: String,
        store: DerivedCacheStore,
        cleanupLegacyURL: URL? = nil
    ) {
        let marker = DerivedCacheStore.MigrationMarker(
            key: Self.derivedMigrationMarkerKey,
            sourceFingerprint: fingerprint,
            completedAt: now().timeIntervalSince1970
        )
        switch store.enqueue(mutations, migrationMarkers: [marker]) {
        case .success:
            if case .failure(let error) = store.flush() {
                PersistenceLogger.log("迁移旧时长缓存落盘失败：\(error.localizedDescription)")
            } else if store.migrationMarker(for: marker.key) == marker,
                      let cleanupLegacyURL {
                cleanupMigratedLegacyFileIfMatching(marker, at: cleanupLegacyURL)
            }

        case .failure(.staleGeneration(_, _, let actual)):
            // A concurrent clear won the generation race. Preserve the clear by
            // committing only the marker, so a later launch cannot resurrect
            // rows from the old JSON file.
            derivedGeneration = actual
            switch store.enqueue([], migrationMarkers: [marker]) {
            case .success:
                if case .success = store.flush(),
                   store.migrationMarker(for: marker.key) == marker,
                   let cleanupLegacyURL {
                    cleanupMigratedLegacyFileIfMatching(marker, at: cleanupLegacyURL)
                }
            case .failure(let error):
                PersistenceLogger.log("记录时长缓存迁移标记失败：\(error.localizedDescription)")
            }

        case .failure(let error):
            PersistenceLogger.log("迁移旧时长缓存失败：\(error.localizedDescription)")
        }
    }

    private func cleanupMigratedLegacyFileIfMatching(
        _ marker: DerivedCacheStore.MigrationMarker,
        at legacyURL: URL
    ) {
        guard let current = try? DerivedCacheFileIO.readBoundedRegularFile(
            at: legacyURL,
            maximumBytes: limits.maximumFileBytes
        ),
              Self.legacyFingerprint(current) == marker.sourceFingerprint else { return }
        do {
            try FileManager.default.removeItem(at: legacyURL)
        } catch {
            PersistenceLogger.log("清理已迁移的时长 JSON 缓存失败：\(error.localizedDescription)")
        }
    }

    nonisolated private static func isValidLegacyPath(_ path: String) -> Bool {
        !path.isEmpty
            && path.hasPrefix("/")
            && !path.utf8.contains(0)
            && path.utf8.count <= 16 * 1_024
    }

    nonisolated private static func legacyFingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "fnv1a64:\(data.count):\(String(format: "%016llx", hash))"
    }

    private func loadLegacyV2(data: Data, url: URL) {
        guard let decoded = try? JSONDecoder().decode(LegacyCacheFile.self, from: data),
              decoded.version == Self.legacyFormatVersion else {
            quarantineAndReset(url: url, reason: .corrupt)
            return
        }

        let accessTime = Int64(now().timeIntervalSince1970.rounded(.down))
        var migrated: [String: Entry] = [:]
        migrated.reserveCapacity(min(decoded.entries.count, limits.maximumEntries))
        var rejectedCount = decoded.rejectedEntryCount
        for path in decoded.entries.keys.sorted() {
            guard let legacy = decoded.entries[path],
                  legacy.durationSeconds.isFinite,
                  legacy.durationSeconds > 0,
                  legacy.fileSize >= 0 else {
                rejectedCount += 1
                continue
            }
            let key = PathKey.canonical(path: path)
            let entry = Entry(
                durationSeconds: legacy.durationSeconds,
                fileSize: legacy.fileSize,
                mtimeNs: legacy.mtimeNs,
                inode: legacy.inode,
                lastAccessedAt: accessTime
            )
            if migrated[key] == nil {
                migrated[key] = entry
            } else {
                rejectedCount += 1
            }
        }
        entries = migrated
        if entries.count > limits.maximumEntries {
            rejectedCount += pruneOldest(to: limits.lowWatermark)
        }
        pendingPrunedEntryCount += rejectedCount
        recordMutation()
    }

    private func quarantineAndReset(url: URL, reason: DerivedCacheQuarantineReason) {
        entries.removeAll(keepingCapacity: false)
        do {
            try DerivedCacheFileIO.quarantine(url, reason: reason, now: now())
            blockedQuarantineReason = nil
            blockedPersistenceError = nil
            recordMutation()
            PersistenceLogger.log("时长派生缓存已隔离并准备重建（\(reason)）")
        } catch let error as DerivedCachePersistenceError {
            blockedQuarantineReason = reason
            blockedPersistenceError = error
            PersistenceLogger.log("时长派生缓存隔离失败：\(error.localizedDescription)")
        } catch {
            blockedQuarantineReason = reason
            blockedPersistenceError = .quarantineFailed(error.localizedDescription)
            PersistenceLogger.log("时长派生缓存隔离失败：\(error.localizedDescription)")
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
            PersistenceLogger.log("保存时长派生缓存失败：\(error.localizedDescription)")
            if retryOnFailure { scheduleRetry() }
            return .failure(error)
        } catch {
            let wrapped = DerivedCachePersistenceError.writeFailed(error.localizedDescription)
            PersistenceLogger.log("保存时长派生缓存失败：\(wrapped.localizedDescription)")
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
            guard let entry = raw[path], entry.fileSize >= 0, isValid(entry) else {
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

    private func isValid(_ entry: Entry) -> Bool {
        entry.durationSeconds.isFinite && entry.durationSeconds > 0 && entry.fileSize >= 0
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

    private func legacyCacheFileURL() -> URL? {
        if let legacyMigrationURLOverride { return legacyMigrationURLOverride }
        guard let environment = try? PersistenceEnvironment.production() else { return nil }
        return environment.applicationSupportURL.appendingPathComponent(
            Self.cacheFileName,
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
