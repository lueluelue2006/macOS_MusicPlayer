import SwiftUI

/// A compact, always-visible six-level random-weight picker.
struct WeightBlocksView: View {
  let level: PlaybackWeights.Level
  let scopeLabel: String
  var itemLabel: String? = nil
  let onSelect: (PlaybackWeights.Level) -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 1) {
      ForEach(PlaybackWeights.Level.allCases, id: \.rawValue) { candidate in
        let isSelected = candidate == level

        Button {
          onSelect(candidate)
        } label: {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fillColor(for: candidate, isSelected: isSelected))
            .frame(width: 11, height: 11)
            .overlay {
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(
                  strokeColor(for: candidate, isSelected: isSelected),
                  lineWidth: candidate == .white && isSelected ? 1.2 : 1
                )
            }
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: candidate, isSelected: isSelected))
        .accessibilityLabel("随机权重，第 \(candidate.rawValue + 1) 档")
        .accessibilityValue(accessibilityValue(for: candidate))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(itemLabel.map { "\($0)的随机权重" } ?? "随机权重")
  }

  private func levelColor(for level: PlaybackWeights.Level) -> Color {
    switch level {
    case .white:
      return .white
    case .green:
      return .green
    case .blue:
      return .blue
    case .purple:
      return .purple
    case .gold:
      return .yellow
    case .red:
      return .red
    }
  }

  private func fillColor(for level: PlaybackWeights.Level, isSelected: Bool) -> Color {
    guard isSelected else {
      return theme.mutedSurface
    }
    return levelColor(for: level).opacity(level == .white ? 0.96 : 0.92)
  }

  private func strokeColor(for level: PlaybackWeights.Level, isSelected: Bool) -> Color {
    if level == .white && isSelected {
      return theme.stagePrimaryText.opacity(colorScheme == .dark ? 0.92 : 0.82)
    }
    return isSelected
      ? theme.stagePrimaryText.opacity(colorScheme == .dark ? 0.70 : 0.72)
      : theme.controlStroke
  }

  private func helpText(for level: PlaybackWeights.Level, isSelected: Bool) -> String {
    let defaultSuffix = level == .defaultLevel ? "（默认）" : ""
    let selectedSuffix = isSelected ? "，当前已选" : ""
    return "随机权重：第 \(level.rawValue + 1) 档 · \(formattedMultiplier(level))×\(defaultSuffix)；范围：\(scopeLabel)\(selectedSuffix)"
  }

  private func accessibilityValue(for level: PlaybackWeights.Level) -> String {
    let defaultSuffix = level == .defaultLevel ? "，默认" : ""
    return "\(formattedMultiplier(level)) 倍\(defaultSuffix)，范围：\(scopeLabel)"
  }

  private func formattedMultiplier(_ level: PlaybackWeights.Level) -> String {
    String(format: "%.1f", level.multiplier)
  }
}
