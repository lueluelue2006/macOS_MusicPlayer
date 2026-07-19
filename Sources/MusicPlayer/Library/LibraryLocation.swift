import Foundation

enum LibraryLocationLimits {
    static let maximumBookmarkBytes = 64 * 1_024
    static let maximumPathBytes = 16 * 1_024
    static let maximumRelativePathComponentBytes = 1_024
    static let maximumDisplayNameBytes = 512
    static let maximumIdentifierBytes = 16 * 1_024
}

enum LibraryLocationKind: String, Codable, Sendable {
    case directory
    case singleFile
}

enum LibraryBookmarkKind: String, Codable, Sendable {
    case securityScoped
    case regular
}

struct LibraryBookmark: Equatable, Sendable {
    let data: Data
    let kind: LibraryBookmarkKind

    init(data: Data, kind: LibraryBookmarkKind) throws {
        guard !data.isEmpty else {
            throw LibraryLocationValidationError.emptyBookmark
        }
        guard data.count <= LibraryLocationLimits.maximumBookmarkBytes else {
            throw LibraryLocationValidationError.bookmarkTooLarge(
                maximumBytes: LibraryLocationLimits.maximumBookmarkBytes
            )
        }
        self.data = data
        self.kind = kind
    }
}

enum LibraryLocationValidationError: Error, Equatable, Sendable {
    case emptyBookmark
    case bookmarkTooLarge(maximumBytes: Int)
    case invalidAbsolutePath
    case pathTooLong(maximumBytes: Int)
    case invalidRelativePath
    case relativePathComponentTooLong(maximumBytes: Int)
    case pathOutsideRoot
    case invalidDisplayName
    case identifierTooLong(maximumBytes: Int)
    case locationKindMismatch
    case locationIdentifierMismatch
}

/// A persistent reference to one user-selected directory or one explicitly
/// selected file. One directory bookmark is shared by every track below that
/// root, keeping persistence bounded for very large libraries.
struct LibraryLocation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: LibraryLocationKind
    let bookmarkData: Data
    let bookmarkKind: LibraryBookmarkKind
    let fallbackPath: String
    let volumeIdentifier: String?
    let volumeRelativeRootPath: String?
    let rootResourceIdentifier: String?
    let displayName: String

    init(
        id: UUID = UUID(),
        kind: LibraryLocationKind,
        bookmarkData: Data,
        bookmarkKind: LibraryBookmarkKind,
        fallbackPath: String,
        volumeIdentifier: String? = nil,
        volumeRelativeRootPath: String? = nil,
        rootResourceIdentifier: String? = nil,
        displayName: String
    ) throws {
        _ = try LibraryBookmark(data: bookmarkData, kind: bookmarkKind)
        let normalizedFallbackPath = try Self.validateAbsolutePath(fallbackPath)
        let normalizedVolumeRelativePath = try volumeRelativeRootPath.map {
            try LibraryRelativePath.validate($0, allowEmpty: true)
        }
        let normalizedVolumeIdentifier = try Self.validateIdentifier(volumeIdentifier)
        let normalizedResourceIdentifier = try Self.validateIdentifier(rootResourceIdentifier)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty,
              normalizedDisplayName.utf8.count <= LibraryLocationLimits.maximumDisplayNameBytes,
              !normalizedDisplayName.utf8.contains(0) else {
            throw LibraryLocationValidationError.invalidDisplayName
        }

        self.id = id
        self.kind = kind
        self.bookmarkData = bookmarkData
        self.bookmarkKind = bookmarkKind
        self.fallbackPath = normalizedFallbackPath
        self.volumeIdentifier = normalizedVolumeIdentifier
        self.volumeRelativeRootPath = normalizedVolumeRelativePath
        self.rootResourceIdentifier = normalizedResourceIdentifier
        self.displayName = normalizedDisplayName
    }

    var fallbackURL: URL {
        URL(fileURLWithPath: fallbackPath, isDirectory: kind == .directory)
    }

    func applying(_ refresh: LibraryBookmarkRefresh) throws -> LibraryLocation {
        guard refresh.locationID == id else {
            throw LibraryLocationValidationError.locationIdentifierMismatch
        }
        return try LibraryLocation(
            id: id,
            kind: kind,
            bookmarkData: refresh.bookmarkData,
            bookmarkKind: refresh.bookmarkKind,
            fallbackPath: refresh.resolvedPath,
            volumeIdentifier: volumeIdentifier,
            volumeRelativeRootPath: refresh.volumeRelativeRootPath,
            rootResourceIdentifier: rootResourceIdentifier,
            displayName: displayName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case bookmarkData
        case bookmarkKind
        case fallbackPath
        case volumeIdentifier
        case volumeRelativeRootPath
        case rootResourceIdentifier
        case displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decode(LibraryLocationKind.self, forKey: .kind),
            bookmarkData: container.decode(Data.self, forKey: .bookmarkData),
            bookmarkKind: container.decode(LibraryBookmarkKind.self, forKey: .bookmarkKind),
            fallbackPath: container.decode(String.self, forKey: .fallbackPath),
            volumeIdentifier: container.decodeIfPresent(String.self, forKey: .volumeIdentifier),
            volumeRelativeRootPath: container.decodeIfPresent(
                String.self,
                forKey: .volumeRelativeRootPath
            ),
            rootResourceIdentifier: container.decodeIfPresent(
                String.self,
                forKey: .rootResourceIdentifier
            ),
            displayName: container.decode(String.self, forKey: .displayName)
        )
    }

    private static func validateAbsolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw LibraryLocationValidationError.invalidAbsolutePath
        }
        guard path.utf8.count <= LibraryLocationLimits.maximumPathBytes else {
            throw LibraryLocationValidationError.pathTooLong(
                maximumBytes: LibraryLocationLimits.maximumPathBytes
            )
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
    }

    private static func validateIdentifier(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.utf8.contains(0) else { return nil }
        guard normalized.utf8.count <= LibraryLocationLimits.maximumIdentifierBytes else {
            throw LibraryLocationValidationError.identifierTooLong(
                maximumBytes: LibraryLocationLimits.maximumIdentifierBytes
            )
        }
        return normalized
    }
}

