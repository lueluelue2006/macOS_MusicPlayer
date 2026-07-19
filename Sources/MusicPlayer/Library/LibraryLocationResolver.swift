import Darwin
import Foundation

protocol LibraryBookmarkProviding: Sendable {
    func createBookmark(
        for url: URL,
        preferredKind: LibraryBookmarkKind
    ) throws -> LibraryBookmark

    func resolveBookmark(_ bookmark: LibraryBookmark) throws -> ResolvedLibraryBookmark
}

struct ResolvedLibraryBookmark: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

struct FoundationLibraryBookmarkProvider: LibraryBookmarkProviding {
    func createBookmark(
        for url: URL,
        preferredKind: LibraryBookmarkKind
    ) throws -> LibraryBookmark {
        let resourceKeys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey,
            .volumeUUIDStringKey,
            .volumeIdentifierKey
        ]

        if preferredKind == .securityScoped {
            do {
                let data = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: resourceKeys,
                    relativeTo: nil
                )
                return try LibraryBookmark(data: data, kind: .securityScoped)
            } catch {
                // The current application is not sandboxed. A regular bookmark
                // still supplies persistent file-reference behavior; a future
                // sandbox migration can ask the user to refresh this location.
            }
        }

        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: resourceKeys,
            relativeTo: nil
        )
        return try LibraryBookmark(data: data, kind: .regular)
    }

    func resolveBookmark(_ bookmark: LibraryBookmark) throws -> ResolvedLibraryBookmark {
        var isStale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI]
        if bookmark.kind == .securityScoped {
            options.insert(.withSecurityScope)
        }
        let url = try URL(
            resolvingBookmarkData: bookmark.data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedLibraryBookmark(url: url.standardizedFileURL, isStale: isStale)
    }
}

protocol MountedLibraryVolumeProviding: Sendable {
    func mountedVolumes() throws -> [MountedLibraryVolume]
}

enum MountedLibraryVolumeProviderError: Error, Equatable, Sendable {
    case unavailable
}

struct FoundationMountedLibraryVolumeProvider: MountedLibraryVolumeProviding {
    func mountedVolumes() throws -> [MountedLibraryVolume] {
        let keys: [URLResourceKey] = [
            .volumeUUIDStringKey,
            .volumeIdentifierKey,
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            throw MountedLibraryVolumeProviderError.unavailable
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let identifier = values.volumeUUIDString
                ?? LibraryIdentifierCodec.stableString(from: values.volumeIdentifier)
            return MountedLibraryVolume(
                url: url,
                identifier: identifier,
                displayName: values.volumeName ?? url.lastPathComponent,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isLocal: values.volumeIsLocal ?? true
            )
        }
    }
}

struct LibraryResourceSnapshot: Equatable, Sendable {
    let isDirectory: Bool
    let isRegularFile: Bool
    let volumeIdentifier: String?
    let resourceIdentifier: String?
}

enum LibraryResourceInspection: Equatable, Sendable {
    case available(LibraryResourceSnapshot)
    case missing
    case permissionDenied
    case inaccessible(String)
}

protocol LibraryResourceInspecting: Sendable {
    func inspect(_ url: URL) -> LibraryResourceInspection
}

struct FoundationLibraryResourceInspector: LibraryResourceInspecting {
    func inspect(_ url: URL) -> LibraryResourceInspection {
        do {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isReadableKey,
                .fileResourceIdentifierKey,
                .volumeUUIDStringKey,
                .volumeIdentifierKey
            ])
            guard values.isReadable != false else { return .permissionDenied }
            return .available(
                LibraryResourceSnapshot(
                    isDirectory: values.isDirectory ?? false,
                    isRegularFile: values.isRegularFile ?? false,
                    volumeIdentifier: values.volumeUUIDString
                        ?? LibraryIdentifierCodec.stableString(from: values.volumeIdentifier),
                    resourceIdentifier: LibraryIdentifierCodec.stableString(
                        from: values.fileResourceIdentifier
                    )
                )
            )
        } catch {
            let nsError = error as NSError
            if Self.isMissing(nsError) { return .missing }
            if Self.isPermissionDenied(nsError) { return .permissionDenied }
            return .inaccessible(nsError.localizedDescription)
        }
    }

    private static func isMissing(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ENOENT) || error.code == Int(ENOTDIR)
        }
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        }
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileReadNoPermissionError
            || error.code == NSFileWriteNoPermissionError
    }
}

