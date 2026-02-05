import SwiftUI

struct SearchSortButton: View {
    let target: SearchFocusTarget
    let helpSuffix: String

    @ObservedObject private var sortState = SearchSortState.shared
    @State private var isPresented: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        let option = sortState.option(for: target)
        let isActive = option != .default

        Button {
            // Make popover feel snappy: avoid implicit animations on show/hide.
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPresented.toggle()
            }
        } label: {
            ZStack {
                if isActive {
                    if reduceMotion {
                        activeBackground(phase: 0.65)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let period = 1.8
                            let phase = (sin(t * (2.0 * .pi) / period) + 1.0) / 2.0 // 0..1
                            activeBackground(phase: phase)
                        }
                    }
                }

                Image(systemName: option.field == .original ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                    .foregroundStyle(isActive ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText))
                    .font(.headline)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SearchSortPopover(target: target, isPresented: $isPresented)
                .transaction { t in
                    t.animation = nil
                    t.disablesAnimations = true
                }
        }
        .help("排序：\(option.field.displayName)（\(option.direction.displayName)）\n\(helpSuffix)")
    }

    @ViewBuilder
    private func activeBackground(phase: Double) -> some View {
        let clamped = max(0.0, min(1.0, phase))
        let bgOpacity = 0.12 + 0.10 * clamped
        let glowOpacity = 0.20 + 0.35 * clamped
        let glowRadius = 6.0 + 7.0 * clamped
        let scale = 0.98 + 0.04 * clamped

        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(theme.accent.opacity(bgOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(theme.accentGradient, lineWidth: 1.2)
                    .opacity(0.85)
            )
            .shadow(color: theme.accentShadow.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
            .scaleEffect(scale)
            .allowsHitTesting(false)
    }
}

private struct SearchSortPopover: View {
    let target: SearchFocusTarget
    @Binding var isPresented: Bool

    @ObservedObject private var sortState = SearchSortState.shared

    var body: some View {
        let option = sortState.option(for: target)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("排序")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            sortSection(
                title: "排序字段",
                items: SearchSortField.allCases,
                isSelected: { $0 == option.field },
                titleFor: { $0.displayName },
                onSelect: { field in
                    sortState.setOption(SearchSortOption(field: field, direction: option.direction), for: target)
                }
            )

            sortSection(
                title: "顺序",
                items: SearchSortDirection.allCases,
                isSelected: { $0 == option.direction },
                titleFor: { $0.displayName },
                onSelect: { direction in
                    sortState.setOption(SearchSortOption(field: option.field, direction: direction), for: target)
                }
            )

            Divider()

            Button("恢复原顺序") {
                sortState.setOption(.default, for: target)
            }
            .disabled(option.field == .original && option.direction == .ascending)
        }
        .padding(12)
        .frame(width: 240)
    }

    private func sortSection<T: Identifiable>(
        title: String,
        items: [T],
        isSelected: @escaping (T) -> Bool,
        titleFor: @escaping (T) -> String,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected(item) ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(isSelected(item) ? .accentColor : .secondary)
                            Text(titleFor(item))
                                .foregroundColor(.primary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
