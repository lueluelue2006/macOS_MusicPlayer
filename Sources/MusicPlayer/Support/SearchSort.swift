import Foundation

enum SearchSortField: String, CaseIterable, Identifiable, Codable, Sendable {
    case original
    case weight
    case title
    case artist
    case duration
    case format

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "原顺序"
        case .weight: return "权重"
        case .title: return "歌名"
        case .artist: return "歌手"
        case .duration: return "时长"
        case .format: return "格式"
        }
    }
}

enum SearchSortDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ascending: return "正序"
        case .descending: return "倒序"
        }
    }
}

struct SearchSortOption: Equatable, Codable, Sendable {
    var field: SearchSortField
    var direction: SearchSortDirection

    static let `default` = SearchSortOption(field: .original, direction: .ascending)
}

@MainActor
final class SearchSortState: ObservableObject {
    static let shared = SearchSortState()

    enum PersistenceState: Equatable {
        case writable
        case protectedFuture(version: Int)
        case protectedCorrupt
    }

    private struct Envelope: Codable {
        let version: Int
        let optionsByTarget: [String: SearchSortOption]
    }

    private struct VersionProbe: Decodable {
        let version: Int?
    }

    nonisolated static let envelopeKey = "searchSort.options"
    nonisolated static let legacyKey = "searchSort.options.v1"
    nonisolated static let formatVersion = 1
    nonisolated static let maximumEnvelopeBytes = 256 * 1_024
    nonisolated static let corruptQuarantineKeys = [
        "searchSort.options.quarantine.0",
        "searchSort.options.quarantine.1",
    ]

    private let userDefaults: UserDefaults
    private let envelopeKey: String
    private let legacyKey: String
    @Published private var optionsByTarget: [String: SearchSortOption] = [:]
    @Published private(set) var revision: Int = 0
    @Published private(set) var persistenceState: PersistenceState = .writable

    init(
        userDefaults: UserDefaults = .standard,
        envelopeKey: String = SearchSortState.envelopeKey,
        legacyKey: String = SearchSortState.legacyKey
    ) {
        self.userDefaults = userDefaults
        self.envelopeKey = envelopeKey
        self.legacyKey = legacyKey
        load()
    }

    func option(for target: SearchFocusTarget) -> SearchSortOption {
        optionsByTarget[target.rawValue] ?? .default
    }

    func setOption(_ option: SearchSortOption, for target: SearchFocusTarget) {
        guard persistenceState == .writable else { return }
        guard optionsByTarget[target.rawValue] != option else { return }
        optionsByTarget[target.rawValue] = option
        persist()
        revision += 1
    }

    private func load() {
        if let data = userDefaults.data(forKey: envelopeKey) {
            guard data.count <= Self.maximumEnvelopeBytes else {
                persistenceState = .protectedCorrupt
                optionsByTarget = [:]
                PersistenceLogger.log("搜索排序偏好超过安全上限，保留原数据并进入只读保护")
                return
            }
            guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
                  let version = probe.version else {
                quarantineCorruptData(data, sourceKey: envelopeKey)
                return
            }
            if version > Self.formatVersion {
                persistenceState = .protectedFuture(version: version)
                optionsByTarget = [:]
                PersistenceLogger.log(
                    "检测到未来搜索排序版本 \(version)，进入只读保护"
                )
                return
            }
            guard version == Self.formatVersion,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  Self.isValid(envelope.optionsByTarget) else {
                quarantineCorruptData(data, sourceKey: envelopeKey)
                return
            }
            optionsByTarget = envelope.optionsByTarget
            return
        }

        guard let legacyData = userDefaults.data(forKey: legacyKey) else { return }
        guard legacyData.count <= Self.maximumEnvelopeBytes,
              let legacy = try? JSONDecoder().decode(
            [String: SearchSortOption].self,
            from: legacyData
        ), Self.isValid(legacy) else {
            quarantineCorruptData(legacyData, sourceKey: legacyKey)
            return
        }
        optionsByTarget = legacy
        persist()
        if userDefaults.data(forKey: envelopeKey) != nil {
            userDefaults.removeObject(forKey: legacyKey)
        }
    }

    private func persist() {
        guard persistenceState == .writable else { return }
        let envelope = Envelope(
            version: Self.formatVersion,
            optionsByTarget: optionsByTarget
        )
        guard let data = try? JSONEncoder().encode(envelope) else {
            PersistenceLogger.log("编码搜索排序偏好失败")
            return
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            PersistenceLogger.log("搜索排序偏好超过安全上限")
            return
        }
        userDefaults.set(data, forKey: envelopeKey)
        if userDefaults.data(forKey: envelopeKey) != data {
            PersistenceLogger.log("搜索排序偏好写入校验失败")
        }
    }