struct LibraryTrackReference: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let locationID: UUID?
    let relativePath: String?
    let legacyAbsolutePath: String
    let signature: FileSignature?

    init(
        id: UUID = UUID(),
        locationID: UUID?,
        relativePath: String?,
        legacyAbsolutePath: String,
        signature: FileSignature? = nil
    ) throws {
        let normalizedAbsolutePath = try LibraryLocation.validateTrackAbsolutePath(
            legacyAbsolutePath
        )
        let normalizedRelativePath = try relativePath.map {
            try LibraryRelativePath.validate($0, allowEmpty: false)
        }
        if locationID == nil, normalizedRelativePath != nil {
            throw LibraryLocationValidationError.locationIdentifierMismatch
        }
        self.id = id
        self.locationID = locationID
        self.relativePath = normalizedRelativePath
        self.legacyAbsolutePath = normalizedAbsolutePath
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case locationID
        case relativePath
        case legacyAbsolutePath
        case signature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            locationID: container.decodeIfPresent(UUID.self, forKey: .locationID),
            relativePath: container.decodeIfPresent(String.self, forKey: .relativePath),
            legacyAbsolutePath: container.decode(String.self, forKey: .legacyAbsolutePath),
            signature: container.decodeIfPresent(FileSignature.self, forKey: .signature)
        )
    }
}

extension LibraryLocation {
    fileprivate static func validateTrackAbsolutePath(_ path: String) throws -> String {
        try validateAbsolutePath(path)
    }
}

