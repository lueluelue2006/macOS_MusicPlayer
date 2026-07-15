import Foundation

/// M3U8 import/export service errors
struct M3U8ServiceError: Error {
    enum Code: Equatable {
        case readFailed
        case invalidUTF8
        case writeFailed
    }

    let code: Code
    let underlyingError: Error?

    init(code: Code, underlyingError: Error? = nil) {
        self.code = code
        self.underlyingError = underlyingError
    }
}

/// M3U8 import service with file validation and structured diagnostics
enum M3U8ImportService {

    struct ImportIssue {
        enum Kind: Equatable {
            case codec
            case duplicate
            case missingFile
            case directory
            case unsupportedFormat
            case obviousNonAudio
        }

        let kind: Kind
        let lineNumber: Int
        let path: String
        let message: String
        let firstOccurrenceLineNumber: Int?
    }

    struct ImportResult {
        let playlistName: String
        let tracks: [UserPlaylist.Track]
        let issues: [ImportIssue]
    }

    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"
    ]

    /// Import M3U8 playlist from file
    /// - Parameter url: M3U8 file URL
    /// - Returns: ImportResult with tracks and non-fatal issues
    /// - Throws: M3U8ServiceError on read failure or invalid UTF-8
    static func importPlaylist(from url: URL) throws -> ImportResult {
        // Read file content
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw M3U8ServiceError(code: .readFailed, underlyingError: error)
        }

        // Decode as UTF-8
        guard let content = String(data: data, encoding: .utf8) else {
            throw M3U8ServiceError(code: .invalidUTF8)
        }

        // Parse with codec
        let baseURL = url.deletingLastPathComponent()
        let parseResult = M3U8Codec.parse(content, baseURL: baseURL)

        var validTracks: [UserPlaylist.Track] = []
        var issues: [ImportIssue] = []
        var seenCanonicalPaths = Set<String>()
        var duplicateLines = Set<Int>()

        // Process codec issues: translate duplicates, pass through others
        for codecIssue in parseResult.issues {
            if let firstLine = codecIssue.firstOccurrenceLineNumber {
                // This is a duplicate detected by codec
                issues.append(ImportIssue(
                    kind: .duplicate,
                    lineNumber: codecIssue.lineNumber,
                    path: codecIssue.content,
                    message: codecIssue.reason,
                    firstOccurrenceLineNumber: firstLine
                ))
                duplicateLines.insert(codecIssue.lineNumber)
            } else {
                // Other codec issue (remote URL, unsupported scheme, etc.)
                issues.append(ImportIssue(
                    kind: .codec,
                    lineNumber: codecIssue.lineNumber,
                    path: codecIssue.content,
                    message: codecIssue.reason,
                    firstOccurrenceLineNumber: nil
                ))
            }
        }

        // Validate each entry
        for entry in parseResult.entries {
            // Skip entries already marked as duplicates by codec
            if duplicateLines.contains(entry.lineNumber) {
                continue
            }

            let entryURL = URL(fileURLWithPath: entry.path)
            let canonicalPath = PathKey.canonical(for: entryURL)

            // Track seen paths for deduplication
            guard !seenCanonicalPaths.contains(canonicalPath) else {
                // Should not happen if codec handled duplicates correctly
                continue
            }

            // Check if file exists
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
                issues.append(ImportIssue(
                    kind: .missingFile,
                    lineNumber: entry.lineNumber,
                    path: entry.path,
                    message: "文件不存在 (file not found)",
                    firstOccurrenceLineNumber: nil
                ))
                continue
            }

            // Check if it's a directory
            if isDirectory.boolValue {
                issues.append(ImportIssue(
                    kind: .directory,
                    lineNumber: entry.lineNumber,
                    path: entry.path,
                    message: "路径是目录而非文件 (path is a directory)",
                    firstOccurrenceLineNumber: nil
                ))
                continue
            }

            // Check file extension
            let ext = entryURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                issues.append(ImportIssue(
                    kind: .unsupportedFormat,
                    lineNumber: entry.lineNumber,
                    path: entry.path,
                    message: "不支持的格式 (unsupported format): .\(ext)",
                    firstOccurrenceLineNumber: nil
                ))
                continue
            }

            // Check for obvious non-audio content using AudioFileSniffer
            if let reason = AudioFileSniffer.nonAudioReasonIfClearlyText(at: entryURL) {
                issues.append(ImportIssue(
                    kind: .obviousNonAudio,
                    lineNumber: entry.lineNumber,
                    path: entry.path,
                    message: reason,
                    firstOccurrenceLineNumber: nil
                ))
                continue
            }

            // Valid track
            seenCanonicalPaths.insert(canonicalPath)
            validTracks.append(UserPlaylist.Track(path: entry.path))
        }

        // Derive playlist name from filename
        let playlistName = url.deletingPathExtension().lastPathComponent

        return ImportResult(
            playlistName: playlistName,
            tracks: validTracks,
            issues: issues
        )
    }
}

/// M3U8 export service with atomic writes
enum M3U8ExportService {

    /// Export playlist to M3U8 file
    /// - Parameters:
    ///   - playlist: Playlist to export
    ///   - url: Target M3U8 file URL
    /// - Throws: M3U8ServiceError on write failure
    static func exportPlaylist(_ playlist: UserPlaylist, to url: URL) throws {
        // Use M3U8 file's parent directory as base for relative paths
        let baseURL = url.deletingLastPathComponent()

        guard let content = M3U8Codec.export(playlist: playlist, baseURL: baseURL) else {
            throw M3U8ServiceError(code: .writeFailed)
        }

        // Write atomically
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw M3U8ServiceError(code: .writeFailed, underlyingError: error)
        }
    }
}
