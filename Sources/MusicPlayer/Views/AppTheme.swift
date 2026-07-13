import AppKit
import SwiftUI

/// Semantic visual tokens for the album-first MusicPlayer interface.
///
/// The listening stage is intentionally dark in both appearances; the library
/// follows the system appearance. Album artwork is the only large decorative
/// object, so routine chrome remains flat and inexpensive to render.
struct AppTheme {
  let scheme: ColorScheme

  // MARK: - Brand and semantic color

  var accent: Color {
    Color(red: 1.0, green: 0.31, blue: 0.38)
  }

  var accentSecondary: Color {
    Color(red: 1.0, green: 0.58, blue: 0.31)
  }

  var accentGradient: LinearGradient {
    LinearGradient(
      colors: [accentSecondary, accent],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Structural backgrounds

  var libraryBackground: Color {
    scheme == .dark
      ? Color(red: 0.075, green: 0.078, blue: 0.088)
      : Color(red: 0.965, green: 0.962, blue: 0.958)
  }

  var nowPlayingBackground: Color {
    Color(red: 0.065, green: 0.064, blue: 0.073)
  }

  /// Compatibility aliases used by secondary windows.
  var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [libraryBackground, libraryBackground],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  var panelBackground: LinearGradient {
    let color = scheme == .dark
      ? Color(red: 0.095, green: 0.098, blue: 0.108)
      : Color(red: 0.985, green: 0.982, blue: 0.978)
    return LinearGradient(colors: [color, color], startPoint: .top, endPoint: .bottom)
  }

  // MARK: - Surfaces

  var surface: Color {
    scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.70)
  }

  var elevatedSurface: Color {
    scheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.94)
  }

  var mutedSurface: Color {
    scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.042)
  }

  // MARK: - Borders and depth

  var stroke: Color {
    scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.085)
  }

  var paneDivider: Color {
    scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.10)
  }

  var glowStroke: Color { accent.opacity(0.42) }

  var subtleShadow: Color {
    scheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.14)
  }

  var accentShadow: Color { accent.opacity(0.18) }

  // MARK: - Text

  var mutedText: Color { Color(nsColor: .secondaryLabelColor) }

  var stagePrimaryText: Color { Color.white.opacity(0.96) }
  var stageSecondaryText: Color { Color.white.opacity(0.58) }
  var stageTertiaryText: Color { Color.white.opacity(0.36) }

  // MARK: - Interaction states

  func rowBackground(isActive: Bool) -> LinearGradient {
    let color = isActive ? accent.opacity(scheme == .dark ? 0.13 : 0.09) : Color.clear
    return LinearGradient(colors: [color, color], startPoint: .leading, endPoint: .trailing)
  }

  func dropZoneBorder(isActive: Bool) -> Color { isActive ? accent : stroke }
  func dropZoneFill(isActive: Bool) -> Color { isActive ? accent.opacity(0.10) : mutedSurface }

  // MARK: - Motion

  static var quickSpring: Animation {
    .spring(response: 0.24, dampingFraction: 0.96, blendDuration: 0)
  }

  static var smoothTransition: Animation { .easeOut(duration: 0.16) }
}