    private func quarantineCorruptData(_ data: Data, sourceKey: String) {
        let keys = Self.corruptQuarantineKeys
        if let previous = userDefaults.data(forKey: keys[0]) {
            userDefaults.set(previous, forKey: keys[1])
        }
        userDefaults.set(data, forKey: keys[0])
        userDefaults.removeObject(forKey: sourceKey)
        optionsByTarget = [:]
        persistenceState = .writable
        PersistenceLogger.log("搜索排序偏好损坏，已隔离并恢复安全默认值")
    }

    private static func isValid(_ options: [String: SearchSortOption]) -> Bool {
        let allowedTargets: Set<String> = [
            SearchFocusTarget.queue.rawValue,
            SearchFocusTarget.playlists.rawValue,
            SearchFocusTarget.addFromQueue.rawValue,
            SearchFocusTarget.volumeAnalysis.rawValue,
        ]
        return options.count <= allowedTargets.count
            && options.keys.allSatisfy(allowedTargets.contains)
    }
}

extension SearchSortOption {
    func applying(to files: [AudioFile], weightScope: PlaybackWeights.Scope?) -> [AudioFile] {
        guard files.count >= 2 else { return files }
        if field == .original {
            return direction == .ascending ? files : Array(files.reversed())
        }

        let field = self.field
        let direction = self.direction
        let weights = PlaybackWeights.shared

        func compareStringAscending(_ a: String, _ b: String) -> Int {
            switch a.localizedStandardCompare(b) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            @unknown default: return 0
            }
        }

        func compareIntDirected(_ a: Int, _ b: Int) -> Int {
            guard a != b else { return 0 }
            if direction == .ascending {
                return a < b ? -1 : 1
            }
            return a > b ? -1 : 1
        }

        func compareStringDirected(_ a: String, _ b: String) -> Int {
            let c = compareStringAscending(a, b)
            guard direction == .descending else { return c }
            return -c
        }

        func compareOptionalStringDirected(_ a: String?, _ b: String?) -> Int {
            switch (a, b) {
            case (nil, nil): return 0
            case (nil, _): return 1 // nil last
            case (_, nil): return -1
            case (let x?, let y?):
                return compareStringDirected(x, y)
            }
        }

        func compareDurationDirected(_ a: TimeInterval?, _ b: TimeInterval?) -> Int {
            switch (a, b) {
            case (nil, nil): return 0
            case (nil, _): return 1 // unknown last
            case (_, nil): return -1
            case (let x?, let y?):
                guard x != y else { return 0 }
                if direction == .ascending {
                    return x < y ? -1 : 1
                }
                return x > y ? -1 : 1
            }
        }

        func titleKey(_ f: AudioFile) -> String {
            let trimmed = f.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return f.url.deletingPathExtension().lastPathComponent
        }

        func artistKey(_ f: AudioFile) -> String? {
            let trimmed = f.metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func formatKey(_ f: AudioFile) -> String? {
            let ext = f.url.pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        }

        func weightLevel(_ f: AudioFile) -> Int {
            guard let scope = weightScope else { return 0 }
            return weights.level(for: f.url, scope: scope).rawValue
        }

        struct SortRow {
            let file: AudioFile
            let offset: Int
            let title: String
            let artist: String?
            let duration: TimeInterval?
            let format: String?
            let name: String
            let weight: Int
        }

        let rows: [SortRow] = files.enumerated().map { entry in
            let file = entry.element
            let weightValue: Int
            if field == .weight {
                weightValue = weightLevel(file)
            } else {
                weightValue = 0
            }
            return SortRow(
                file: file,
                offset: entry.offset,
                title: titleKey(file),
                artist: artistKey(file),
                duration: file.duration,
                format: formatKey(file),
                name: file.url.lastPathComponent,
                weight: weightValue
            )
        }

        let sorted = rows.sorted { lhs, rhs in
            let primary: Int = {
                switch field {
                case .original:
                    return 0
                case .weight:
                    return compareIntDirected(lhs.weight, rhs.weight)
                case .title:
                    return compareStringDirected(lhs.title, rhs.title)
                case .artist:
                    return compareOptionalStringDirected(lhs.artist, rhs.artist)
                case .duration:
                    return compareDurationDirected(lhs.duration, rhs.duration)
                case .format:
                    return compareOptionalStringDirected(lhs.format, rhs.format)
                }
            }()

            if primary != 0 { return primary < 0 }

            // Tie-breakers: keep stable and predictable regardless of sort direction.
            let t = compareStringAscending(lhs.title, rhs.title)
            if t != 0 { return t < 0 }
            let n = compareStringAscending(lhs.name, rhs.name)
            if n != 0 { return n < 0 }
            return lhs.offset < rhs.offset
        }

        return sorted.map(\.file)
    }
}
