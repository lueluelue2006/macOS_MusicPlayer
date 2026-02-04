import SwiftUI

struct WeightDotsView: View {
    let level: PlaybackWeights.Level
    let onSelect: (PlaybackWeights.Level) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(PlaybackWeights.Level.allCases.enumerated()), id: \.offset) { (_, l) in
                Button {
                    onSelect(l)
                } label: {
                    Circle()
                        .fill(color(for: l))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(theme.stroke.opacity(0.7), lineWidth: 0.8)
                        )
                        .opacity(l.rawValue <= level.rawValue ? 1.0 : 0.18)
                        .padding(.vertical, 2)
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

