import SwiftUI

struct AppTheme {
    let scheme: ColorScheme

    // MARK: - 极光冷色系（Aurora Borealis）

    /// 主强调色 - 冰蓝色
    var accent: Color {
        Color(red: 0.35, green: 0.85, blue: 0.92)
    }

    /// 次要强调色 - 薄荷绿
    var accentSecondary: Color {
        Color(red: 0.30, green: 0.95, blue: 0.70)
    }

    /// 第三强调色 - 极光绿
    var accentTertiary: Color {
        Color(red: 0.55, green: 1.0, blue: 0.85)
    }

    /// 主渐变 - 极光效果
    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.95, blue: 0.70),  // 薄荷绿
                Color(red: 0.35, green: 0.85, blue: 0.92),  // 冰蓝
                Color(red: 0.45, green: 0.75, blue: 0.95)   // 天青
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 活力渐变 - 用于当前播放项等高亮元素
    var vibrantGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 1.0, blue: 0.85),   // 极光绿
                Color(red: 0.35, green: 0.85, blue: 0.92),  // 冰蓝
                Color(red: 0.50, green: 0.70, blue: 0.98)   // 淡紫蓝
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// 进度条渐变
    var progressGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.95, blue: 0.70),  // 薄荷绿
                Color(red: 0.35, green: 0.85, blue: 0.92),  // 冰蓝
                Color(red: 0.50, green: 0.75, blue: 0.98)   // 极光蓝
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - 背景系统（深邃夜空）

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
                    Color(red: 0.95, green: 0.98, blue: 0.99),  // 冰雪白
                    Color(red: 0.92, green: 0.96, blue: 0.98),  // 薄霜色
                    Color(red: 0.94, green: 0.97, blue: 0.99)   // 极地白
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
                    Color(red: 0.96, green: 0.99, blue: 1.0),   // 冰晶白
                    Color(red: 0.94, green: 0.97, blue: 0.99)   // 霜雪色
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
        scheme == .dark ? Color(red: 0.15, green: 0.15, blue: 0.22).opacity(0.85) : Color.white.opacity(0.75)
    }

    // MARK: - 边框和阴影

    var stroke: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    /// 发光边框色
    var glowStroke: Color {
        scheme == .dark ? accent.opacity(0.35) : accent.opacity(0.25)
    }

    var subtleShadow: Color {
        scheme == .dark ? Color.black.opacity(0.50) : Color.black.opacity(0.12)
    }

    /// 强调阴影 - 带颜色的阴影
    var accentShadow: Color {
        scheme == .dark ? accent.opacity(0.30) : accent.opacity(0.20)
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
