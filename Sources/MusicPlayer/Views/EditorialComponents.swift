import Foundation
import SwiftUI

/// Small editorial label used to orient major regions without adding cards.
struct EditorialSectionLabel: View {
  let index: String
  let title: String

  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 8) {
      Text(index)
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(theme.accent)

      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(theme.stageSecondaryText)

      Rectangle()
        .fill(theme.paneDivider)
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Generated playlist identity that stays cheap: text and vector shapes only.
struct PlaylistMonogramView: View {
  let name: String
  var isActive = false

  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  private var initial: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map(String.init) ?? "乐"
  }

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)

      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: max(6, side * 0.13), style: .continuous)
          .fill(isActive ? theme.accent : theme.selectedSurface)

        Circle()
          .stroke(
            isActive ? theme.accentForeground.opacity(0.20) : theme.accent.opacity(0.18),
            lineWidth: 1
          )
          .frame(width: side * 0.72, height: side * 0.72)
          .offset(x: side * 0.25, y: side * 0.23)

        Text(initial)
          .font(AppTheme.musicDisplayFont(size: side * 0.50, weight: .bold))
          .foregroundStyle(isActive ? theme.accentForeground : theme.stagePrimaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(isActive ? theme.accentForeground.opacity(0.72) : theme.accent)
          .frame(width: max(2, side * 0.045))
          .padding(.vertical, side * 0.12)
      }
      .clipShape(RoundedRectangle(cornerRadius: max(6, side * 0.13), style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: max(6, side * 0.13), style: .continuous)
          .stroke(theme.stroke, lineWidth: 1)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityHidden(true)
  }
}

/// Column labels aligned with `PlaylistItemView`'s independent hit regions.
struct TrackListColumnHeader: View {
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 0) {
      Text("#")
        .frame(width: 49, alignment: .leading)

      Text("标题")
        .frame(maxWidth: .infinity, alignment: .leading)

      Text("随机权重")
        .frame(width: 116, alignment: .center)

      Text("时长")
        .frame(width: 42, alignment: .trailing)

      Color.clear
        .frame(width: 66, height: 1)
    }
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(theme.stageTertiaryText)
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(theme.paneDivider)
        .frame(height: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("歌曲列表：编号、标题、随机权重和时长")
  }
}

struct NextUpPreviewView: View {
  let file: AudioFile

  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("接下来播放")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.stagePrimaryText)

        Rectangle()
          .fill(theme.paneDivider)
          .frame(height: 1)

        Image(systemName: "text.line.last.and.arrowtriangle.forward")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(theme.stageTertiaryText)
      }

      HStack(spacing: 10) {
        PlaylistMonogramView(name: file.metadata.title)
          .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 2) {
          Text(file.metadata.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.stagePrimaryText)
            .lineLimit(1)

          Text(file.metadata.artist)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(theme.stageTertiaryText)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        if let duration = file.duration, duration.isFinite, duration > 0 {
          Text(Self.formatDuration(duration))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.stageTertiaryText)
        }
      }
    }
    .padding(.vertical, 12)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.paneDivider)
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("接下来播放，\(file.metadata.title)，\(file.metadata.artist)")
  }

  private static func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.towardZero))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
