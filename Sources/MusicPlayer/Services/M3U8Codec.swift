import Foundation

/// M3U8 playlist codec for import/export.
/// Supports UTF-8 with BOM, CRLF/LF line endings, relative and absolute paths.
enum M3U8Codec {
    private static let maximumLineCount = 100_000
    private static let maximumEntryCount = 50_000
    private static let maximumIssueCount = 2_000
    private static let maximumLineBytes = 16 * 1_024

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
        let wasTruncated: Bool
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
        let strippedContent = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        var seenPaths: [String: Int] = [:]
        var lineNumber = 0
        var wasTruncated = false
        strippedContent.enumerateLines { line, stop in
            lineNumber += 1
            guard lineNumber <= maximumLineCount else {
                wasTruncated = true
                stop = true
                return
            }
            guard entries.count < maximumEntryCount else {
                wasTruncated = true
                stop = true
                return
            }
            processImportLine(
                line,
                lineNumber: lineNumber,
                baseURL: baseURL,
                seenPaths: &seenPaths,
                entries: &entries,
                issues: &issues
            )
        }

        return ParseResult(entries: entries, issues: issues, wasTruncated: wasTruncated)
    }

    private static func processImportLine(
        _ line: String,
        lineNumber: Int,
        baseURL: URL?,
        seenPaths: inout [String: Int],
        entries: inout [ParsedEntry],
        issues: inout [ParseIssue]
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
        guard trimmed.utf8.count <= maximumLineBytes else {
            appendIssue(
                ParseIssue(
                    lineNumber: lineNumber,
                    content: String(trimmed.prefix(256)),
                    reason: "条目过长 (entry too long)",
                    firstOccurrenceLineNumber: nil
                ),
                to: &issues
            )
            return
        }

        if let colonIndex = trimmed.firstIndex(of: ":"), colonIndex != trimmed.startIndex {
            let schemeCandidate = String(trimmed[..<colonIndex])
            if let first = schemeCandidate.first, first.isASCII, first.isLetter {
                let isScheme = schemeCandidate.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
                }
                if isScheme {
                    let scheme = schemeCandidate.lowercased()
                    if scheme == "file" {
                        guard let url = URL(string: trimmed),
                              url.scheme?.lowercased() == "file" else {
                            appendIssue(
                                ParseIssue(
                                    lineNumber: lineNumber,
                                    content: trimmed,
                                    reason: "无效的 file:// URL (invalid file:// URL)",
                                    firstOccurrenceLineNumber: nil
                                ),
                                to: &issues
                            )
                            return
                        }
                        if let host = url.host,
                           !host.isEmpty,
                           host.lowercased() != "localhost" {
                            appendIssue(
                                ParseIssue(
                                    lineNumber: lineNumber,
                                    content: trimmed,
                                    reason: "不支持非本地 file:// URL (non-local file:// URL not supported)",
                                    firstOccurrenceLineNumber: nil
                                ),
                                to: &issues
                            )
                            return
                        }
                        processEntry(
                            url.path,
                            trimmed,
                            lineNumber,
                            &seenPaths,
                            &entries,
                            &issues
                        )
                        return
                    }
                    let reason = (scheme == "http" || scheme == "https")
                        ? "不支持远程 URL (remote URL not supported)"
                        : "不支持的 URL scheme (unsupported URL scheme)"
                    appendIssue(
                        ParseIssue(
                            lineNumber: lineNumber,
                            content: trimmed,
                            reason: reason,
                            firstOccurrenceLineNumber: nil
                        ),
                        to: &issues
                    )
                    return
                }
            }
        }

        let absolutePath = resolveLocalPath(trimmed, baseURL: baseURL)
        processEntry(
            absolutePath,
            trimmed,
            lineNumber,
            &seenPaths,
            &entries,
            &issues
        )
    }

    private static func appendIssue(_ issue: ParseIssue, to issues: inout [ParseIssue]) {
        guard issues.count < maximumIssueCount else { return }
        issues.append(issue)
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
            appendIssue(
                ParseIssue(
                    lineNumber: lineNumber,
                    content: originalContent,
                    reason: "重复条目 (duplicate entry)",
                    firstOccurrenceLineNumber: firstLine
                ),
                to: &issues
            )
        } else {
            seenPaths[canonicalPath] = lineNumber
        }

        // Add entry regardless of whether it's a duplicate (preserve all)
        entries.append(ParsedEntry(path: absolutePath, lineNumber: lineNumber))
    }
}
