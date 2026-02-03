import Foundation

enum SearchFocusTarget: String {
    case queue
    case playlists
    case addFromQueue
    case volumeAnalysis
}

final class AppFocusState {
    static let shared = AppFocusState()
    private init() {}

    // 是否正在编辑“搜索框”
    var isSearchFocused: Bool = false

    // 当前 Command+F 应该聚焦的搜索框目标
    var activeSearchTarget: SearchFocusTarget = .queue
}
