import Foundation
import Darwin

enum DerivedCachePersistenceError: Error, Equatable, LocalizedError, Sendable {
    case storageUnavailable
    case readFailed(String)
    case quarantineFailed(String)
    case encodeFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "缓存存储目录不可用"
        case .readFailed(let detail):
            return "无法读取缓存：\(detail)"
        case .quarantineFailed(let detail):
            return "无法隔离旧缓存：\(detail)"
        case .encodeFailed(let detail):
            return "无法编码缓存：\(detail)"
        case .writeFailed(let detail):
            return "无法写入缓存：\(detail)"
        }
    }
}

struct DerivedCacheFlushReport: Equatable, Sendable {
    let wroteFile: Bool
    let entryCount: Int
    let prunedEntryCount: Int
}

struct DerivedCacheClearReport: Equatable, Sendable {
    let removedEntryCount: Int
    let quarantinedFileCount: Int
}

struct DerivedCacheLimits: Equatable, Sendable {
    static let standard = DerivedCacheLimits(
        maximumEntries: 8_192,
        lowWatermark: 7_168,
        maximumFileBytes: 8 * 1_024 * 1_024
    )

    let maximumEntries: Int
    let lowWatermark: Int
    let maximumFileBytes: Int

    init(maximumEntries: Int, lowWatermark: Int, maximumFileBytes: Int) {
        let maximumEntries = max(1, maximumEntries)
        self.maximumEntries = maximumEntries
        self.lowWatermark = min(max(0, lowWatermark), maximumEntries)
        self.maximumFileBytes = max(1_024, maximumFileBytes)
    }
}

enum DerivedCacheQuarantineReason: Equatable, Sendable {
    case corrupt
    case oversized
    case future(version: Int)
    case legacy(version: Int)

    fileprivate var fileComponent: String {
        switch self {
        case .corrupt:
            return "corrupt"
        case .oversized:
            return "oversized"
        case .future(let version):
            return "future-v\(version)"
        case .legacy(let version):
            return "legacy-v\(version)"
        }
    }
}

enum DerivedCacheFileIO {
    static let quarantineDirectoryName = "CacheQuarantine"
    static let maximumQuarantineFilesPerCache = 2

    static func ensureParentDirectory(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        var priorInfo = stat()
        let directoryAlreadyExisted = lstat(directory.path, &priorInfo) == 0
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DerivedCachePersistenceError.storageUnavailable
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              chmod(directory.path, mode_t(0o700)) == 0 else {
            throw DerivedCachePersistenceError.storageUnavailable
        }
        if !directoryAlreadyExisted {
            do {
                try synchronizeDirectory(directory.deletingLastPathComponent())
            } catch {
                throw DerivedCachePersistenceError.storageUnavailable
            }
        }
    }

