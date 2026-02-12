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

    private let defaultsKey = "searchSort.options.v1"
    @Published private var optionsByTarget: [String: SearchSortOption] = [:]

    private init() {
        load()
    }

    func option(for target: SearchFocusTarget) -> SearchSortOption {
        optionsByTarget[target.rawValue] ?? .default
    }

    func setOption(_ option: SearchSortOption, for target: SearchFocusTarget) {
        optionsByTarget[target.rawValue] = option
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: SearchSortOption].self, from: data)
        else { return }
        optionsByTarget = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(optionsByTarget) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
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
