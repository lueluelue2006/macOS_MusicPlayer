import SwiftUI

struct SearchBarView: View {
  @Binding var searchText: String
  let focusTarget: SearchFocusTarget
  var autoFocusOnAppear: Bool = false
  @ObservedObject private var sortState = SearchSortState.shared
  @FocusState private var isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundColor(theme.mutedText)
        .font(.system(size: 13, weight: .medium))

      TextField("搜索歌曲、艺术家或专辑...", text: $searchText)
        .textFieldStyle(PlainTextFieldStyle())
        .font(.subheadline)
        .focused($isFocused)
        .onChange(of: isFocused) { focused in
          if focused {
            AppFocusState.shared.activeSearchTarget = focusTarget
            AppFocusState.shared.isSearchFocused = true
          } else {
            if AppFocusState.shared.activeSearchTarget == focusTarget {
              AppFocusState.shared.isSearchFocused = false
            }
          }
        }

      if !searchText.isEmpty {
        Button(action: {
          searchText = ""
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(theme.mutedText)
            .font(.headline)
        }
        .buttonStyle(PlainButtonStyle())
      }

      SearchSortButton(target: focusTarget, helpSuffix: "仅影响列表显示，不改变队列/歌单顺序。")
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(theme.surface)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(
            isFocused ? theme.accent : theme.controlStroke,
            lineWidth: isFocused ? 1.5 : 1
          )
      }
    )
    .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { notification in
      let requestedTarget = (notification.userInfo?["target"] as? String).flatMap {
        SearchFocusTarget(rawValue: $0)
      }
      if let requestedTarget {
        guard requestedTarget == focusTarget else { return }
      } else {
        // No explicit target: focus only the current active search target.
        guard AppFocusState.shared.activeSearchTarget == focusTarget else { return }
      }
      AppFocusState.shared.activeSearchTarget = focusTarget
      AppFocusState.shared.pendingSearchFocusTarget = nil
      isFocused = true
      AppFocusState.shared.isSearchFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .blurSearchField)) { _ in
      isFocused = false
      if AppFocusState.shared.activeSearchTarget == focusTarget {
        AppFocusState.shared.isSearchFocused = false
      }
    }
    .onAppear {
      DispatchQueue.main.async {
        let shouldFocus = autoFocusOnAppear
          || AppFocusState.shared.pendingSearchFocusTarget == focusTarget
        if shouldFocus {
          AppFocusState.shared.pendingSearchFocusTarget = nil
          AppFocusState.shared.activeSearchTarget = focusTarget
          isFocused = true
          AppFocusState.shared.isSearchFocused = true
        } else {
          // 防止窗口初次展示时自动获得焦点
          isFocused = false
          if AppFocusState.shared.activeSearchTarget == focusTarget {
            AppFocusState.shared.isSearchFocused = false
          }
        }
      }
    }
  }
}
