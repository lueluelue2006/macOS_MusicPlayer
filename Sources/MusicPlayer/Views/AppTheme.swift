import SwiftUI

struct AppTheme {
    let scheme: ColorScheme

    // MARK: - 精致、高级的现代 macOS 配色风格（Nordic / Apple Pro）

    /// 主强调色 - 经典的 macOS 蓝，优雅、沉稳且对比度高
    var accent: Color {
        scheme == .dark
            ? Color(red: 0.18, green: 0.49, blue: 0.96)    // 苹果蓝/Cupertino Blue
            : Color(red: 0.00, green: 0.40, blue: 0.85)    // 深海蓝
    }

    /// 次要强调色 - 优雅的蓝灰色
    var accentSecondary: Color {
        scheme == .dark
            ? Color(red: 0.50, green: 0.60, blue: 0.75)    // 钢蓝
            : Color(red: 0.35, green: 0.45, blue: 0.55)    // 石板蓝
    }

    /// 第三强调色 - 辅助灰色
    var accentTertiary: Color {
        scheme == .dark
            ? Color(red: 0.35, green: 0.35, blue: 0.38)
            : Color(red: 0.60, green: 0.60, blue: 0.65)
    }

    /// 主渐变 - 极为低调且高级的微渐变（不再使用高饱和度的青色到薄荷绿）
    var accentGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.52, blue: 0.98), // 明亮蓝
                    Color(red: 0.15, green: 0.42, blue: 0.88)  // 深蔚蓝
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.45, blue: 0.90),
                    Color(red: 0.00, green: 0.35, blue: 0.80)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// 进度条渐变 - 同样使用单色系高级渐变
    var progressGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.55, blue: 1.0),
                    Color(red: 0.16, green: 0.45, blue: 0.92)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.00, green: 0.48, blue: 0.95),
                    Color(red: 0.00, green: 0.36, blue: 0.82)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    // MARK: - 高级质感的背景系统（中性灰色，摒弃高饱和彩色背景）

    var backgroundGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.09),  // 纯正极客暗灰
                    Color(red: 0.10, green: 0.10, blue: 0.11),
                    Color(red: 0.07, green: 0.07, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.96, blue: 0.97),  // 苹果视网膜灰
                    Color(red: 0.98, green: 0.98, blue: 0.98),
                    Color(red: 0.95, green: 0.95, blue: 0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var panelBackground: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.13, blue: 0.15),  // 面板低调深灰
                    Color(red: 0.11, green: 0.11, blue: 0.13)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 1.0, blue: 1.0),
                    Color(red: 0.98, green: 0.98, blue: 0.99)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - 表面和层级

    var surface: Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    var elevatedSurface: Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    var mutedSurface: Color {
        scheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)
    }

    // MARK: - 边框和阴影

    var stroke: Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    /// 发光边框色：不再使用亮青色，仅作为辅助强调边框
    var glowStroke: Color {
        scheme == .dark ? accent.opacity(0.20) : accent.opacity(0.15)
    }

    var subtleShadow: Color {
        scheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.05)
    }

    /// 强调阴影 - 极低透明度的微投影，杜绝发光感
    var accentShadow: Color {
        scheme == .dark ? Color.black.opacity(0.40) : Color.black.opacity(0.08)
    }

    // MARK: - 文字颜色

    var mutedText: Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color.secondary
    }

    // MARK: - 交互状态

    func rowBackground(isActive: Bool) -> LinearGradient {
        if isActive {
            return LinearGradient(
                colors: [
                    accent.opacity(0.12),
                    accent.opacity(0.06)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [
                    surface,
                    surface.opacity(0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    func dropZoneBorder(isActive: Bool) -> Color {
        isActive ? accent : (scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12))
    }

    func dropZoneFill(isActive: Bool) -> Color {
        if isActive {
            return accent.opacity(0.08)
        } else {
            return scheme == .dark ? Color.white.opacity(0.01) : Color.black.opacity(0.01)
        }
    }

    // MARK: - 动画配置

    /// 快速弹簧动画
    static var quickSpring: Animation {
        .spring(response: 0.22, dampingFraction: 0.8, blendDuration: 0)
    }

    /// 柔和过渡动画
    static var smoothTransition: Animation {
        .easeInOut(duration: 0.2)
    }
}

