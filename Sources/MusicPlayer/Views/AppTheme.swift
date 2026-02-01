import SwiftUI

struct AppTheme {
    let scheme: ColorScheme

    // MARK: - 双模式配色（暗色极光 / 亮色暖霞）

    /// 主强调色 - 暗色冰蓝 / 亮色玫瑰粉
    var accent: Color {
        scheme == .dark
            ? Color(red: 0.35, green: 0.85, blue: 0.92)   // 冰蓝色
            : Color(red: 0.93, green: 0.32, blue: 0.52)    // 玫瑰粉
    }

    /// 次要强调色 - 暗色薄荷绿 / 亮色暖橙
    var accentSecondary: Color {
        scheme == .dark
            ? Color(red: 0.30, green: 0.95, blue: 0.70)   // 薄荷绿
            : Color(red: 1.0, green: 0.55, blue: 0.32)    // 暖橙
    }

    /// 第三强调色 - 暗色极光绿 / 亮色梦幻紫
    var accentTertiary: Color {
        scheme == .dark
            ? Color(red: 0.55, green: 1.0, blue: 0.85)    // 极光绿
            : Color(red: 0.58, green: 0.25, blue: 0.80)    // 梦幻紫
    }

    /// 主渐变 - 暗色极光效果 / 亮色暖霞渐变
    var accentGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.95, blue: 0.70),  // 薄荷绿
                    Color(red: 0.35, green: 0.85, blue: 0.92),  // 冰蓝
                    Color(red: 0.45, green: 0.75, blue: 0.95)   // 天青
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    accentTertiary,
                    accent,
                    accentSecondary
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// 活力渐变 - 用于当前播放项等高亮元素
    var vibrantGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.55, green: 1.0, blue: 0.85),   // 极光绿
                    Color(red: 0.35, green: 0.85, blue: 0.92),  // 冰蓝
                    Color(red: 0.50, green: 0.70, blue: 0.98)   // 淡紫蓝
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.22, blue: 0.78),  // 深紫
                    Color(red: 0.95, green: 0.36, blue: 0.50),  // 玫红
                    Color(red: 1.0, green: 0.58, blue: 0.28)    // 暖橙
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    /// 进度条渐变
    var progressGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.95, blue: 0.70),  // 薄荷绿
                    Color(red: 0.35, green: 0.85, blue: 0.92),  // 冰蓝
                    Color(red: 0.50, green: 0.75, blue: 0.98)   // 极光蓝
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.60, green: 0.28, blue: 0.82),  // 紫色
                    Color(red: 0.93, green: 0.34, blue: 0.52),  // 品红
                    Color(red: 1.0, green: 0.55, blue: 0.32)    // 珊瑚
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    // MARK: - 背景系统

    var backgroundGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.08, blue: 0.12),  // 深夜蓝
                    Color(red: 0.06, green: 0.10, blue: 0.14),  // 午夜色
                    Color(red: 0.03, green: 0.06, blue: 0.10)   // 深海蓝
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.95, blue: 0.98),  // 淡紫白
                    Color(red: 0.99, green: 0.96, blue: 0.95),  // 暖桃白
                    Color(red: 0.98, green: 0.95, blue: 0.93)   // 暖杏白
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var panelBackground: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.12, blue: 0.16),  // 极夜蓝
                    Color(red: 0.06, green: 0.10, blue: 0.14)   // 深渊蓝
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.97, blue: 0.97),   // 暖玫白
                    Color(red: 0.99, green: 0.96, blue: 0.95)   // 暖桃色
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - 表面和层级

    var surface: Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.92)
    }

    var elevatedSurface: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.85)
    }

    var mutedSurface: Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.70)
    }

    /// 玻璃效果背景色
    var glassSurface: Color {
        scheme == .dark
            ? Color(red: 0.15, green: 0.15, blue: 0.22).opacity(0.85)
            : Color(red: 1.0, green: 0.97, blue: 0.96).opacity(0.80)
    }

    // MARK: - 边框和阴影

    var stroke: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    /// 发光边框色
    var glowStroke: Color {
        scheme == .dark ? accent.opacity(0.35) : accent.opacity(0.30)
    }

    var subtleShadow: Color {
        scheme == .dark ? Color.black.opacity(0.50) : Color.black.opacity(0.10)
    }

    /// 强调阴影 - 带颜色的阴影
    var accentShadow: Color {
        scheme == .dark ? accent.opacity(0.30) : accentSecondary.opacity(0.22)
    }

    // MARK: - 文字颜色

    var mutedText: Color {
        scheme == .dark ? Color.white.opacity(0.65) : Color.secondary
    }

    /// 高亮文字色
    var highlightText: Color {
        scheme == .dark ? Color.white : Color.black
    }

    // MARK: - 交互状态

    func rowBackground(isActive: Bool) -> LinearGradient {
        if isActive {
            return LinearGradient(
                colors: [
                    accent.opacity(0.25),
                    accentSecondary.opacity(0.15)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [
                    surface,
                    surface.opacity(0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// 当前播放项的发光边框
    func activeRowGlow(isActive: Bool) -> Color {
        isActive ? accent.opacity(0.45) : Color.clear
    }

    func dropZoneBorder(isActive: Bool) -> Color {
        isActive ? accent : (scheme == .dark ? Color.white.opacity(0.25) : Color.gray.opacity(0.4))
    }

    func dropZoneFill(isActive: Bool) -> Color {
        if isActive {
            return accent.opacity(0.15)
        } else {
            return scheme == .dark ? Color.white.opacity(0.03) : Color.gray.opacity(0.04)
        }
    }

    // MARK: - 动画配置

    /// 标准弹簧动画
    static var springAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0)
    }

    /// 快速弹簧动画
    static var quickSpring: Animation {
        .spring(response: 0.25, dampingFraction: 0.75, blendDuration: 0)
    }

    /// 柔和过渡动画
    static var smoothTransition: Animation {
        .easeInOut(duration: 0.25)
    }
}
