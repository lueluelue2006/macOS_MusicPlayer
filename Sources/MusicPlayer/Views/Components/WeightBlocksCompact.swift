import SwiftUI

/// 轨道行使用的紧凑随机权重选择器。
///
/// 默认只显示一个代表当前权重的彩色方块，点击后以 popover 打开完整六档选择器。
/// 避免每行常驻 6 个方块造成的视觉噪音，同时保持交互入口。
struct WeightBlocksCompact: View {
  let level: PlaybackWeights.Level
  let scopeLabel: String
  var itemLabel: String? = nil
  let onSelect: (PlaybackWeights.Level) -> Void

  @State private var isPresented = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(fillColor)
        .frame(width: 11, height: 11)
        .overlay {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(strokeColor, lineWidth: 1)
        }
        .frame(width: 18, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Text("随机权重 · \(scopeLabel)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.stagePrimaryText)

        WeightBlocksView(
          level: level,
          scopeLabel: scopeLabel,
          itemLabel: itemLabel
        ) { newLevel in
          onSelect(newLevel)
          isPresented = false
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
    }
    .help(helpText)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  private var fillColor: Color {
    levelColor.opacity(level == .white ? 0.96 : 0.92)
  }

  private var strokeColor: Color {
    if level == .white {
      return theme.stagePrimaryText.opacity(colorScheme == .dark ? 0.92 : 0.82)
    }
    return theme.stagePrimaryText.opacity(colorScheme == .dark ? 0.70 : 0.72)
  }

  private var levelColor: Color {
    switch level {
    case .white: return .white
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    case .gold: return .yellow
    case .red: return .red
    }
  }

  private var helpText: String {
    let defaultSuffix = level == .defaultLevel ? "（默认）" : ""
    return "随机权重：第 \(level.rawValue + 1) 档 · \(formattedMultiplier)×\(defaultSuffix)；范围：\(scopeLabel)；点击可调整"
  }

  private var accessibilityLabel: String {
    itemLabel.map { "\($0)的随机权重" } ?? "随机权重"
  }

  private var accessibilityValue: String {
    let defaultSuffix = level == .defaultLevel ? "，默认" : ""
    return "\(formattedMultiplier) 倍\(defaultSuffix)，范围：\(scopeLabel)"
  }

  private var formattedMultiplier: String {
    String(format: "%.1f", level.multiplier)
  }
}
