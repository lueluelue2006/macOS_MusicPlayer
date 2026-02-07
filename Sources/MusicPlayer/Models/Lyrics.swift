import Foundation
import AVFoundation

// MARK: - Models

public enum LyricsSource: Equatable {
    case embeddedUnsynced            // Plain text lyrics embedded in metadata
    case embeddedSynced              // Timed lyrics embedded in metadata (e.g., ID3 SYLT, iTunes synced)
    case sidecarLRC(URL)             // External .lrc file
    case manual                      // Placeholder for future manual input
}

public struct LyricsLine: Identifiable, Equatable {
    public let id: Int
    public let timestamp: TimeInterval?   // nil for unsynced/static lines
    public let text: String

    public init(id: Int, timestamp: TimeInterval?, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}

public struct LyricsTimeline: Equatable {
    public let lines: [LyricsLine]
    public let isSynced: Bool
    public let source: LyricsSource
    // 仅在 isSynced 为 true 时有效：按行顺序提取的时间戳数组，用于二分搜索
    private let timestamps: [TimeInterval]

    public init(lines: [LyricsLine], isSynced: Bool, source: LyricsSource) {
        self.lines = lines
        self.isSynced = isSynced
        self.source = source
        // 仅对已同步的歌词缓存时间戳；未同步则留空
        if isSynced {
            self.timestamps = lines.compactMap { $0.timestamp }
        } else {
            self.timestamps = []
        }
    }

    // 自定义等值判断，忽略派生字段 timestamps
    public static func == (lhs: LyricsTimeline, rhs: LyricsTimeline) -> Bool {
        lhs.lines == rhs.lines && lhs.isSynced == rhs.isSynced && lhs.source == rhs.source
    }

    public func currentIndex(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        guard !timestamps.isEmpty else { return nil }
        // 二分搜索：找出最后一个 <= time 的索引
        var low = 0
        var high = timestamps.count - 1
        var result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if timestamps[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                if mid == 0 { break }
                high = mid - 1
            }
        }
        return result
    }
}

// MARK: - Service

public enum LyricsServiceError: Error {
    case noLyricsFound
    case parsingFailed
}