enum LibraryRelativePath {
    static func validate(_ relativePath: String, allowEmpty: Bool) throws -> String {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        if normalized.isEmpty {
            guard allowEmpty else {
                throw LibraryLocationValidationError.invalidRelativePath
            }
            return ""
        }
        guard !normalized.hasPrefix("/"),
              !normalized.utf8.contains(0),
              normalized.utf8.count <= LibraryLocationLimits.maximumPathBytes else {
            throw LibraryLocationValidationError.invalidRelativePath
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw LibraryLocationValidationError.invalidRelativePath
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw LibraryLocationValidationError.invalidRelativePath
            }
            guard component.utf8.count <= LibraryLocationLimits.maximumRelativePathComponentBytes else {
                throw LibraryLocationValidationError.relativePathComponentTooLong(
                    maximumBytes: LibraryLocationLimits.maximumRelativePathComponentBytes
                )
            }
        }
        return components.map(String.init).joined(separator: "/")
    }

    static func make(
        childURL: URL,
        relativeTo rootURL: URL,
        allowRoot: Bool = false
    ) throws -> String {
        let rootComponents = normalizedComponents(of: rootURL)
        let childComponents = normalizedComponents(of: childURL)
        guard childComponents.count >= rootComponents.count,
              childComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            throw LibraryLocationValidationError.pathOutsideRoot
        }
        let relativeComponents = childComponents.dropFirst(rootComponents.count)
        if relativeComponents.isEmpty {
            guard allowRoot else {
                throw LibraryLocationValidationError.pathOutsideRoot
            }
            return ""
        }
        return try validate(relativeComponents.joined(separator: "/"), allowEmpty: false)
    }

    static func resolve(
        _ relativePath: String,
        under rootURL: URL,
        allowRoot: Bool = false
    ) throws -> URL {
        let validated = try validate(relativePath, allowEmpty: allowRoot)
        let standardizedRoot = rootURL.standardizedFileURL
        if validated.isEmpty { return standardizedRoot }

        var result = standardizedRoot
        for component in validated.split(separator: "/") {
            result.appendPathComponent(String(component), isDirectory: false)
        }
        result = result.standardizedFileURL

        let rootComponents = normalizedComponents(of: standardizedRoot)
        let resultComponents = normalizedComponents(of: result)
        guard resultComponents.count > rootComponents.count,
              resultComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            throw LibraryLocationValidationError.pathOutsideRoot
        }
        return result
    }

    private static func normalizedComponents(of url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.map {
            $0.precomposedStringWithCanonicalMapping
        }
    }
}

struct LibraryBookmarkRefresh: Equatable, Sendable {
    let locationID: UUID
    let bookmarkData: Data
    let bookmarkKind: LibraryBookmarkKind
    let resolvedPath: String
    let volumeRelativeRootPath: String?

    init(
        locationID: UUID,
        bookmarkData: Data,
        bookmarkKind: LibraryBookmarkKind,
        resolvedPath: String,
        volumeRelativeRootPath: String?
    ) throws {
        _ = try LibraryBookmark(data: bookmarkData, kind: bookmarkKind)
        self.locationID = locationID
        self.bookmarkData = bookmarkData
        self.bookmarkKind = bookmarkKind
        self.resolvedPath = try LibraryLocation.validateTrackAbsolutePath(resolvedPath)
        self.volumeRelativeRootPath = try volumeRelativeRootPath.map {
            try LibraryRelativePath.validate($0, allowEmpty: true)
        }
    }
}

enum LibraryLocationAvailability: Equatable, Sendable {
    case available(URL)
    case volumeUnavailable
    case authorizationRequired
    case rootMissing
    case fileMissing
    case invalidReference(String)
    case indeterminate(String)
}

struct LibraryLocationResolution: Equatable, Sendable {
    let locationID: UUID
    let availability: LibraryLocationAvailability
    let bookmarkRefresh: LibraryBookmarkRefresh?
}

struct LibraryTrackResolution: Equatable, Sendable {
    let referenceID: UUID
    let locationID: UUID?
    let availability: LibraryLocationAvailability
    let bookmarkRefresh: LibraryBookmarkRefresh?
}

struct MountedLibraryVolume: Equatable, Sendable {
    let url: URL
    let identifier: String?
    let displayName: String
    let isRemovable: Bool
    let isEjectable: Bool
    let isLocal: Bool

    init(
        url: URL,
        identifier: String?,
        displayName: String,
        isRemovable: Bool = false,
        isEjectable: Bool = false,
        isLocal: Bool = true
    ) {
        self.url = url.standardizedFileURL
        self.identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
    }

    var topologyKey: String {
        if let identifier, !identifier.isEmpty {
            return "id:\(identifier)"
        }
        return "path:\(url.path.precomposedStringWithCanonicalMapping)"
    }
}