protocol LibrarySecurityScopeAccessing: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct FoundationLibrarySecurityScopeAccessor: LibrarySecurityScopeAccessing {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum LibraryLocationResolverError: Error, Equatable, Sendable {
    case invalidLocation(LibraryLocationValidationError)
    case unavailable(LibraryLocationAvailability)
}

/// Ownership token retained by playback while a resolved file is installed.
/// Implementations must make release idempotent because replacement, failure,
/// and teardown paths can converge during asynchronous loading.
protocol AudioPlaybackAccessLease: AnyObject, Sendable {
    var locationID: UUID { get }
    var url: URL { get }
    func releasePlaybackAccess()
}

struct AudioPlaybackAccessRequest: Equatable, Sendable {
    let referenceID: UUID
    let locationID: UUID
    let relativePath: String?
    let legacyAbsolutePath: String
}

protocol AudioPlaybackAccessLeaseProviding: AnyObject {
    /// Returns nil for ordinary local files, avoiding resolver and database work.
    func playbackAccessRequest(for file: AudioFile) -> AudioPlaybackAccessRequest?

    func acquirePlaybackAccessLease(
        for request: AudioPlaybackAccessRequest
    ) async throws -> any AudioPlaybackAccessLease
}

final class LibraryLocationAccessLease: AudioPlaybackAccessLease, @unchecked Sendable {
    let locationID: UUID
    let url: URL
    let bookmarkRefresh: LibraryBookmarkRefresh?

    private let lock = NSLock()
    private var releaseAction: (@Sendable () async -> Void)?

    fileprivate init(
        locationID: UUID,
        url: URL,
        bookmarkRefresh: LibraryBookmarkRefresh?,
        releaseAction: @escaping @Sendable () async -> Void
    ) {
        self.locationID = locationID
        self.url = url
        self.bookmarkRefresh = bookmarkRefresh
        self.releaseAction = releaseAction
    }

    func release() async {
        let action = takeReleaseAction()
        await action?()
    }

    func releasePlaybackAccess() {
        guard let action = takeReleaseAction() else { return }
        Task { await action() }
    }

    deinit {
        guard let action = takeReleaseAction() else { return }
        Task { await action() }
    }

    private func takeReleaseAction() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let action = releaseAction
        releaseAction = nil
        return action
    }
}

