import SwiftUI

/// 集中管理启动后自动更新检查和手动更新检查的状态与副作用。
@MainActor
final class UpdateCheckState: ObservableObject {
    private var updateCheckTask: Task<Void, Never>?
    private var didAutoCheckForUpdatesThisLaunch = false

    deinit {
        updateCheckTask?.cancel()
    }

    /// 在播放列表就绪后执行一次延迟的自动更新检查。
    func maybeAutoCheck(
        currentVersion: String,
        playlistManager: PlaylistManager,
        onOutcome: @escaping (UpdateChecker.CheckOutcome) -> Void
    ) {
        let ready =
            !playlistManager.audioFiles.isEmpty &&
            !playlistManager.isAddingFiles &&
            !playlistManager.isRestoringPlaylist

        guard ready else {
            updateCheckTask?.cancel()
            updateCheckTask = nil
            return
        }

        guard !didAutoCheckForUpdatesThisLaunch else { return }
        guard updateCheckTask == nil else { return }

        updateCheckTask = Task(priority: .background) {
            do {
                // 启动前几秒优先让 UI、恢复与缓存任务跑完。
                try await Task.sleep(nanoseconds: 12_000_000_000)
            } catch {
                return
            }
            await self.runCheck(
                currentVersion: currentVersion,
                markLaunchChecked: true,
                onOutcome: onOutcome
            )
        }
    }

    /// 用户手动触发更新检查。
    func manualCheck(
        currentVersion: String,
        onOutcome: @escaping (UpdateChecker.CheckOutcome) -> Void
    ) {
        updateCheckTask?.cancel()
        updateCheckTask = nil

        updateCheckTask = Task(priority: .userInitiated) {
            await self.runCheck(
                currentVersion: currentVersion,
                markLaunchChecked: true,
                onOutcome: onOutcome
            )
        }
    }

    /// 执行自动更新安装流程，并在过程中通过 toastState 反馈进度。
    func startSelfUpdate(
        _ info: UpdateChecker.UpdateInfo,
        toastState: ToastState
    ) {
        updateCheckTask?.cancel()
        updateCheckTask = Task(priority: .userInitiated) {
            toastState.show(
                "正在下载并安装 \(info.latestVersion)…",
                subtitle: "将自动覆盖安装到 /Applications 并重启",
                kind: .update,
                duration: 60.0
            )
            do {
                try await SelfUpdater.shared.startUpdateIfPossible(info: info)
            } catch {
                toastState.show(
                    "自动更新失败",
                    subtitle: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    kind: .error,
                    duration: 4.0,
                    tapURL: info.releaseURL
                )
            }
        }
    }

    private func runCheck(
        currentVersion: String,
        markLaunchChecked: Bool,
        onOutcome: @escaping (UpdateChecker.CheckOutcome) -> Void
    ) async {
        if Task.isCancelled { return }
        let outcome = await UpdateChecker.shared.check(currentVersion: currentVersion)
        if Task.isCancelled { return }

        if markLaunchChecked {
            didAutoCheckForUpdatesThisLaunch = true
        }
        updateCheckTask = nil

        await MainActor.run {
            onOutcome(outcome)
        }
    }
}
