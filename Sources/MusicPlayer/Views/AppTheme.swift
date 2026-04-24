import SwiftUI

struct AppTheme {
    let scheme: ColorScheme

    // MARK: - 双模式配色（暗色玫瑰石墨 / 亮色暖霞）

    /// 主强调色 - 暗色柔和玫瑰 / 亮色玫瑰粉
    var accent: Color {
        scheme == .dark
            ? Color(red: 0.86, green: 0.46, blue: 0.52)
            : Color(red: 0.93, green: 0.32, blue: 0.52)    // 玫瑰粉
    }

    /// 次要强调色 - 暗色暖铜 / 亮色暖橙
    var accentSecondary: Color {
        scheme == .dark
            ? Color(red: 0.86, green: 0.60, blue: 0.36)
            : Color(red: 1.0, green: 0.55, blue: 0.32)    // 暖橙
    }

    /// 第三强调色 - 暗色钢蓝灰 / 亮色梦幻紫
    var accentTertiary: Color {
        scheme == .dark
            ? Color(red: 0.48, green: 0.56, blue: 0.70)
            : Color(red: 0.58, green: 0.25, blue: 0.80)    // 梦幻紫
    }

    /// 主渐变 - 暗色低饱和玫瑰铜 / 亮色暖霞渐变
    var accentGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.84, green: 0.44, blue: 0.52),
                    Color(red: 0.84, green: 0.58, blue: 0.36),
                    Color(red: 0.48, green: 0.56, blue: 0.70)
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

    /// 进度条渐变
    var progressGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.84, green: 0.44, blue: 0.52),
                    Color(red: 0.86, green: 0.60, blue: 0.36)
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
                    Color(red: 0.11, green: 0.11, blue: 0.12),
                    Color(red: 0.13, green: 0.13, blue: 0.15),
                    Color(red: 0.14, green: 0.12, blue: 0.13)
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

    var backgroundArtworkOpacity: Double {
        scheme == .dark ? 0.18 : 0.28
    }

    var backgroundArtworkScrim: Color {
        scheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.50) : Color.white.opacity(0.64)
    }

    var backgroundArtworkVignette: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.52)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.82),
                    Color.white.opacity(0.54),
                    Color.white.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var glassPanelFill: Color {
        scheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.14).opacity(0.90) : Color.white.opacity(0.72)
    }

    var glassCardFill: Color {
        scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.15).opacity(0.86) : Color.white.opacity(0.74)
    }

    var glassRowFill: Color {
        scheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.16).opacity(0.80) : Color.white.opacity(0.62)
    }

    var panelBackground: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.15, blue: 0.16),
                    Color(red: 0.11, green: 0.11, blue: 0.12)
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
        scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.92)
    }

    var elevatedSurface: Color {
        scheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.85)
    }

    var mutedSurface: Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.70)
    }

    // MARK: - 边框和阴影

    var stroke: Color {
        scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.06)
    }

    /// 发光边框色
    var glowStroke: Color {
        scheme == .dark ? accent.opacity(0.28) : accent.opacity(0.30)
    }

    var subtleShadow: Color {
        scheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.10)
    }

    /// 强调阴影 - 带颜色的阴影
    var accentShadow: Color {
        scheme == .dark ? accent.opacity(0.18) : accentSecondary.opacity(0.22)
    }

    // MARK: - 文字颜色

    var mutedText: Color {
        scheme == .dark ? Color.white.opacity(0.76) : Color.secondary
    }

    // MARK: - 交互状态

    func rowBackground(isActive: Bool) -> LinearGradient {
        if isActive {
            return LinearGradient(
                colors: [
                    accent.opacity(0.18),
                    accentSecondary.opacity(0.10)
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

    /// 快速弹簧动画
    static var quickSpring: Animation {
        .spring(response: 0.25, dampingFraction: 0.75, blendDuration: 0)
    }

    /// 柔和过渡动画
    static var smoothTransition: Animation {
        .easeInOut(duration: 0.25)
    }
}
