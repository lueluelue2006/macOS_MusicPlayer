import Foundation

/// Service responsible for capturing and validating file signatures.
/// Handles all FileManager and URL resource access with proper error handling and diagnostics.
actor FileIdentity {
    enum Error: Swift.Error {
        case fileNotAccessible(underlying: Swift.Error)
        case missingSizeAttribute
        case missingModificationDate
        case negativeSizeValue(Int64)
        case invalidModificationTime(TimeInterval)
        case unsupportedIdentifierType(key: String, type: String)
    }

    /// Captures a comprehensive file signature from a URL.
    func captureSignature(for url: URL) throws -> FileSignature {
        let fm = FileManager.default
        let canonicalPath = PathKey.canonical(for: url)

        // Get basic attributes
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: url.path)
        } catch {
            throw Error.fileNotAccessible(underlying: error)
        }

        guard let sizeNumber = attrs[.size] as? NSNumber else {
            throw Error.missingSizeAttribute
        }
        let size = sizeNumber.int64Value
        guard size >= 0 else {
            throw Error.negativeSizeValue(size)
        }

        guard let modDate = attrs[.modificationDate] as? Date else {
            throw Error.missingModificationDate
        }
        let modTimeInterval = modDate.timeIntervalSince1970
        guard modTimeInterval.isFinite else {
            throw Error.invalidModificationTime(modTimeInterval)
        }
        let roundedValue = (modTimeInterval * 1_000_000_000).rounded()
        guard let modTimeNs = Int64(exactly: roundedValue) else {
            throw Error.invalidModificationTime(modTimeInterval)
        }

        // Best-effort inode
        let inode: UInt64? = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value

        // Capture resource identifiers in one pass
        let resourceValues = try url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .volumeUUIDStringKey,
            .volumeIdentifierKey
        ])

        let fileResourceId: String? = try resourceValues.fileResourceIdentifier.map {
            try stableIdentifier($0, key: "fileResourceIdentifier")
        }

        // Prefer volumeUUIDString, fallback to volumeIdentifier
        let volumeId: String? = try {
            if let uuidString = resourceValues.volumeUUIDString {
                return uuidString
            }
            return try resourceValues.volumeIdentifier.map {
                try stableIdentifier($0, key: "volumeIdentifier")
            }
        }()

        return FileSignature(
            pathKey: canonicalPath,
            size: size,
            modificationTimeNanoseconds: modTimeNs,
            inode: inode,
            fileResourceIdentifier: fileResourceId,
            volumeIdentifier: volumeId
        )
    }

    /// Validates a signature against the current file state (non-throwing, returns false on mismatch or error).
    func validate(signature: FileSignature, against url: URL) -> Bool {
        guard let current = try? captureSignature(for: url) else {
            return false
        }
        return signature == current
    }

    /// Validates a signature against the current file state (throwing version for diagnostics).
    func validateStrict(signature: FileSignature, against url: URL) throws -> Bool {
        let current = try captureSignature(for: url)
        return signature == current
    }

    // MARK: - Private Helpers

    /// Converts resource identifier to stable string representation.
    private func stableIdentifier(_ value: Any, key: String) throws -> String {
        switch value {
        case let data as Data:
            return data.base64EncodedString()
        case let uuid as UUID:
            return uuid.uuidString
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        default:
            let typeName = String(describing: type(of: value))
            throw Error.unsupportedIdentifierType(key: key, type: typeName)
        }
    }
}
