import AppKit
import SwiftUI

/// Semantic visual tokens for the record-sleeve editorial interface.
///
/// The palette intentionally uses opaque, matte surfaces. It keeps light mode
/// readable on reflective displays and gives dark mode the same warm musical
/// character without relying on blur, gradients, or artwork-driven redraws.
struct AppTheme {
  let scheme: ColorScheme

  // MARK: - Brand and semantic color

  var accent: Color {
    scheme == .dark
      ? Self.color(0xF06B70)
      : Self.color(0xA83B46)
  }

  /// Compatibility aliases for secondary windows that still consume the old
  /// token names. Both resolve to the same ink color by design.
  var accentSecondary: Color { accent }
  var interactiveAccent: Color { accent }

  var accentForeground: Color {
    scheme == .dark ? Self.color(0x1A0D12) : .white
  }

  var accentGradient: LinearGradient {
    LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
  }

  var destructive: Color {
    scheme == .dark ? Self.color(0xFF7B82) : Self.color(0xB42332)
  }

  var warning: Color {
    scheme == .dark ? Self.color(0xE7B56A) : Self.color(0x8A5717)
  }

  var success: Color {
    scheme == .dark ? Self.color(0x79C79A) : Self.color(0x2F6F4E)
  }

  var info: Color {
    scheme == .dark ? Self.color(0x8AB4CF) : Self.color(0x41627A)
  }

  // MARK: - Structural backgrounds

  var libraryCanvas: Color {
    scheme == .dark ? Self.color(0x1D1C1F) : Self.color(0xF2EEE8)
  }

  var nowPlayingBackground: Color {
    scheme == .dark ? Self.color(0x160C11) : Self.color(0xE7DED6)
  }

  var libraryBackground: LinearGradient {
    LinearGradient(
      colors: [libraryCanvas, libraryCanvas],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  /// Compatibility aliases used by secondary windows.
  var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [libraryCanvas, libraryCanvas],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  var panelBackground: LinearGradient {
    let color = panelSurface
    return LinearGradient(colors: [color, color], startPoint: .top, endPoint: .bottom)
  }

  // MARK: - Surfaces

  var panelSurface: Color {
    scheme == .dark ? Self.color(0x222024) : Self.color(0xF8F4EF)
  }

  var surface: Color {
    scheme == .dark ? Self.color(0x272428) : Self.color(0xF7F2EC)
  }

  var elevatedSurface: Color {
    scheme == .dark ? Self.color(0x2C292D) : Self.color(0xFFFDFC)
  }

  var mutedSurface: Color {
    scheme == .dark ? Self.color(0x302C31) : Self.color(0xE9E2DC)
  }

  var hoverSurface: Color {
    scheme == .dark ? Self.color(0x29262A) : Self.color(0xEAE3DD)
  }

  var selectedSurface: Color {
    scheme == .dark ? Self.color(0x3B2027) : Self.color(0xF1DADD)
  }

  // MARK: - Borders and depth

  var stroke: Color {
    scheme == .dark ? Self.color(0x4A4248) : Self.color(0xC8BDB6)
  }

  /// Higher-contrast boundary for controls whose shape must remain visible.
  /// Decorative rules continue to use `stroke` or `paneDivider`.
  var controlStroke: Color {
    scheme == .dark ? Self.color(0x82787F) : Self.color(0x827679)
  }

  var paneDivider: Color {
    scheme == .dark ? Self.color(0x3A3439) : Self.color(0xD7CCC4)
  }

  var glowStroke: Color { accent }

  var subtleShadow: Color {
    scheme == .dark ? Color.black.opacity(0.38) : Color.black.opacity(0.13)
  }

  var accentShadow: Color { accent.opacity(0.16) }

  // MARK: - Text

  var mutedText: Color { stageSecondaryText }

  var stagePrimaryText: Color {
    scheme == .dark ? Self.color(0xF4ECEA) : Self.color(0x241F20)
  }

  var stageSecondaryText: Color {
    scheme == .dark ? Self.color(0xC2B8B8) : Self.color(0x5D5557)
  }

  var stageTertiaryText: Color {
    scheme == .dark ? Self.color(0x9E9496) : Self.color(0x6A6063)
  }

  var disabledText: Color {
    scheme == .dark ? Self.color(0x71686B) : Self.color(0x91888A)
  }

  // MARK: - Interaction states

  func rowBackground(isActive: Bool) -> LinearGradient {
    let color = isActive ? selectedSurface : Color.clear
    return LinearGradient(colors: [color, color], startPoint: .leading, endPoint: .trailing)
  }

  func dropZoneBorder(isActive: Bool) -> Color { isActive ? accent : controlStroke }
  func dropZoneFill(isActive: Bool) -> Color { isActive ? selectedSurface : mutedSurface }

  // MARK: - Type

  static func musicDisplayFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .serif)
  }

  // MARK: - Motion

  static var quickSpring: Animation {
    .spring(response: 0.24, dampingFraction: 0.96, blendDuration: 0)
  }

  static var smoothTransition: Animation { .easeOut(duration: 0.16) }

  private static func color(_ rgb: UInt32) -> Color {
    Color(
      .sRGB,
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      opacity: 1
    )
  }
}
