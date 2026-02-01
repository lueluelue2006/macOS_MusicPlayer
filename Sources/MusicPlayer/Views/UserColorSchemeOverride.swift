import SwiftUI

enum UserColorSchemeOverride: Int {
    case system = 0
    case light = 1
    case dark = 2

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var iconName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.stars.fill"
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "亮色"
        case .dark:
            return "暗色"
        }
    }
}