public actor LyricsService {
    public static let shared = LyricsService()
    private init() {}

    private nonisolated static let timestampGroupRegex = try? NSRegularExpression(
        pattern: #"(\[(\d{1,2}):(\d{1,2})(?:[.:](\d+))?\])+"#,
        options: []
    )
    private nonisolated static let timeOnlyRegex = try? NSRegularExpression(
        pattern: #"^\s*(\[(\d{1,2}):(\d{1,2})(?:[.:](\d+))?\])+\s*$"#,
        options: []
    )
    private nonisolated static let bracketTimestampRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d+))?\]"#,
        options: []
    )

    // Cache per file URL, with modification-date fingerprints to detect staleness
    private struct CacheEntry {
        let timeline: LyricsTimeline
        let audioMTime: Date?
        let lrcMTime: Date?
    }

    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit: Int = 200

    // Invalidate cache for a specific url or all
    public func invalidate(for url: URL) {
        let key = url.path
        cache.removeValue(forKey: key)
        removeKeyFromOrder(key)
    }

    public func invalidateAll() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    public func loadLyrics(for url: URL) async -> Result<LyricsTimeline, LyricsServiceError> {
        let key = url.path

        // Compute current fingerprints (audio file + sidecar lrc)
        let currentAudioMTime = Self.modificationDate(of: url)
        let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
        let currentLrcMTime = FileManager.default.fileExists(atPath: lrcURL.path) ? Self.modificationDate(of: lrcURL) : nil

        if let entry = cache[key] {
            let sameAudio = Self.isSameDate(entry.audioMTime, currentAudioMTime)
            let sameLrc = Self.isSameDate(entry.lrcMTime, currentLrcMTime)
            if sameAudio && sameLrc {
                touchKey(key)
                return .success(entry.timeline)
            }
        }

        // Load fresh lyrics
        let result = await loadLyricsFresh(url: url)
        switch result {
        case .success(let timeline):
            cache[key] = CacheEntry(timeline: timeline, audioMTime: currentAudioMTime, lrcMTime: currentLrcMTime)
            touchKey(key)
        case .failure:
            cache.removeValue(forKey: key)
            removeKeyFromOrder(key)
        }
        return result
    }

    private func touchKey(_ key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
        enforceCacheLimit()
    }

    private func removeKeyFromOrder(_ key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
    }

    private func enforceCacheLimit() {
        guard cacheOrder.count > cacheLimit else { return }
        let overflow = cacheOrder.count - cacheLimit
        for _ in 0..<overflow {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Loader tries: embedded synced -> embedded unsynced -> sidecar .lrc
    private func loadLyricsFresh(url: URL) async -> Result<LyricsTimeline, LyricsServiceError> {
        // 1) Embedded (AVAsset metadata)
        if let embedded = await extractEmbeddedLyrics(url: url) {
            return .success(embedded)
        }
        // 2) Sidecar .lrc
        if let lrc = self.loadSidecarLRC(url: url) {
            return .success(lrc)
        }
        return .failure(.noLyricsFound)
    }

    // MARK: - Embedded extraction
    private func extractEmbeddedLyrics(url: URL) async -> LyricsTimeline? {
        let asset = AVURLAsset(url: url)
        let all = await asset.allMetadataItems()
        // Try synchronized first (QuickTime/iTunes timed text can be under metadata key "com.apple.iTunes" with "----:com.apple.iTunes:SYLT" or similar; also ID3)
        if let synced = await extractSyncedFromMetadata(items: all) {
            return synced
        }

        // Then unsynchronized lyrics (commonKey .lyrics or ID3/QuickTime specific identifiers)
        if let unsynced = await extractUnsyncedFromMetadata(items: all) {
            return unsynced
        }

        return nil
    }

    private func extractUnsyncedFromMetadata(items: [AVMetadataItem]) async -> LyricsTimeline? {
        // 1) Look for explicit "lyrics" fields (commonKey or identifier)
        if let item = items.first(where: { $0.commonKey?.rawValue == "lyrics" || $0.identifier?.rawValue.lowercased().contains("lyrics") == true }),
           let textRaw = await Self.loadStringValue(from: item),
           !textRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 如果文本看起来像 LRC，优先尝试解析为“动态歌词”
            if looksLikeLRC(text: textRaw), let parsed = parseLRC(text: textRaw, source: .embeddedSynced) {
                return parsed
            }
            // 否则按纯文本处理为“静态歌词”
            let timeline = buildUnsyncedTimeline(from: textRaw, source: .embeddedUnsynced)
            if let t = timeline { return t }
        }
        
        // 2) Heuristic: search any metadata value that looks like lyrics (multi-line with timestamps or many CJK lines)
        var candidates: [String] = []
        candidates.reserveCapacity(min(items.count, 64))
        for item in items {
            if let s = await Self.loadStringValue(from: item) {
                candidates.append(s)
                continue
            }
            if let d = await Self.loadDataValue(from: item),
               let s = String(data: d, encoding: .utf8) {
                candidates.append(s)
            }
        }
        
        // Prefer LRC-like content
        if let lrcLike = candidates.first(where: { looksLikeLRC(text: $0) }) {
            if let parsed = parseLRC(text: lrcLike, source: .embeddedSynced) {
                return parsed
            }
            if let unsynced = buildUnsyncedTimeline(from: lrcLike, source: .embeddedUnsynced) {
                return unsynced
            }
        }
        
        // Otherwise, choose the longest multi-line text as lyrics (covers ID3 USLT exposed as plain text)
        if let longest = candidates
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ $0.contains("\n") && $0.count > 20 })
            .sorted(by: { $0.count > $1.count })
            .first {
            if let t = buildUnsyncedTimeline(from: longest, source: .embeddedUnsynced) {
                return t
            }
        }
        
        return nil
    }

    private func extractSyncedFromMetadata(items: [AVMetadataItem]) async -> LyricsTimeline? {
        // Attempt to parse ID3 SYLT or timed QuickTime items
        // In AVFoundation, synced lyrics may not be exposed uniformly across formats.
        // We will attempt heuristic keys and custom iTunes fields.
        // Try to find items with dataValue that look like LRC or timed payload
        // Some encoders embed LRC as a freeform tag (----:com.apple.iTunes:LYRICS) or custom
        if let candidate = items.first(where: { item in
            if let keySpace = item.keySpace?.rawValue.lowercased(), keySpace.contains("id3") || keySpace.contains("quicktime") || keySpace.contains("itunes") {
                if let identifier = item.identifier?.rawValue.lowercased() {
                    return identifier.contains("sylt") || identifier.contains("lyrics") || identifier.contains("lyric")
                }
                if let key = item.key as? String {
                    let k = key.lowercased()
                    return k.contains("sylt") || k.contains("lyrics") || k.contains("lyric")
                }
            }
            return false
        }) {
            // Prefer string if present and looks like LRC
            if let text = await Self.loadStringValue(from: candidate), looksLikeLRC(text: text) {
                if let timeline = parseLRC(text: text, source: .embeddedSynced) {
                    return timeline
                }
            }
            // Fallback to dataValue - try utf8 decode
            if let data = await Self.loadDataValue(from: candidate),
               let text = String(data: data, encoding: .utf8),
               looksLikeLRC(text: text) {
                if let timeline = parseLRC(text: text, source: .embeddedSynced) {
                    return timeline
                }
            }
        }
        return nil
    }

    // MARK: - Sidecar .lrc
    private func loadSidecarLRC(url: URL) -> LyricsTimeline? {
        let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
        guard FileManager.default.fileExists(atPath: lrcURL.path) else { return nil }
        guard let data = try? Data(contentsOf: lrcURL) else { return nil }

        // Try UTF-8 first, then GBK (common for Chinese lyrics), then fallback
        let text: String? =
            String(data: data, encoding: .utf8) ??
            LyricsEncoding.guess(data: data) ??
            String(data: data, encoding: .ascii)

        guard let lrcText = text, !lrcText.isEmpty else { return nil }
        return parseLRC(text: lrcText, source: .sidecarLRC(lrcURL))
    }

    // Build unsynced timeline from plain text (split by lines)
    // 处理包含字面 "\r\n" 或 "\r" "\n" 转义的元数据，统一换行，过滤空白与只有时间戳的行
    private func buildUnsyncedTimeline(from text: String, source: LyricsSource) -> LyricsTimeline? {
        // 1) 优先将字面转义序列反转义成真实换行
        // 例如元数据中存有 "...\r\n" 两个字符，应当转换为实际换行
        let unescaped = text
            .replacingOccurrences(of: "\\r\\n", with: "\n")   // 字面 "\r\n" -> 换行
            .replacingOccurrences(of: "\\n", with: "\n")      // 字面 "\n" -> 换行
            .replacingOccurrences(of: "\\r", with: "\n")      // 字面 "\r" -> 换行
        
        // 2) 再统一平台换行
        let normalized = unescaped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        
        // 3) 拆分行并过滤：去除纯空白行、去除只有时间戳而正文为空的行（以避免空行渲染）
        // 支持 [mm:ss] 或 [mm:ss.xxx] 等多种时间格式
        let timeOnlyRegex = Self.timeOnlyRegex
        
        let texts = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { line in
                guard let re = timeOnlyRegex else { return true }
                let ns = line as NSString
                let hasOnlyTime = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil
                return !hasOnlyTime
            }

        guard !texts.isEmpty else { return nil }
        let lines: [LyricsLine] = texts.enumerated().map { idx, t in
            LyricsLine(id: idx, timestamp: nil, text: t)
        }
        return LyricsTimeline(lines: lines, isSynced: false, source: source)
    }
    
    // MARK: - LRC parsing
    private func parseLRC(text: String, source: LyricsSource) -> LyricsTimeline? {
        // 1) 反转义字面换行，再统一换行
        let unescaped = text
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
        let normalized = unescaped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        var lines: [(TimeInterval?, String)] = []

        // Example tag: [mm:ss.xx] lyric
        // Also supports multiple timestamps per line: [mm:ss.xx][mm:ss.xx] lyric
        // 支持任意位小数：[mm:ss]、[mm:ss.c]、[mm:ss.cc]、[mm:ss.ccc]…（小数位数不限）
        let regex = Self.timestampGroupRegex
        let timeOnlyRegex = Self.timeOnlyRegex
        let bracketRegex = Self.bracketTimestampRegex

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // 过滤掉只有时间戳、没有正文的行，避免渲染空行
            if let re = timeOnlyRegex {
                let ns = line as NSString
                if re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                    continue
                }
            }

            let nsLine = line as NSString
            let matches = regex?.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) ?? []

            if matches.isEmpty {
                // No timestamp - treat as unsynced chunk
                lines.append((nil, line))
                continue
            }

            // Extract lyric text after last timestamp group
            guard let last = matches.last else { continue }
            let lyricStart = last.range.location + last.range.length
            let lyricText = lyricStart < nsLine.length ? nsLine.substring(from: lyricStart).trimmingCharacters(in: .whitespaces) : ""

            // For each timestamp in the line, add one LyricsLine with same text
            // Scan all [mm:ss.xx] occurrences
            // 与主匹配保持一致：任意位小数
            let timeMatches = bracketRegex?.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) ?? []
            for m in timeMatches {
                if m.numberOfRanges >= 3 {
                    let mm = nsLine.substring(with: m.range(at: 1))
                    let ss = nsLine.substring(with: m.range(at: 2))
                    var cs: String? = nil
                    if m.numberOfRanges >= 4, m.range(at: 3).location != NSNotFound {
                        cs = nsLine.substring(with: m.range(at: 3))
                    }
                    let t = timeFrom(mm: mm, ss: ss, cs: cs)
                    lines.append((t, lyricText))
                }
            }
        }

        // If we produced no timestamped lines, treat result as unsynced text
        let hasAnyTimestamp = lines.contains { $0.0 != nil }
        if hasAnyTimestamp {
            // Keep only timestamped lines for synced timeline; drop pure-unsynced lines to avoid clutter
            let syncedLines = lines
                .compactMap { t, text -> (TimeInterval, String)? in
                    guard let t else { return nil }
                    return (t, text)
                }
                .sorted { (a, b) -> Bool in
                    if a.0 == b.0 { return a.1 < b.1 }
                    return a.0 < b.0
                }

            let built: [LyricsLine] = syncedLines.enumerated().map { idx, pair in
                LyricsLine(id: idx, timestamp: pair.0, text: pair.1)
            }
            return LyricsTimeline(lines: built, isSynced: true, source: source)
        } else {
            // All unsynced
            let unsyncedLines: [LyricsLine] = lines.enumerated()
                .map { idx, pair in LyricsLine(id: idx, timestamp: nil, text: pair.1) }
                .filter { !$0.text.isEmpty }
            guard !unsyncedLines.isEmpty else { return nil }
            return LyricsTimeline(lines: unsyncedLines, isSynced: false, source: source)
        }
    }

    private func timeFrom(mm: String, ss: String, cs: String?) -> TimeInterval {
        let minutes = Double(mm) ?? 0
        let seconds = Double(ss) ?? 0
        var fraction = 0.0
        if var cs = cs, !cs.isEmpty {
            // 仅读取前两位精度（如 229996 -> 22 表示 0.22s）
            if cs.count > 2 { cs = String(cs.prefix(2)) }
            if let frac = Double("0." + cs) { fraction = frac }
        }
        return minutes * 60 + seconds + fraction
    }

    private func looksLikeLRC(text: String) -> Bool {
        // quick heuristic: presence of [mm:ss] or [mm:ss.xxx] and multiple lines
        if !(text.contains("[") && text.contains(":") && text.contains("]")) { return false }
        // ensure there are multiple timestamp patterns to avoid false positives
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d+))?\]"#
        if let r = try? NSRegularExpression(pattern: pattern, options: []) {
            let count = r.numberOfMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
            return count >= 2
        }
        return false
    }
}

