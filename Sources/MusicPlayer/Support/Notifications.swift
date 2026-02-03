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

    /// App 内 Toast（右上角）
    static let showAppToast = Notification.Name("showAppToast")
}
