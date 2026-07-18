import Foundation

/// 与歌单/队列管理相关的离散用户命令。
///
/// 这里只做参数校验和调用服务，不处理任何视图状态或窗口管理。
enum PlaylistCommands {
    /// 创建空歌单。
    static func createEmptyPlaylist(
        name: String,
        in store: PlaylistsStore
    ) -> UserPlaylist.ID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return store.createEmptyPlaylist(name: trimmed)
    }

    /// 重命名歌单。
    static func renamePlaylist(
        _ playlist: UserPlaylist,
        to newName: String,
        in store: PlaylistsStore
    ) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renamePlaylist(playlist, to: trimmed)
    }

    /// 删除歌单。
    static func deletePlaylist(
        _ playlist: UserPlaylist,
        from store: PlaylistsStore
    ) {
        store.deletePlaylist(playlist)
    }

    /// 从队列中移除一首歌曲，并在必要时清理播放器状态。
    static func removeTrackFromQueue(
        _ file: AudioFile,
        manager: PlaylistManager,
        player: AudioPlayer
    ) {
        let isDeletingPlaybackReference =
            player.currentFile?.url == file.url ||
            player.pendingPlaybackURL == file.url

        guard let index = manager.audioFiles.firstIndex(where: { $0.url == file.url }) else { return }
        let removalContext = manager.removeFile(at: index)

        guard isDeletingPlaybackReference else { return }

        let remaining = manager.audioFiles
        player.handleRemovedTrack(
            file.url,
            remainingFiles: remaining,
            playNext: {
                removalContext.flatMap { manager.nextFileAfterRemovingQueueItem($0) }
            },
            playRandom: { manager.getRandomFile() },
            restoreInstalledSelection: {
                guard let installedURL = player.currentFile?.url,
                      let installedIndex = manager.audioFiles.firstIndex(where: { $0.url == installedURL })
                else { return }
                _ = manager.selectFile(at: installedIndex)
            }
        )
    }
}