// MARK: - Helpers

private enum LyricsEncoding {
    // Attempt to guess GBK/GB18030, common for zh-CN LRC files
    static func guess(data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian
        ]
        for e in encodings {
            if let s = String(data: data, encoding: e) {
                return s
            }
        }
        // Fallback using CFStringEncodings for GB_18030_2000
        let cfEnc = CFStringEncodings.GB_18030_2000
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        let e = String.Encoding(rawValue: encoding)
        return String(data: data, encoding: e)
    }
}

private extension LyricsService {
    static func loadStringValue(from item: AVMetadataItem) async -> String? {
        if #available(macOS 13.0, *) {
            return try? await item.load(.stringValue)
        } else {
            return item.stringValue
        }
    }

    static func loadDataValue(from item: AVMetadataItem) async -> Data? {
        if #available(macOS 13.0, *) {
            return try? await item.load(.dataValue)
        } else {
            return item.dataValue
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            return mtime
        }
        return nil
    }

    static func isSameDate(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (la?, lb?):
            // Consider equal if within 1 second to avoid FS precision issues
            return abs(la.timeIntervalSince1970 - lb.timeIntervalSince1970) < 1.0
        default:
            return false
        }
    }
}

// MARK: - AVAsset convenience to search lyrics-related metadata
private extension AVAsset {
    func allMetadataItems() async -> [AVMetadataItem] {
        if #available(macOS 13.0, *) {
            var items: [AVMetadataItem] = []
            if let m = try? await load(.metadata) { items.append(contentsOf: m) }
            if let m = try? await load(.commonMetadata) { items.append(contentsOf: m) }
            if let formats = try? await load(.availableMetadataFormats) {
                for format in formats {
                    if let m = try? await loadMetadata(for: format) {
                        items.append(contentsOf: m)
                    }
                }
            }
            return items
        } else {
            var items: [AVMetadataItem] = []
            items.append(contentsOf: metadata)
            items.append(contentsOf: commonMetadata)
            for format in availableMetadataFormats {
                items.append(contentsOf: self.metadata(forFormat: format))
            }
            return items
        }
    }
}
