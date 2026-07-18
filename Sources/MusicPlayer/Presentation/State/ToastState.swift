import SwiftUI

/// 集中管理应用右上角 Toast 提示的展示和自动关闭。
///
/// 点击动作（打开 URL、触发自动更新）由持有 Toast 的视图通过 `tapURL` / `tapUpdate`
/// 自行决定，避免 State 依赖外部更新服务。
@MainActor
final class ToastState: ObservableObject {
    @Published var isVisible = false
    @Published var title = ""
    @Published var subtitle: String?
    @Published var kind: ToastKind = .info

    private(set) var tapURL: URL?
    private(set) var tapUpdate: UpdateChecker.UpdateInfo?

    private var dismissTask: Task<Void, Never>?

    func show(
        _ title: String,
        subtitle: String? = nil,
        kind: ToastKind = .info,
        duration: TimeInterval = 2.8,
        tapURL: URL? = nil,
        tapUpdate: UpdateChecker.UpdateInfo? = nil
    ) {
        dismissTask?.cancel()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            isVisible = false
            return
        }

        self.title = trimmedTitle
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.tapURL = tapURL
        self.tapUpdate = tapUpdate

        withAnimation(.easeInOut(duration: 0.2)) {
            isVisible = true
        }

        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            } catch {
                return
            }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        tapURL = nil
        tapUpdate = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            isVisible = false
        }
    }

    var hasTapAction: Bool {
        tapURL != nil || tapUpdate != nil
    }

    deinit {
        dismissTask?.cancel()
    }
}
