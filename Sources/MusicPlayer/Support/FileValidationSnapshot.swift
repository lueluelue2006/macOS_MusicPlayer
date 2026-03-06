import Foundation

struct FileValidationSnapshot: Sendable, Equatable {
    let exists: Bool
    let fileSize: Int64
    let mtimeNs: Int64
    let inode: Int64?

    static let missing = FileValidationSnapshot(exists: false, fileSize: 0, mtimeNs: 0, inode: nil)

    static func load(for url: URL, fileManager: FileManager = .default) -> FileValidationSnapshot {
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let size = values.fileSize, let mtime = values.contentModificationDate else {
                return .missing
            }

            let inode: Int64? = {
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                if let n = attrs?[.systemFileNumber] as? NSNumber {
                    return n.int64Value
                }
                if let n = attrs?[.systemFileNumber] as? Int {
                    return Int64(n)
                }
                return nil
            }()

            return FileValidationSnapshot(
                exists: true,
                fileSize: Int64(size),
                mtimeNs: Int64((mtime.timeIntervalSince1970 * 1_000_000_000.0).rounded()),
                inode: inode
            )
        } catch {
            return .missing
        }
    }
}
