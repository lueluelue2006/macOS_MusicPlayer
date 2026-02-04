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
            isPresented.toggle()
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

            VStack(alignment: .leading, spacing: 8) {
                Text("排序字段")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { option.field },
                    set: { newField in
                        sortState.setOption(SearchSortOption(field: newField, direction: option.direction), for: target)
                    }
                )) {
                    ForEach(SearchSortField.allCases) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .pickerStyle(.inline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("顺序")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { option.direction },
                    set: { newDirection in
                        sortState.setOption(SearchSortOption(field: option.field, direction: newDirection), for: target)
                    }
                )) {
                    ForEach(SearchSortDirection.allCases) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .pickerStyle(.inline)
            }

            Divider()

            Button("恢复原顺序") {
                sortState.setOption(.default, for: target)
            }
            .disabled(option.field == .original && option.direction == .ascending)
        }
        .padding(12)
        .frame(width: 240)
    }
}

