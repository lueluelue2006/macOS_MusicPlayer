import AppKit
import SwiftUI

/// A restrained, semantic theme for a native macOS music workspace.
///
/// Album artwork provides the expressive color. Chrome stays neutral so the
/// interface remains legible in both appearances and cheap to render on
/// lower-memory Macs.
struct AppTheme {
  let scheme: ColorScheme

  // MARK: - Accent

  var accent: Color {
    Color(nsColor: .controlAccentColor)
  }

  var accentSecondary: Color {
    Color(nsColor: .systemTeal)
  }

  /// Kept as a ShapeStyle-compatible gradient for existing call sites, but
  /// intentionally monochromatic to avoid rainbow chrome.
  var accentGradient: LinearGradient {
    LinearGradient(
      colors: [accent.opacity(0.88), accent],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Backgrounds

  var backgroundGradient: LinearGradient {
    let colors: [Color] =
      scheme == .dark
      ? [
        Color(red: 0.055, green: 0.058, blue: 0.066),
        Color(red: 0.070, green: 0.073, blue: 0.082),
      ]
      : [
        Color(red: 0.955, green: 0.957, blue: 0.962),
        Color(red: 0.925, green: 0.930, blue: 0.940),
      ]
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }

  var panelBackground: LinearGradient {
    let colors: [Color] =
      scheme == .dark
      ? [
        Color(red: 0.095, green: 0.098, blue: 0.108),
        Color(red: 0.078, green: 0.081, blue: 0.090),
      ]
      : [
        Color.white.opacity(0.90),
        Color.white.opacity(0.72),
      ]
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }

  // MARK: - Surfaces

  var surface: Color {
    scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.68)
  }

  var elevatedSurface: Color {
    scheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.92)
  }

  var mutedSurface: Color {
    scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
  }

  // MARK: - Borders and depth

  var stroke: Color {
    scheme == .dark ? Color.white.opacity(0.105) : Color.black.opacity(0.095)
  }

  var glowStroke: Color {
    accent.opacity(scheme == .dark ? 0.46 : 0.38)
  }

  var subtleShadow: Color {
    scheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.08)
  }

  var accentShadow: Color {
    accent.opacity(scheme == .dark ? 0.15 : 0.10)
  }

  // MARK: - Text

  var mutedText: Color {
    Color(nsColor: .secondaryLabelColor)
  }

  // MARK: - Interaction states

  func rowBackground(isActive: Bool) -> LinearGradient {
    if isActive {
      return LinearGradient(
        colors: [accent.opacity(0.16), accent.opacity(0.09)],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
    return LinearGradient(
      colors: [surface, surface],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  func dropZoneBorder(isActive: Bool) -> Color {
    isActive ? accent : stroke
  }

  func dropZoneFill(isActive: Bool) -> Color {
    isActive ? accent.opacity(0.10) : mutedSurface
  }

  // MARK: - Motion

  static var quickSpring: Animation {
    .spring(response: 0.28, dampingFraction: 0.92, blendDuration: 0)
  }

  static var smoothTransition: Animation {
    .easeOut(duration: 0.18)
  }
}
