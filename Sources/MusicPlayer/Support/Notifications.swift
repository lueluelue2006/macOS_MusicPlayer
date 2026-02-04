import Foundation

extension Notification.Name {
    /// 聚焦播放列表搜索框
    static let focusSearchField = Notification.Name("focusSearchField")
    /// 取消搜索框聚焦
    static let blurSearchField = Notification.Name("blurSearchField")

    /// 缓存清理通知
    static let showVolumeCacheClearedAlert = Notification.Name("showVolumeCacheClearedAlert")
    static let showDurationCacheClearedAlert = Notification.Name("showDurationCacheClearedAlert")
    static let showArtworkCacheClearedAlert = Notification.Name("showArtworkCacheClearedAlert")
    static let showLyricsCacheClearedAlert = Notification.Name("showLyricsCacheClearedAlert")
    static let showAllCachesClearedAlert = Notification.Name("showAllCachesClearedAlert")

    /// 音量均衡分析面板
    static let showVolumeNormalizationAnalysis = Notification.Name("showVolumeNormalizationAnalysis")

    /// 在退出/强制退出前请求关闭所有 Sheet（避免某些 modal 阻止 Cmd+Q / Quit 生效）
    static let requestDismissAllSheets = Notification.Name("requestDismissAllSheets")

    /// App 内 Toast（右上角）
    static let showAppToast = Notification.Name("showAppToast")

    /// 随机权重变更（用于重置洗牌队列等）
    static let playbackWeightsDidChange = Notification.Name("playbackWeightsDidChange")

    /// 左侧面板（队列/歌单）切换
    static let switchPlaylistPanelToQueue = Notification.Name("switchPlaylistPanelToQueue")
    static let switchPlaylistPanelToPlaylists = Notification.Name("switchPlaylistPanelToPlaylists")
}
