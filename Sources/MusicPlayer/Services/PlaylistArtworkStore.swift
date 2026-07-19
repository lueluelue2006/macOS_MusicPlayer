import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads bounded playlist-cover thumbnails and persists user-selected artwork.
/// Custom JPEGs are user assets; they are never treated as disposable caches.
actor PlaylistArtworkStore {
  static let shared = PlaylistArtworkStore()

  struct ArtworkRemovalTicket: Hashable, Sendable {
    fileprivate let id: UUID
    let playlistID: UserPlaylist.ID
  }

  enum ArtworkError: LocalizedError {
    case unreadableImage
    case encodingFailed
    case storageUnavailable
    case removalTransactionFailed

    var errorDescription: String? {
      switch self {
      case .unreadableImage:
        return "无法读取这张图片"
      case .encodingFailed:
        return "无法处理这张图片"
      case .storageUnavailable:
        return "无法访问歌单封面存储目录"
      case .removalTransactionFailed:
        return "无法安全清理歌单封面"
      }
    }
  }

  private let fileManager: FileManager
  private let customDirectoryOverride: URL?
  private let bundledDirectoryOverride: URL?
  private let replacementValidationHook: (@Sendable () throws -> Void)?
  private let imageCache = NSCache<NSString, CGImage>()
  private var failedSourceSignatures = Set<String>()
  private var failedSourceSignatureOrder: [String] = []
  private var didRecoverInterruptedRemovals = false
  private var recoveryFailureCount = 0
  private var recoveryRetryNotBefore = Date.distantPast
  private var deletedPlaylistIDs = Set<UserPlaylist.ID>()
  private var deletedPlaylistIDOrder: [UserPlaylist.ID] = []

  private static let failedSourceLimit = 32
  private static let maximumSourceBytes = 32 * 1_024 * 1_024
  private static let maximumPersistedJPEGBytes = 8 * 1_024 * 1_024
  private static let maximumSourcePixelDimension = 16_384
  private static let maximumSourcePixelCount = 64_000_000
  private static let maximumImageFrameCount = 256
  private static let maximumPendingRemovalCount = 256
  private static let maximumRecoveryConflictCount = 256
  private static let maximumTemporaryFileCount = 4
  private static let maximumDeletedPlaylistTombstones = 4_096
  private static let pendingDirectoryName = ".PendingDeletion"
  private static let recoveryConflictDirectoryName = ".RecoveryConflicts"
  private static let temporaryFilenamePrefix = ".artwork-tmp-"
  private static let deletionFilenamePrefix = ".artwork-delete-"

  init(
    fileManager: FileManager = .default,
    customDirectoryOverride: URL? = nil,
    bundledDirectoryOverride: URL? = nil,
    replacementValidationHook: (@Sendable () throws -> Void)? = nil
  ) {
    self.fileManager = fileManager
    self.customDirectoryOverride = customDirectoryOverride
    self.bundledDirectoryOverride = bundledDirectoryOverride
    self.replacementValidationHook = replacementValidationHook
    imageCache.countLimit = 16
    imageCache.totalCostLimit = 8 * 1_024 * 1_024
  }

  func image(for playlist: UserPlaylist, targetPixelSize: Int) -> CGImage? {
    recoverInterruptedRemovalsIfNeeded()
    let pixelSize = min(max(targetPixelSize, 48), 512)

    for source in sourceCandidates(for: playlist) {
      let signature = cacheKey(
        for: source.url,
        pixelSize: pixelSize,
        allowRootOwner: source.allowRootOwner
      )
      if let cached = imageCache.object(forKey: signature as NSString) {
        return cached
      }
      if failedSourceSignatures.contains(signature) {
        continue
      }

      guard let image = Self.downsampleImage(
        at: source.url,
        maxPixelSize: pixelSize,
        allowRootOwner: source.allowRootOwner
      ) else {
        rememberFailedSource(signature)
        continue
      }

      imageCache.setObject(
        image,
        forKey: signature as NSString,
        cost: image.bytesPerRow * image.height
      )
      return image
    }
    return nil
  }

  func hasCustomArtwork(for playlistID: UserPlaylist.ID) -> Bool {
    recoverInterruptedRemovalsIfNeeded()
    guard let url = customArtworkURL(for: playlistID, createDirectory: false) else { return false }
    guard case .regular = Self.regularFileStatus(at: url),
      chmod(url.path, mode_t(0o600)) == 0
    else { return false }
    return true
  }

  func clearMemoryCache() {
    imageCache.removeAllObjects()
    failedSourceSignatures.removeAll(keepingCapacity: false)
    failedSourceSignatureOrder.removeAll(keepingCapacity: false)
  }

  func importArtwork(from sourceURL: URL, for playlistID: UserPlaylist.ID) throws {
    recoverInterruptedRemovalsIfNeeded()
    guard !deletedPlaylistIDs.contains(playlistID) else {
      throw ArtworkError.removalTransactionFailed
    }
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed { sourceURL.stopAccessingSecurityScopedResource() }
    }

    guard let image = Self.downsampleImage(
      at: sourceURL,
      maxPixelSize: 1_024,
      allowAnyReadableOwner: true
    ) else {
      throw ArtworkError.unreadableImage
    }
    guard let jpegData = Self.jpegData(from: image, quality: 0.86) else {
      throw ArtworkError.encodingFailed
    }
    guard jpegData.count <= Self.maximumPersistedJPEGBytes else {
      throw ArtworkError.encodingFailed
    }
    guard let destinationURL = customArtworkURL(for: playlistID, createDirectory: true) else {
      throw ArtworkError.storageUnavailable
    }

    do {
      try persistJPEG(jpegData, to: destinationURL)
    } catch {
      PersistenceLogger.log("写入歌单封面失败：\(error.localizedDescription)")
      throw ArtworkError.storageUnavailable
    }
    clearMemoryCache()
  }

  /// A durable playlist deletion installs an in-process tombstone before
  /// removing artwork. A delayed import task can therefore never recreate an
  /// orphan cover after the deletion cleanup has already completed.
  func removeArtworkForDeletedPlaylist(_ playlistID: UserPlaylist.ID) throws {
    if deletedPlaylistIDs.insert(playlistID).inserted {
      deletedPlaylistIDOrder.append(playlistID)
      if deletedPlaylistIDOrder.count > Self.maximumDeletedPlaylistTombstones {
        let removed = deletedPlaylistIDOrder.removeFirst()
        deletedPlaylistIDs.remove(removed)
      }
    }
    try removeCustomArtwork(for: playlistID)
  }

  /// Explicit reset is an intentional user action against the artwork itself,
  /// so it may commit immediately instead of coordinating with playlist JSON.
  func removeCustomArtwork(for playlistID: UserPlaylist.ID) throws {
    recoverInterruptedRemovalsIfNeeded()
    guard let url = customArtworkURL(for: playlistID, createDirectory: false) else {
      throw ArtworkError.storageUnavailable
    }
    switch Self.regularFileStatus(at: url) {
    case .missing:
      return
    case .regular:
      do {
        try durablyRemoveRegularFile(at: url)
      } catch {
        throw ArtworkError.removalTransactionFailed
      }
    case .invalid:
      throw ArtworkError.removalTransactionFailed
    }
    clearMemoryCache()
  }

  /// Phase 1 of playlist deletion. The user asset is moved atomically to a
  /// durable staging location before the playlist snapshot changes.
  func stageCustomArtworkRemoval(
    for playlistID: UserPlaylist.ID
  ) throws -> ArtworkRemovalTicket? {
    recoverInterruptedRemovalsIfNeeded()
    guard let sourceURL = customArtworkURL(for: playlistID, createDirectory: false) else {
      throw ArtworkError.storageUnavailable
    }
    switch Self.regularFileStatus(at: sourceURL) {
    case .missing:
      return nil
    case .regular:
      break
    case .invalid:
      throw ArtworkError.removalTransactionFailed
    }
    guard let pendingDirectory = pendingRemovalDirectory(create: true) else {
      throw ArtworkError.storageUnavailable
    }
    do {
      let entries = try boundedDirectoryEntries(
        at: pendingDirectory,
        maximumEntries: Self.maximumPendingRemovalCount
      )
      guard entries.count < Self.maximumPendingRemovalCount else {
        throw ArtworkError.removalTransactionFailed
      }
    } catch let error as ArtworkError {
      throw error
    } catch {
      throw ArtworkError.removalTransactionFailed
    }

    let ticket = ArtworkRemovalTicket(id: UUID(), playlistID: playlistID)
    let stagedURL = stagedArtworkURL(for: ticket, directory: pendingDirectory)
    do {
      try durableMove(sourceURL, to: stagedURL, rollbackOnSyncFailure: true)
    } catch {
      throw ArtworkError.removalTransactionFailed
    }
    clearMemoryCache()
    return ticket
  }

  /// Phase 2 after the playlist deletion has durably succeeded.
  func commitCustomArtworkRemoval(_ ticket: ArtworkRemovalTicket) throws {
    didRecoverInterruptedRemovals = true
    guard let directory = pendingRemovalDirectory(create: false) else {
      throw ArtworkError.storageUnavailable
    }
    let stagedURL = stagedArtworkURL(for: ticket, directory: directory)
    switch Self.regularFileStatus(at: stagedURL) {
    case .missing:
      return
    case .regular:
      do {
        try durablyRemoveRegularFile(at: stagedURL)
      } catch {
        throw ArtworkError.removalTransactionFailed
      }
    case .invalid:
      throw ArtworkError.removalTransactionFailed
    }
    clearMemoryCache()
  }

  /// Rolls phase 1 back when playlist persistence fails. A newer destination
  /// is never overwritten; the staged user asset is retained as a conflict.
  func rollbackCustomArtworkRemoval(_ ticket: ArtworkRemovalTicket) throws {
    didRecoverInterruptedRemovals = true
    guard let pendingDirectory = pendingRemovalDirectory(create: false) else {
      throw ArtworkError.storageUnavailable
    }
    let stagedURL = stagedArtworkURL(for: ticket, directory: pendingDirectory)
    switch Self.regularFileStatus(at: stagedURL) {
    case .missing:
      return
    case .regular:
      break
    case .invalid:
      throw ArtworkError.removalTransactionFailed
    }
    guard let originalURL = customArtworkURL(for: ticket.playlistID, createDirectory: true) else {
      throw ArtworkError.storageUnavailable
    }

    do {
      switch Self.regularFileStatus(at: originalURL) {
      case .regular:
        try moveToRecoveryConflict(stagedURL, playlistID: ticket.playlistID)
      case .missing:
        try durableMove(stagedURL, to: originalURL, rollbackOnSyncFailure: true)
      case .invalid:
        throw ArtworkError.removalTransactionFailed
      }
    } catch {
      throw ArtworkError.removalTransactionFailed
    }
    clearMemoryCache()
  }

  /// Restores tickets left by a process interruption. If playlist deletion had
  /// already succeeded this can leave an orphan JPEG, which is preferable to
  /// destroying a user-selected asset without proof of durable deletion.
  @discardableResult
  func recoverInterruptedRemovalTransactions() throws -> Int {
    guard let pendingDirectory = pendingRemovalDirectory(create: false) else {
      throw ArtworkError.storageUnavailable
    }

    let stagedFiles: [URL]
    do {
      stagedFiles = try boundedDirectoryEntries(
        at: pendingDirectory,
        maximumEntries: Self.maximumPendingRemovalCount
      )
    } catch let error as POSIXDirectoryError where error.code == ENOENT {
      didRecoverInterruptedRemovals = true
      recoveryFailureCount = 0
      recoveryRetryNotBefore = .distantPast
      return 0
    } catch {
      throw ArtworkError.removalTransactionFailed
    }

    var recoveredCount = 0
    recoveryLoop: for stagedURL in stagedFiles
      where stagedURL.pathExtension.lowercased() == "jpg"
    {
      guard let playlistID = Self.playlistID(fromStagedFilename: stagedURL.lastPathComponent),
        let originalURL = customArtworkURL(for: playlistID, createDirectory: true)
      else { continue }

      do {
        switch Self.regularFileStatus(at: stagedURL) {
        case .missing:
          continue recoveryLoop
        case .regular:
          break
        case .invalid:
          throw ArtworkError.removalTransactionFailed
        }
        switch Self.regularFileStatus(at: originalURL) {
        case .regular:
          try moveToRecoveryConflict(stagedURL, playlistID: playlistID)
        case .missing:
          try durableMove(stagedURL, to: originalURL, rollbackOnSyncFailure: true)
        case .invalid:
          throw ArtworkError.removalTransactionFailed
        }
        recoveredCount += 1
        clearMemoryCache()
      } catch {
        throw ArtworkError.removalTransactionFailed
      }
    }
    didRecoverInterruptedRemovals = true
    recoveryFailureCount = 0
    recoveryRetryNotBefore = .distantPast
    return recoveredCount
  }

  static func bundledFilename(forPlaylistName name: String) -> String? {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized {
    case "杨坤", "楊坤":
      return "yang-kun.png"
    case "费玉清", "費玉清":
      return "fei-yu-ching.png"
    case "孙燕姿", "孫燕姿":
      return "stefanie-sun.png"
    case "王菲":
      return "faye-wong.png"
    default:
      return nil
    }
  }

  private func recoverInterruptedRemovalsIfNeeded() {
    guard !didRecoverInterruptedRemovals,
      Date() >= recoveryRetryNotBefore
    else { return }
    do {
      _ = try recoverInterruptedRemovalTransactions()
    } catch {
      recoveryFailureCount = min(recoveryFailureCount + 1, 4)
      let delays: [TimeInterval] = [1, 5, 30, 120]
      recoveryRetryNotBefore = Date().addingTimeInterval(delays[recoveryFailureCount - 1])
      PersistenceLogger.log("恢复中断的歌单封面清理失败：\(error.localizedDescription)")
    }
  }

  private struct ArtworkSource {
    let url: URL
    let allowRootOwner: Bool
  }

  private func sourceCandidates(for playlist: UserPlaylist) -> [ArtworkSource] {
    var candidates: [ArtworkSource] = []
    if let customURL = customArtworkURL(for: playlist.id, createDirectory: false),
      case .regular = Self.regularFileStatus(at: customURL),
      chmod(customURL.path, mode_t(0o600)) == 0
    {
      candidates.append(ArtworkSource(url: customURL, allowRootOwner: false))
    }
    if let bundledURL = bundledArtworkURL(forPlaylistName: playlist.name) {
      candidates.append(ArtworkSource(url: bundledURL, allowRootOwner: true))
    }
    return candidates
  }

  private func bundledArtworkURL(forPlaylistName name: String) -> URL? {
    guard let filename = Self.bundledFilename(forPlaylistName: name) else { return nil }
    let directory = bundledDirectoryOverride
      ?? Bundle.main.resourceURL?.appendingPathComponent("PlaylistCovers", isDirectory: true)
    guard let url = directory?.appendingPathComponent(filename, isDirectory: false),
      case .regular = Self.regularFileStatus(at: url, allowRootOwner: true)
    else { return nil }
    return url
  }

  private func customArtworkDirectory(create: Bool) -> URL? {
    let directory: URL
    if let customDirectoryOverride {
      directory = customDirectoryOverride
    } else {
      guard let base = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first else { return nil }
      directory = base
        .appendingPathComponent("MusicPlayer", isDirectory: true)
        .appendingPathComponent("PlaylistArtwork", isDirectory: true)
    }

    return secureDirectory(directory, create: create) ? directory : nil
  }

  private func customArtworkURL(
    for playlistID: UserPlaylist.ID,
    createDirectory: Bool
  ) -> URL? {
    customArtworkDirectory(create: createDirectory)?.appendingPathComponent(
      "\(playlistID.uuidString).jpg",
      isDirectory: false
    )
  }

  private func pendingRemovalDirectory(create: Bool) -> URL? {
    guard let customDirectory = customArtworkDirectory(create: create) else { return nil }
    let directory = customDirectory.appendingPathComponent(
      Self.pendingDirectoryName,
      isDirectory: true
    )
    return secureDirectory(directory, create: create) ? directory : nil
  }

  private func recoveryConflictDirectory(create: Bool) -> URL? {
    guard let customDirectory = customArtworkDirectory(create: create) else { return nil }
    let directory = customDirectory.appendingPathComponent(
      Self.recoveryConflictDirectoryName,
      isDirectory: true
    )
    return secureDirectory(directory, create: create) ? directory : nil
  }

  private func stagedArtworkURL(
    for ticket: ArtworkRemovalTicket,
    directory: URL
  ) -> URL {
    directory.appendingPathComponent(
      "\(ticket.playlistID.uuidString)--\(ticket.id.uuidString).jpg",
      isDirectory: false
    )
  }

  private static func playlistID(fromStagedFilename filename: String) -> UserPlaylist.ID? {
    let stem = (filename as NSString).deletingPathExtension
    guard let separator = stem.range(of: "--") else { return nil }
    return UUID(uuidString: String(stem[..<separator.lowerBound]))
  }

  private func moveToRecoveryConflict(
    _ sourceURL: URL,
    playlistID: UserPlaylist.ID
  ) throws {
    guard let directory = recoveryConflictDirectory(create: true) else {
      throw ArtworkError.storageUnavailable
    }
    let entries = try boundedDirectoryEntries(
      at: directory,
      maximumEntries: Self.maximumRecoveryConflictCount
    )
    guard entries.count < Self.maximumRecoveryConflictCount else {
      throw ArtworkError.removalTransactionFailed
    }
    let destination = directory.appendingPathComponent(
      "\(playlistID.uuidString)--\(UUID().uuidString).jpg",
      isDirectory: false
    )
    try durableMove(sourceURL, to: destination, rollbackOnSyncFailure: true)
  }

  private enum RegularFileStatus {
    case missing
    case regular(stat)
    case invalid(Int32)
  }

  private struct POSIXDirectoryError: Error {
    let code: Int32
  }

  private nonisolated static func regularFileStatus(
    at url: URL,
    allowRootOwner: Bool = false
  ) -> RegularFileStatus {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      return errno == ENOENT ? .missing : .invalid(errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG,
      (info.st_uid == geteuid() || (allowRootOwner && info.st_uid == 0)),
      info.st_size >= 0
    else {
      return .invalid(EINVAL)
    }
    return .regular(info)
  }

  private func secureDirectory(_ directory: URL, create: Bool) -> Bool {
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { return false }
      guard create else { return true }
      do {
        try fileManager.createDirectory(
          at: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        return false
      }
      guard lstat(directory.path, &info) == 0 else { return false }
      do {
        try Self.synchronizeDirectory(directory.deletingLastPathComponent())
      } catch {
        return false
      }
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == geteuid(),
      chmod(directory.path, mode_t(0o700)) == 0
    else {
      return false
    }
    return true
  }

  private func boundedDirectoryEntries(
    at directory: URL,
    maximumEntries: Int
  ) throws -> [URL] {
    guard let stream = opendir(directory.path) else {
      throw POSIXDirectoryError(code: errno)
    }
    defer { closedir(stream) }

    var result: [URL] = []
    result.reserveCapacity(min(maximumEntries, 64))
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        if errno != 0 {
          throw POSIXDirectoryError(code: errno)
        }
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      guard result.count < maximumEntries else {
        throw POSIXDirectoryError(code: EOVERFLOW)
      }
      result.append(directory.appendingPathComponent(name, isDirectory: false))
    }
    return result
  }

  private func persistJPEG(_ data: Data, to destinationURL: URL) throws {
    guard data.count <= Self.maximumPersistedJPEGBytes else {
      throw ArtworkError.encodingFailed
    }
    let directory = destinationURL.deletingLastPathComponent()
    guard secureDirectory(directory, create: true) else {
      throw ArtworkError.storageUnavailable
    }
    cleanupTemporaryFiles(in: directory)

    let temporaryURL = directory.appendingPathComponent(
      "\(Self.temporaryFilenamePrefix)\(UUID().uuidString)",
      isDirectory: false
    )
    try Self.writeSecureFile(data, to: temporaryURL)
    var temporaryExists = true
    defer {
      if temporaryExists {
        _ = temporaryURL.path.withCString { unlink($0) }
      }
    }

    switch Self.regularFileStatus(at: destinationURL) {
    case .missing:
      guard renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXDirectoryError(code: errno)
      }
      temporaryExists = false
      do {
        try Self.synchronizeDirectory(directory)
      } catch {
        _ = destinationURL.path.withCString { unlink($0) }
        try? Self.synchronizeDirectory(directory)
        throw error
      }

    case .regular(let originalInfo):
      guard renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP)) == 0 else {
        throw POSIXDirectoryError(code: errno)
      }
      do {
        guard case .regular(let swappedInfo) = Self.regularFileStatus(at: temporaryURL),
          Self.sameFile(originalInfo, swappedInfo)
        else {
          throw POSIXDirectoryError(code: EBUSY)
        }
        try replacementValidationHook?()
        try Self.synchronizeDirectory(directory)
      } catch {
        if renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP)) == 0 {
          try? Self.synchronizeDirectory(directory)
        } else {
          // The previous image is still at the temporary path. Keep it for
          // bounded cleanup/recovery instead of unlinking the only old copy.
          temporaryExists = false
        }
        throw error
      }

      // The destination is durably committed. Failure to unlink the swapped-out
      // predecessor leaves a bounded private transaction file, never a lost cover.
      if temporaryURL.path.withCString({ unlink($0) }) == 0 || errno == ENOENT {
        temporaryExists = false
        try? Self.synchronizeDirectory(directory)
      } else {
        PersistenceLogger.log("清理旧歌单封面临时文件失败：\(Self.errorText(errno))")
        temporaryExists = false
      }

    case .invalid:
      throw POSIXDirectoryError(code: EINVAL)
    }
    cleanupTemporaryFiles(in: directory)
  }

  private func durableMove(
    _ sourceURL: URL,
    to destinationURL: URL,
    rollbackOnSyncFailure: Bool
  ) throws {
    guard case .regular(let originalInfo) = Self.regularFileStatus(at: sourceURL),
      case .missing = Self.regularFileStatus(at: destinationURL),
      chmod(sourceURL.path, mode_t(0o600)) == 0,
      renamex_np(sourceURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0
    else {
      throw POSIXDirectoryError(code: errno == 0 ? EINVAL : errno)
    }
    guard case .regular(let movedInfo) = Self.regularFileStatus(at: destinationURL),
      Self.sameFile(originalInfo, movedInfo)
    else {
      _ = renamex_np(destinationURL.path, sourceURL.path, UInt32(RENAME_EXCL))
      throw POSIXDirectoryError(code: EBUSY)
    }

    let sourceDirectory = sourceURL.deletingLastPathComponent()
    let destinationDirectory = destinationURL.deletingLastPathComponent()
    do {
      try Self.synchronizeDirectory(destinationDirectory)
      if sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL {
        try Self.synchronizeDirectory(sourceDirectory)
      }
    } catch {
      if rollbackOnSyncFailure,
        renamex_np(destinationURL.path, sourceURL.path, UInt32(RENAME_EXCL)) == 0
      {
        try? Self.synchronizeDirectory(sourceDirectory)
        if sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL {
          try? Self.synchronizeDirectory(destinationDirectory)
        }
      }
      throw error
    }
  }

  private func durablyRemoveRegularFile(at sourceURL: URL) throws {
    guard case .regular(let originalInfo) = Self.regularFileStatus(at: sourceURL) else {
      if case .missing = Self.regularFileStatus(at: sourceURL) { return }
      throw POSIXDirectoryError(code: EINVAL)
    }
    let directory = sourceURL.deletingLastPathComponent()
    let deletionURL = directory.appendingPathComponent(
      "\(Self.deletionFilenamePrefix)\(UUID().uuidString)",
      isDirectory: false
    )
    guard renamex_np(sourceURL.path, deletionURL.path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == ENOENT { return }
      throw POSIXDirectoryError(code: errno)
    }
    guard case .regular(let movedInfo) = Self.regularFileStatus(at: deletionURL),
      Self.sameFile(originalInfo, movedInfo)
    else {
      _ = renamex_np(deletionURL.path, sourceURL.path, UInt32(RENAME_EXCL))
      throw POSIXDirectoryError(code: EBUSY)
    }
    do {
      try Self.synchronizeDirectory(directory)
    } catch {
      if renamex_np(deletionURL.path, sourceURL.path, UInt32(RENAME_EXCL)) == 0 {
        try? Self.synchronizeDirectory(directory)
      }
      throw error
    }

    if deletionURL.path.withCString({ unlink($0) }) != 0, errno != ENOENT {
      PersistenceLogger.log("清理歌单封面删除事务失败：\(Self.errorText(errno))")
    } else {
      try? Self.synchronizeDirectory(directory)
    }
    cleanupTemporaryFiles(in: directory)
  }

  private func cleanupTemporaryFiles(in directory: URL) {
    guard let entries = try? boundedDirectoryEntries(at: directory, maximumEntries: 4_096) else {
      return
    }
    let candidates = entries.filter {
      let name = $0.lastPathComponent
      return name.hasPrefix(Self.temporaryFilenamePrefix)
        || name.hasPrefix(Self.deletionFilenamePrefix)
    }
    guard candidates.count > Self.maximumTemporaryFileCount else { return }

    let sorted = candidates.sorted { lhs, rhs in
      let left = Self.regularFileModificationTime(at: lhs)
      let right = Self.regularFileModificationTime(at: rhs)
      if left == right { return lhs.lastPathComponent < rhs.lastPathComponent }
      return left < right
    }
    var removedAny = false
    for candidate in sorted.prefix(candidates.count - Self.maximumTemporaryFileCount) {
      guard case .regular = Self.regularFileStatus(at: candidate) else { continue }
      if candidate.path.withCString({ unlink($0) }) == 0 {
        removedAny = true
      }
    }
    if removedAny {
      try? Self.synchronizeDirectory(directory)
    }
  }

  private nonisolated static func writeSecureFile(_ data: Data, to url: URL) throws {
    let descriptor = Darwin.open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard descriptor >= 0 else { throw POSIXDirectoryError(code: errno) }
    var shouldRemove = true
    defer {
      Darwin.close(descriptor)
      if shouldRemove {
        _ = url.path.withCString { unlink($0) }
      }
    }

    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw POSIXDirectoryError(code: errno)
        }
        guard count > 0 else { throw POSIXDirectoryError(code: EIO) }
        offset += count
      }
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0,
      fsync(descriptor) == 0
    else {
      throw POSIXDirectoryError(code: errno)
    }
    shouldRemove = false
  }

  private nonisolated static func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(
      directory.path,
      O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw POSIXDirectoryError(code: errno) }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXDirectoryError(code: errno) }
  }

  private nonisolated static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private nonisolated static func regularFileModificationTime(at url: URL) -> Int64 {
    guard case .regular(let info) = regularFileStatus(at: url) else { return Int64.min }
    return Int64(info.st_mtimespec.tv_sec)
  }

  private nonisolated static func errorText(_ code: Int32) -> String {
    String(cString: strerror(code))
  }

  private func cacheKey(for url: URL, pixelSize: Int, allowRootOwner: Bool) -> String {
    guard case .regular(let info) = Self.regularFileStatus(
      at: url,
      allowRootOwner: allowRootOwner
    ) else {
      return "\(url.path)|\(pixelSize)|invalid"
    }
    return "\(url.path)|\(pixelSize)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_size)|\(info.st_ino)"
  }

  private func rememberFailedSource(_ signature: String) {
    guard failedSourceSignatures.insert(signature).inserted else { return }
    failedSourceSignatureOrder.append(signature)
    while failedSourceSignatureOrder.count > Self.failedSourceLimit {
      let oldest = failedSourceSignatureOrder.removeFirst()
      failedSourceSignatures.remove(oldest)
    }
  }

  private nonisolated static func downsampleImage(
    at url: URL,
    maxPixelSize: Int,
    allowRootOwner: Bool = false,
    allowAnyReadableOwner: Bool = false
  ) -> CGImage? {
    guard maxPixelSize > 0,
      let data = try? readBoundedRegularFile(
        at: url,
        maximumBytes: maximumSourceBytes,
        allowRootOwner: allowRootOwner,
        allowAnyReadableOwner: allowAnyReadableOwner
      )
    else {
      return nil
    }
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldAllowFloat: false,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      CGImageSourceGetCount(source) <= maximumImageFrameCount,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = Self.positivePixelDimension(properties[kCGImagePropertyPixelWidth]),
      let height = Self.positivePixelDimension(properties[kCGImagePropertyPixelHeight]),
      width <= maximumSourcePixelDimension,
      height <= maximumSourcePixelDimension,
      width <= maximumSourcePixelCount / height
    else {
      return nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldAllowFloat: false,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  private nonisolated static func readBoundedRegularFile(
    at url: URL,
    maximumBytes: Int,
    allowRootOwner: Bool,
    allowAnyReadableOwner: Bool
  ) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXDirectoryError(code: errno) }
    defer { Darwin.close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      ownerIsAllowed(
        info.st_uid,
        allowRootOwner: allowRootOwner,
        allowAnyReadableOwner: allowAnyReadableOwner
      ),
      info.st_size >= 0,
      info.st_size <= maximumBytes
    else {
      throw POSIXDirectoryError(code: EINVAL)
    }

    var data = Data()
    data.reserveCapacity(min(Int(info.st_size), maximumBytes))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXDirectoryError(code: errno)
      }
      guard data.count <= maximumBytes - count else {
        throw POSIXDirectoryError(code: EFBIG)
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  static func ownerIsAllowed(
    _ ownerUID: uid_t,
    allowRootOwner: Bool,
    allowAnyReadableOwner: Bool
  ) -> Bool {
    allowAnyReadableOwner
      || ownerUID == geteuid()
      || (allowRootOwner && ownerUID == 0)
  }

  private nonisolated static func positivePixelDimension(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let dimension = number.int64Value
    guard dimension > 0, dimension <= Int64(Int.max) else { return nil }
    return Int(dimension)
  }

  private nonisolated static func jpegData(
    from image: CGImage,
    quality: CGFloat
  ) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else { return nil }

    let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
