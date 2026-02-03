<div align="center">
  <img src="AppIcon.iconset/icon_256x256.png" width="128" height="128" alt="MusicPlayer icon" />
  <h1>MusicPlayer for macOS</h1>
  <p>一款基于 SwiftUI 与 AVFoundation 的本地音乐播放器</p>
  <p>
    <a href="https://github.com/lueluelue2006/macOS_MusicPlayer/releases">下载（Releases）</a>
    ·
    <a href="LLM_README.md">开发与调试（LLM_README）</a>
  </p>
</div>

特性：
- 拖拽添加歌曲/文件夹 + 播放列表
- 随机/循环、断点续播
- 音量均衡（响度分析缓存）
- 歌词显示（内嵌/外置 `.lrc`）
- 基础元数据编辑

## 下载（DMG）

- GitHub Releases: https://github.com/lueluelue2006/macOS_MusicPlayer/releases
- 选择对应架构的 DMG：
  - Apple Silicon：`MusicPlayer-vX.Y.dmg`
  - Intel：`MusicPlayer-vX.Y-intel.dmg`

## 使用

- 拖拽本地音乐文件/文件夹到窗口即可添加到播放列表。
- 支持随机/循环/断点续播/歌词显示/响度分析等功能。

## 隐私

- 应用不上传你的音乐数据；仅在“检查更新”时会访问 GitHub（获取最新版本信息）。

## 开发与调试

- CLI/IPC/构建与代码地图等内容见：`LLM_README.md`

## Bundle ID（UserDefaults 域）

- `io.github.lueluelue2006.macosmusicplayer`

## License

GNU AGPLv3（见 `LICENSE`）。
