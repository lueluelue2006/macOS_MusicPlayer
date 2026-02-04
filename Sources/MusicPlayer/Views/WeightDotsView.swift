import SwiftUI

struct WeightDotsView: View {
    let level: PlaybackWeights.Level
    let onSelect: (PlaybackWeights.Level) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        let levels = PlaybackWeights.Level.allCases
        HStack(spacing: 0) {
            ForEach(Array(levels.enumerated()), id: \.offset) { (i, l) in
                Button {
                    onSelect(l)
                } label: {
                    let isSelected = (l == level)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isSelected ? color(for: l) : theme.mutedText.opacity(0.12))
                        .frame(width: 10, height: 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(theme.stroke.opacity(isSelected ? 0.9 : 0.55), lineWidth: 1.0)
                        )
                        .shadow(color: isSelected ? color(for: l).opacity(0.75) : .clear, radius: 6, x: 0, y: 0)
                        .shadow(color: isSelected ? color(for: l).opacity(0.35) : .clear, radius: 14, x: 0, y: 0)
                        // Bigger hitbox, but keep layout tight.
                        .frame(width: 14, height: 14)
                        // Remove dead zone between controls: allocate spacing to the left cell.
                        .padding(.trailing, i == (levels.count - 1) ? 0 : 2)
                }
                .buttonStyle(.plain)
                .help(helpText(for: l))
                .accessibilityLabel(accessibilityText(for: l))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func color(for level: PlaybackWeights.Level) -> Color {
        switch level {
        case .green: return Color.green
        case .blue: return Color.blue
        case .purple: return Color.purple
        case .gold: return Color.yellow
        case .red: return Color.red
        }
    }

    private func helpText(for level: PlaybackWeights.Level) -> String {
        let m = level.multiplier
        return "随机权重：\(String(format: "%.1f", m))×"
    }

    private func accessibilityText(for level: PlaybackWeights.Level) -> String {
        let m = level.multiplier
        return "随机权重 \(String(format: "%.1f", m)) 倍"
    }
}