actor LibraryLocationResolver {
    private struct ActiveAccess {
        let rootURL: URL
        let bookmarkRefresh: LibraryBookmarkRefresh?
        let didStartSecurityScope: Bool
        var referenceCount: Int
        var acceptsNewLeases: Bool
    }

    private struct RootAcquisition {
        let availability: LibraryLocationAvailability
        let bookmarkRefresh: LibraryBookmarkRefresh?
    }

    private struct RootCandidate {
        let url: URL
        let shouldRefreshBookmark: Bool
    }

    private let bookmarkProvider: any LibraryBookmarkProviding
    private let volumeProvider: any MountedLibraryVolumeProviding
    private let resourceInspector: any LibraryResourceInspecting
    private let securityScopeAccessor: any LibrarySecurityScopeAccessing
    private var activeAccesses: [UUID: ActiveAccess] = [:]

    init(
        bookmarkProvider: any LibraryBookmarkProviding = FoundationLibraryBookmarkProvider(),
        volumeProvider: any MountedLibraryVolumeProviding = FoundationMountedLibraryVolumeProvider(),
        resourceInspector: any LibraryResourceInspecting = FoundationLibraryResourceInspector(),
        securityScopeAccessor: any LibrarySecurityScopeAccessing = FoundationLibrarySecurityScopeAccessor()
    ) {
        self.bookmarkProvider = bookmarkProvider
        self.volumeProvider = volumeProvider
        self.resourceInspector = resourceInspector
        self.securityScopeAccessor = securityScopeAccessor
    }

    func makeLocation(
        for selectedURL: URL,
        kind: LibraryLocationKind,
        preferSecurityScope: Bool = true,
        id: UUID = UUID()
    ) throws -> LibraryLocation {
        let url = selectedURL.standardizedFileURL
        let inspection = resourceInspector.inspect(url)
        guard case .available(let snapshot) = inspection else {
            throw LibraryLocationResolverError.unavailable(
                Self.availability(forRootInspection: inspection)
            )
        }
        switch kind {
        case .directory where !snapshot.isDirectory:
            throw LibraryLocationResolverError.invalidLocation(.locationKindMismatch)
        case .singleFile where !snapshot.isRegularFile:
            throw LibraryLocationResolverError.invalidLocation(.locationKindMismatch)
        default:
            break
        }

        let preferredKind: LibraryBookmarkKind = preferSecurityScope ? .securityScoped : .regular
        let bookmark = try bookmarkProvider.createBookmark(for: url, preferredKind: preferredKind)
        let volumes = try volumeProvider.mountedVolumes()
        let relativeToVolume = Self.relativePathToUniqueVolume(
            for: url,
            volumeIdentifier: snapshot.volumeIdentifier,
            mountedVolumes: volumes
        )
        let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return try LibraryLocation(
            id: id,
            kind: kind,
            bookmarkData: bookmark.data,
            bookmarkKind: bookmark.kind,
            fallbackPath: url.path,
            volumeIdentifier: snapshot.volumeIdentifier,
            volumeRelativeRootPath: relativeToVolume,
            rootResourceIdentifier: snapshot.resourceIdentifier,
            displayName: displayName
        )
    }

    func makeReference(
        for fileURL: URL,
        in location: LibraryLocation,
        id: UUID = UUID(),
        signature: FileSignature? = nil
    ) throws -> LibraryTrackReference {
        let url = fileURL.standardizedFileURL
        let relativePath: String?
        switch location.kind {
        case .directory:
            relativePath = try LibraryRelativePath.make(
                childURL: url,
                relativeTo: location.fallbackURL
            )
        case .singleFile:
            guard Self.sameStandardizedPath(url, location.fallbackURL) else {
                throw LibraryLocationValidationError.pathOutsideRoot
            }
            relativePath = nil
        }
        return try LibraryTrackReference(
            id: id,
            locationID: location.id,
            relativePath: relativePath,
            legacyAbsolutePath: url.path,
            signature: signature
        )
    }

    func resolve(_ location: LibraryLocation) -> LibraryLocationResolution {
        let acquisition = acquireRoot(for: location)
        defer {
            if case .available = acquisition.availability {
                releaseAccess(for: location.id)
            }
        }
        return LibraryLocationResolution(
            locationID: location.id,
            availability: acquisition.availability,
            bookmarkRefresh: acquisition.bookmarkRefresh
        )
    }

    func resolve(
        _ reference: LibraryTrackReference,
        in location: LibraryLocation
    ) -> LibraryTrackResolution {
        guard reference.locationID == location.id else {
            return LibraryTrackResolution(
                referenceID: reference.id,
                locationID: reference.locationID,
                availability: .invalidReference("位置身份不匹配"),
                bookmarkRefresh: nil
            )
        }

        let acquisition = acquireRoot(for: location)
        guard case .available(let rootURL) = acquisition.availability else {
            return LibraryTrackResolution(
                referenceID: reference.id,
                locationID: reference.locationID,
                availability: acquisition.availability,
                bookmarkRefresh: acquisition.bookmarkRefresh
            )
        }
        defer { releaseAccess(for: location.id) }

        let availability = trackAvailability(
            reference: reference,
            location: location,
            rootURL: rootURL
        )
        return LibraryTrackResolution(
            referenceID: reference.id,
            locationID: reference.locationID,
            availability: availability,
            bookmarkRefresh: acquisition.bookmarkRefresh
        )
    }

    func acquireAccess(
        to reference: LibraryTrackReference,
        in location: LibraryLocation
    ) throws -> LibraryLocationAccessLease {
        guard reference.locationID == location.id else {
            throw LibraryLocationResolverError.invalidLocation(.locationIdentifierMismatch)
        }
        let acquisition = acquireRoot(for: location)
        guard case .available(let rootURL) = acquisition.availability else {
            throw LibraryLocationResolverError.unavailable(acquisition.availability)
        }

        let targetAvailability = trackAvailability(
            reference: reference,
            location: location,
            rootURL: rootURL
        )
        guard case .available(let targetURL) = targetAvailability else {
            releaseAccess(for: location.id)
            throw LibraryLocationResolverError.unavailable(targetAvailability)
        }

        return LibraryLocationAccessLease(
            locationID: location.id,
            url: targetURL,
            bookmarkRefresh: acquisition.bookmarkRefresh,
            releaseAction: { [weak self] in
                await self?.releaseLease(for: location.id)
            }
        )
    }

    func withAccess<T: Sendable>(
        to reference: LibraryTrackReference,
        in location: LibraryLocation,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let lease = try acquireAccess(to: reference, in: location)
        do {
            let result = try await operation(lease.url)
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Prevents a new lease from reusing a root that an external-volume event
    /// has invalidated. Existing playback/analysis leases retain their access
    /// until their owners release them.
    func invalidateActiveResolution(for locationID: UUID) {
        guard var active = activeAccesses[locationID] else { return }
        active.acceptsNewLeases = false
        activeAccesses[locationID] = active
    }

    func activeLeaseCount(for locationID: UUID) -> Int {
        activeAccesses[locationID]?.referenceCount ?? 0
    }

    private func acquireRoot(for location: LibraryLocation) -> RootAcquisition {
        if var active = activeAccesses[location.id] {
            guard active.acceptsNewLeases else {
                return RootAcquisition(availability: .volumeUnavailable, bookmarkRefresh: nil)
            }
            active.referenceCount += 1
            activeAccesses[location.id] = active
            return RootAcquisition(
                availability: .available(active.rootURL),
                bookmarkRefresh: active.bookmarkRefresh
            )
        }

        let mountedVolumes: [MountedLibraryVolume]
        do {
            mountedVolumes = try volumeProvider.mountedVolumes()
        } catch {
            return RootAcquisition(
                availability: .indeterminate("无法读取已挂载磁盘列表"),
                bookmarkRefresh: nil
            )
        }

        let matchingVolumes = mountedVolumes.filter {
            guard let expected = location.volumeIdentifier else { return false }
            return $0.identifier == expected
        }
        if location.volumeIdentifier != nil, matchingVolumes.isEmpty {
            return RootAcquisition(availability: .volumeUnavailable, bookmarkRefresh: nil)
        }

        var candidates: [RootCandidate] = []
        do {
            let bookmark = try LibraryBookmark(
                data: location.bookmarkData,
                kind: location.bookmarkKind
            )
            let resolved = try bookmarkProvider.resolveBookmark(bookmark)
            candidates.append(
                RootCandidate(
                    url: resolved.url.standardizedFileURL,
                    shouldRefreshBookmark: resolved.isStale
                )
            )
        } catch {
            // A volume-relative fallback below can repair an unavailable or
            // stale bookmark without scanning the mounted volume.
        }

        if let fallback = fallbackRootURL(
            for: location,
            matchingVolumes: matchingVolumes
        ), !candidates.contains(where: { Self.sameStandardizedPath($0.url, fallback) }) {
            candidates.append(RootCandidate(url: fallback, shouldRefreshBookmark: true))
        }
        if candidates.isEmpty, location.volumeIdentifier == nil {
            candidates.append(
                RootCandidate(url: location.fallbackURL, shouldRefreshBookmark: true)
            )
        }

        var lastUnavailable: LibraryLocationAvailability = .rootMissing
        for candidate in candidates {
            let didStartScope = location.bookmarkKind == .securityScoped
                && securityScopeAccessor.startAccessing(candidate.url)
            let inspection = resourceInspector.inspect(candidate.url)
            guard case .available(let snapshot) = inspection else {
                if didStartScope { securityScopeAccessor.stopAccessing(candidate.url) }
                lastUnavailable = Self.availability(forRootInspection: inspection)
                if lastUnavailable == .authorizationRequired { break }
                continue
            }

            let kindMatches = (location.kind == .directory && snapshot.isDirectory)
                || (location.kind == .singleFile && snapshot.isRegularFile)
            guard kindMatches else {
                if didStartScope { securityScopeAccessor.stopAccessing(candidate.url) }
                lastUnavailable = .invalidReference("保存的位置类型已经改变")
                continue
            }
            if let expectedVolume = location.volumeIdentifier,
               snapshot.volumeIdentifier != expectedVolume {
                if didStartScope { securityScopeAccessor.stopAccessing(candidate.url) }
                lastUnavailable = .invalidReference("磁盘身份不匹配")
                continue
            }
            if let expectedResource = location.rootResourceIdentifier,
               snapshot.resourceIdentifier != expectedResource {
                if didStartScope { securityScopeAccessor.stopAccessing(candidate.url) }
                lastUnavailable = .rootMissing
                continue
            }

            let refresh = candidate.shouldRefreshBookmark
                ? makeRefresh(
                    for: location,
                    resolvedURL: candidate.url,
                    mountedVolumes: mountedVolumes
                )
                : nil
            activeAccesses[location.id] = ActiveAccess(
                rootURL: candidate.url,
                bookmarkRefresh: refresh,
                didStartSecurityScope: didStartScope,
                referenceCount: 1,
                acceptsNewLeases: true
            )
            return RootAcquisition(
                availability: .available(candidate.url),
                bookmarkRefresh: refresh
            )
        }

        return RootAcquisition(availability: lastUnavailable, bookmarkRefresh: nil)
    }

    private func trackAvailability(
        reference: LibraryTrackReference,
        location: LibraryLocation,
        rootURL: URL
    ) -> LibraryLocationAvailability {
        let targetURL: URL
        do {
            switch location.kind {
            case .directory:
                guard let relativePath = reference.relativePath else {
                    return .invalidReference("目录歌曲缺少相对路径")
                }
                targetURL = try LibraryRelativePath.resolve(relativePath, under: rootURL)
            case .singleFile:
                guard reference.relativePath == nil else {
                    return .invalidReference("单文件位置不应包含相对路径")
                }
                targetURL = rootURL
            }
        } catch {
            return .invalidReference("相对路径越过了授权根目录")
        }

        switch resourceInspector.inspect(targetURL) {
        case .available(let snapshot):
            guard snapshot.isRegularFile else {
                return .invalidReference("歌曲路径不是普通文件")
            }
            return .available(targetURL)
        case .missing:
            return .fileMissing
        case .permissionDenied:
            return .authorizationRequired
        case .inaccessible(let message):
            return .indeterminate(message)
        }
    }

    private func fallbackRootURL(
        for location: LibraryLocation,
        matchingVolumes: [MountedLibraryVolume]
    ) -> URL? {
        guard matchingVolumes.count == 1,
              let volume = matchingVolumes.first,
              let relativePath = location.volumeRelativeRootPath else { return nil }
        return try? LibraryRelativePath.resolve(
            relativePath,
            under: volume.url,
            allowRoot: true
        )
    }

    private func makeRefresh(
        for location: LibraryLocation,
        resolvedURL: URL,
        mountedVolumes: [MountedLibraryVolume]
    ) -> LibraryBookmarkRefresh? {
        guard let bookmark = try? bookmarkProvider.createBookmark(
            for: resolvedURL,
            preferredKind: location.bookmarkKind
        ) else { return nil }
        let volumeRelativePath = Self.relativePathToUniqueVolume(
            for: resolvedURL,
            volumeIdentifier: location.volumeIdentifier,
            mountedVolumes: mountedVolumes
        )
        return try? LibraryBookmarkRefresh(
            locationID: location.id,
            bookmarkData: bookmark.data,
            bookmarkKind: bookmark.kind,
            resolvedPath: resolvedURL.path,
            volumeRelativeRootPath: volumeRelativePath
        )
    }

    private func releaseLease(for locationID: UUID) {
        releaseAccess(for: locationID)
    }

    private func releaseAccess(for locationID: UUID) {
        guard var active = activeAccesses[locationID] else { return }
        active.referenceCount -= 1
        if active.referenceCount > 0 {
            activeAccesses[locationID] = active
            return
        }
        activeAccesses.removeValue(forKey: locationID)
        if active.didStartSecurityScope {
            securityScopeAccessor.stopAccessing(active.rootURL)
        }
    }

    private static func availability(
        forRootInspection inspection: LibraryResourceInspection
    ) -> LibraryLocationAvailability {
        switch inspection {
        case .available:
            return .indeterminate("位置状态不一致")
        case .missing:
            return .rootMissing
        case .permissionDenied:
            return .authorizationRequired
        case .inaccessible(let message):
            return .indeterminate(message)
        }
    }

    private static func relativePathToUniqueVolume(
        for url: URL,
        volumeIdentifier: String?,
        mountedVolumes: [MountedLibraryVolume]
    ) -> String? {
        let candidates: [MountedLibraryVolume]
        if let volumeIdentifier {
            candidates = mountedVolumes.filter { $0.identifier == volumeIdentifier }
        } else {
            candidates = mountedVolumes.filter {
                (try? LibraryRelativePath.make(
                    childURL: url,
                    relativeTo: $0.url,
                    allowRoot: true
                )) != nil
            }
        }
        guard candidates.count == 1, let volume = candidates.first else { return nil }
        return try? LibraryRelativePath.make(
            childURL: url,
            relativeTo: volume.url,
            allowRoot: true
        )
    }

    private static func sameStandardizedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path.precomposedStringWithCanonicalMapping
            == rhs.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}

private enum LibraryIdentifierCodec {
    static func stableString(from value: Any?) -> String? {
        switch value {
        case let data as Data:
            return data.base64EncodedString()
        case let data as NSData:
            return (data as Data).base64EncodedString()
        case let uuid as UUID:
            return uuid.uuidString
        case let uuid as NSUUID:
            return uuid.uuidString
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        default:
            return nil
        }
    }
}
