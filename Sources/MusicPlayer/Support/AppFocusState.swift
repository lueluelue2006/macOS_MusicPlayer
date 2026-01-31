import Foundation

final class AppFocusState {
    static let shared = AppFocusState()
    private init() {}

    // 是否正在编辑“搜索框”
    var isSearchFocused: Bool = false
}

