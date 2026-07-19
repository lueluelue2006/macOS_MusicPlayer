import Foundation

/// Bounded disk-backed cache for audio duration. Every value is derived from
/// the source file and may be safely quarantined or rebuilt.
actor DurationCache {
    static let shared = DurationCache(cacheFileURLOverride: isolatedTestCacheURL())

    private static let cacheFileName = "duration-cache.json"
    private static let formatVersion = 3
    private static let legacyFormatVersion = 2
    private static let accessRefreshInterval: TimeInterval = 24 * 60 * 60

    private let cacheFileURLOverride: URL?
    private let limits: DerivedCacheLimits
    private let now: @Sendable () -> Date
    private let saveDebounce: TimeInterval
    private let maximumSaveLatency: TimeInterval

    init(
        cacheFileURLOverride: URL? = nil,
        limits: DerivedCacheLimits = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        saveDebounce: TimeInterval = 0.75,
        maximumSaveLatency: TimeInterval = 5
    ) {
        self.cacheFileURLOverride = cacheFileURLOverride
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
        removeEntryWithoutLoading(for: url)
    }

    func removeAll() {
        loadIfNeeded()
        guard !entries.isEmpty else { return }
        pendingPrunedEntryCount += entries.count
        entries.removeAll(keepingCapacity: false)
        recordMutation()
    }

    @discardableResult
    func flushPersistence() -> Result<DerivedCacheFlushReport, DerivedCachePersistenceError> {
        loadIfNeeded()
        return flushPersistenceInternal(cancelPending: true, retryOnFailure: false)
    }

    @discardableResult
    func clearPersistence() -> Result<DerivedCacheClearReport, DerivedCachePersistenceError> {
        loadIfNeeded()
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

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

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
        if let cacheFileURLOverride { return cacheFileURLOverride }
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("MusicPlayer", isDirectory: true)
            .appendingPathComponent(Self.cacheFileName, isDirectory: false)
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
            "musicplayer-duration-cache-\(process.processIdentifier).json",
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