    static func fileSize(at url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw DerivedCachePersistenceError.readFailed("文件类型不安全")
        }
        let size = Int64(info.st_size)
        guard size >= 0, size <= Int64(Int.max) else { return Int.max }
        return Int(size)
    }

    static func readBoundedRegularFile(
        at url: URL,
        maximumBytes: Int,
        requireCurrentUserOwner: Bool = true
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw DerivedCachePersistenceError.readFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (!requireCurrentUserOwner || info.st_uid == geteuid()),
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw DerivedCachePersistenceError.readFailed("文件过大、所有者错误或类型不安全")
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
                throw DerivedCachePersistenceError.readFailed(String(cString: strerror(errno)))
            }
            guard data.count <= maximumBytes - count else {
                throw DerivedCachePersistenceError.readFailed("缓存文件在读取期间超过容量上限")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureParentDirectory(for: url)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DerivedCachePersistenceError.writeFailed(String(cString: strerror(errno)))
        }
        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = temporaryURL.path.withCString { unlink($0) }
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(
                        descriptor,
                        rawBuffer.baseAddress?.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw DerivedCachePersistenceError.writeFailed(
                            String(cString: strerror(errno))
                        )
                    }
                    guard written > 0 else {
                        throw DerivedCachePersistenceError.writeFailed("缓存写入未取得进展")
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0,
                  rename(temporaryURL.path, url.path) == 0 else {
                throw DerivedCachePersistenceError.writeFailed(String(cString: strerror(errno)))
            }
            shouldRemoveTemporaryFile = false
            guard chmod(url.path, mode_t(0o600)) == 0 else {
                throw DerivedCachePersistenceError.writeFailed(String(cString: strerror(errno)))
            }
            try synchronizeDirectory(directory)
        } catch let error as DerivedCachePersistenceError {
            throw error
        } catch {
            throw DerivedCachePersistenceError.writeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    static func quarantine(
        _ sourceURL: URL,
        reason: DerivedCacheQuarantineReason,
        now: Date = Date()
    ) throws -> URL {
        let fileManager = FileManager.default
        let parent = sourceURL.deletingLastPathComponent()
        let directory = parent.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  chmod(directory.path, mode_t(0o700)) == 0 else {
                throw DerivedCachePersistenceError.storageUnavailable
            }
        } catch {
            throw DerivedCachePersistenceError.quarantineFailed(error.localizedDescription)
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let timestamp = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let filename = "\(stem).\(reason.fileComponent).\(timestamp).\(UUID().uuidString).json"
        let destination = directory.appendingPathComponent(filename, isDirectory: false)

        do {
            var sourceInfo = stat()
            guard lstat(sourceURL.path, &sourceInfo) == 0,
                  (sourceInfo.st_mode & S_IFMT) == S_IFREG,
                  sourceInfo.st_uid == geteuid() else {
                throw DerivedCachePersistenceError.quarantineFailed("源文件类型或所有者不安全")
            }
            try fileManager.moveItem(at: sourceURL, to: destination)
            var destinationInfo = stat()
            if lstat(destination.path, &destinationInfo) == 0,
               (destinationInfo.st_mode & S_IFMT) == S_IFREG {
                guard chmod(destination.path, mode_t(0o600)) == 0 else {
                    throw DerivedCachePersistenceError.quarantineFailed(
                        String(cString: strerror(errno))
                    )
                }
            }
            try synchronizeDirectory(directory)
            try synchronizeDirectory(parent)
        } catch {
            throw DerivedCachePersistenceError.quarantineFailed(error.localizedDescription)
        }

        pruneQuarantineFiles(in: directory, cacheStem: stem, preserving: destination)
        return destination
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DerivedCachePersistenceError.writeFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DerivedCachePersistenceError.writeFailed(String(cString: strerror(errno)))
        }
    }

    private static func pruneQuarantineFiles(
        in directory: URL,
        cacheStem: String,
        preserving preservedURL: URL
    ) {
        let fileManager = FileManager.default
        guard let urls = boundedDirectoryURLs(in: directory, maximumEntries: 4_096) else {
            return
        }

        let matching = urls.filter {
            $0.lastPathComponent.hasPrefix(cacheStem + ".") && $0.pathExtension == "json"
        }
        guard matching.count > maximumQuarantineFilesPerCache else { return }

        let sorted = matching.sorted { lhs, rhs in
            if lhs == preservedURL { return false }
            if rhs == preservedURL { return true }
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if leftDate == rightDate { return lhs.lastPathComponent < rhs.lastPathComponent }
            return leftDate < rightDate
        }

        let removeCount = matching.count - maximumQuarantineFilesPerCache
        for url in sorted.prefix(removeCount) where url != preservedURL {
            try? fileManager.removeItem(at: url)
        }
    }

    static func boundedDirectoryURLs(
        in directory: URL,
        maximumEntries: Int
    ) -> [URL]? {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }
        defer { closedir(stream) }

        var urls: [URL] = []
        urls.reserveCapacity(min(64, maximumEntries))
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(item.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            guard urls.count < maximumEntries else { return nil }
            urls.append(directory.appendingPathComponent(name, isDirectory: false))
        }
        return urls
    }
}

private struct DerivedCacheDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct DerivedCacheLossyDictionary<Value: Decodable>: Decodable {
    let values: [String: Value]
    let rejectedValueCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DerivedCacheDynamicCodingKey.self)
        var values: [String: Value] = [:]
        values.reserveCapacity(container.allKeys.count)
        var rejectedValueCount = 0

        for key in container.allKeys {
            do {
                values[key.stringValue] = try container.decode(Value.self, forKey: key)
            } catch {
                rejectedValueCount += 1
            }
        }

        self.values = values
        self.rejectedValueCount = rejectedValueCount
    }
}
