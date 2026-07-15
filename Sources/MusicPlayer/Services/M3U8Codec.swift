import Foundation

/// M3U8 playlist codec for import/export.
/// Supports UTF-8 with BOM, CRLF/LF line endings, relative and absolute paths.
enum M3U8Codec {

    struct ParsedEntry {
        let path: String
        let lineNumber: Int
    }

    struct ParseIssue {
        let lineNumber: Int
        let content: String
        let reason: String
        let firstOccurrenceLineNumber: Int?
    }

    struct ParseResult {
        let entries: [ParsedEntry]
        let issues: [ParseIssue]
    }

    // MARK: - Export

    /// Export a playlist to M3U8 format.
    /// - Parameters:
    ///   - playlist: The playlist to export
    ///   - baseURL: Optional base directory for relative path conversion
    /// - Returns: M3U8 string with #EXTM3U header, one path per line, ending with newline
    static func export(playlist: UserPlaylist, baseURL: URL?) -> String? {
        var lines: [String] = []
        lines.append("#EXTM3U")

        for track in playlist.tracks {
            // Normalize track path
            let normalizedPath = URL(fileURLWithPath: track.path).standardizedFileURL.path
            let exportPath: String

            if let baseURL = baseURL {
                let basePath = baseURL.standardizedFileURL.path

                if normalizedPath.hasPrefix(basePath + "/") {
                    // Path is inside base directory, make it relative
                    let relativePath = String(normalizedPath.dropFirst(basePath.count + 1))
                    exportPath = relativePath
                } else if normalizedPath == basePath {
                    // Edge case: track is the base directory itself
                    exportPath = normalizedPath
                } else {
                    // Path is outside base directory, keep absolute
                    exportPath = normalizedPath
                }
            } else {
                exportPath = normalizedPath
            }

            lines.append(exportPath)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Import

    /// Parse M3U8 content into entries and issues.
    /// - Parameters:
    ///   - content: M3U8 file content (UTF-8, may have BOM)
    ///   - baseURL: Optional base directory for resolving relative paths
    /// - Returns: ParseResult with entries and issues (duplicates, unsupported URLs)
    static func parse(_ content: String, baseURL: URL? = nil) -> ParseResult {
        var entries: [ParsedEntry] = []
        var issues: [ParseIssue] = []

        // Strip UTF-8 BOM if present
        let strippedContent = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content

        // Normalize line endings: CRLF and CR -> LF
        let normalized = strippedContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Split by LF
        let lines = normalized.components(separatedBy: "\n")

        // Track seen paths for duplicate detection
        var seenPaths: [String: Int] = [:] // canonical path -> first line number

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            guard !trimmed.isEmpty else { continue }

            // Skip comments (#EXTM3U, #EXTINF, # comments, etc.)
            guard !trimmed.hasPrefix("#") else { continue }

            // Check for URI scheme (case-insensitive)
            if let colonIndex = trimmed.firstIndex(of: ":"),
               colonIndex != trimmed.startIndex {
                let schemeCandidate = String(trimmed[..<colonIndex])

                // RFC 3986: scheme must start with ASCII letter, followed by letter/digit/+/-/.
                guard let firstChar = schemeCandidate.first,
                      firstChar.isASCII && firstChar.isLetter else {
                    // Not a valid scheme, treat as local path
                    let absolutePath = resolveLocalPath(trimmed, baseURL: baseURL)
                    processEntry(absolutePath, trimmed, lineNumber, &seenPaths, &entries, &issues)
                    continue
                }

                // Check if remaining characters are valid for scheme
                let isScheme = schemeCandidate.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
                }

                if isScheme {
                    let schemeLower = schemeCandidate.lowercased()

                    if schemeLower == "file" {
                        // file:// URL - validate it's local
                        if let url = URL(string: trimmed), url.scheme?.lowercased() == "file" {
                            // Reject file URLs with explicit non-local host
                            if let host = url.host, !host.isEmpty {
                                let hostLower = host.lowercased()
                                if hostLower != "localhost" {
                                    issues.append(ParseIssue(
                                        lineNumber: lineNumber,
                                        content: trimmed,
                                        reason: "不支持非本地 file:// URL (non-local file:// URL not supported)",
                                        firstOccurrenceLineNumber: nil
                                    ))
                                    continue
                                }
                            }

                            // Local file URL is valid, extract path
                            let absolutePath = url.path
                            processEntry(absolutePath, trimmed, lineNumber, &seenPaths, &entries, &issues)
                            continue
                        } else {
                            issues.append(ParseIssue(
                                lineNumber: lineNumber,
                                content: trimmed,
                                reason: "无效的 file:// URL (invalid file:// URL)",
                                firstOccurrenceLineNumber: nil
                            ))
                            continue
                        }
                    } else if schemeLower == "http" || schemeLower == "https" {
                        issues.append(ParseIssue(
                            lineNumber: lineNumber,
                            content: trimmed,
                            reason: "不支持远程 URL (remote URL not supported)",
                            firstOccurrenceLineNumber: nil
                        ))
                        continue
                    } else {
                        // Any other scheme (ftp, smb, rtsp, etc.)
                        issues.append(ParseIssue(
                            lineNumber: lineNumber,
                            content: trimmed,
                            reason: "不支持的 URL scheme (unsupported URL scheme)",
                            firstOccurrenceLineNumber: nil
                        ))
                        continue
                    }
                }
            }

            // No scheme or Windows-style path (C:/) - treat as local path
            let absolutePath = resolveLocalPath(trimmed, baseURL: baseURL)
            processEntry(absolutePath, trimmed, lineNumber, &seenPaths, &entries, &issues)
        }

        return ParseResult(entries: entries, issues: issues)
    }

    // MARK: - Helpers

    private static func resolveLocalPath(_ path: String, baseURL: URL?) -> String {
        if path.hasPrefix("/") {
            // Already absolute path
            return path
        } else {
            // Relative path - resolve against baseURL
            if let baseURL = baseURL {
                let resolved = baseURL.appendingPathComponent(path)
                return resolved.standardizedFileURL.path
            } else {
                // No base URL, resolve against current directory
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
        }
    }

    private static func processEntry(
        _ absolutePath: String,
        _ originalContent: String,
        _ lineNumber: Int,
        _ seenPaths: inout [String: Int],
        _ entries: inout [ParsedEntry],
        _ issues: inout [ParseIssue]
    ) {
        // Normalize path for duplicate detection
        let canonicalPath = PathKey.canonical(path: absolutePath)

        // Check for duplicates
        if let firstLine = seenPaths[canonicalPath] {
            issues.append(ParseIssue(
                lineNumber: lineNumber,
                content: originalContent,
                reason: "重复条目 (duplicate entry)",
                firstOccurrenceLineNumber: firstLine
            ))
        } else {
            seenPaths[canonicalPath] = lineNumber
        }

        // Add entry regardless of whether it's a duplicate (preserve all)
        entries.append(ParsedEntry(path: absolutePath, lineNumber: lineNumber))
    }
}
