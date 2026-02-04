import SwiftUI

struct SearchSortButton: View {
    let target: SearchFocusTarget
    let helpSuffix: String

    @ObservedObject private var sortState = SearchSortState.shared
    @State private var isPresented: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        let option = sortState.option(for: target)

        Button {
            // Make popover feel snappy: avoid implicit animations on show/hide.
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPresented.toggle()
            }
        } label: {
            Image(systemName: option.field == .original ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                .foregroundColor(theme.mutedText)
                .font(.headline)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
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
