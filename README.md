# MusicPlayer for macOS (v3.0)

一款基于 SwiftUI 与 AVFoundation 的本地音乐播放器：拖拽添加、播放列表、随机/循环、断点续播、音量均衡（响度分析缓存）、歌词显示（内嵌/外置 `.lrc`）、基础元数据编辑（Apple 格式原生写入；其他格式提供 FFmpeg 命令引导）。

## 构建与运行

- 构建 App：`./build.sh`（输出：`MusicPlayer.app`）
- 运行 App：`open MusicPlayer.app`
- 构建 CLI：`swift build -c release`（输出：`.build/release/musicplayerctl`）
- 创建 DMG：`./create_dmg.sh`（输出：`MusicPlayer-v3.0.dmg`）

## CLI（调试/自动化）

- `musicplayerctl ping`
- `musicplayerctl status --json`
- `musicplayerctl toggle|pause|resume|next|prev|random|shuffle|loop`
- `musicplayerctl play <关键词...>` / `musicplayerctl play --index <n>`
- `musicplayerctl seek 2:50`
- `musicplayerctl volume 80%`
- `musicplayerctl rate 1.25`
- `musicplayerctl normalization on|off`
- `musicplayerctl add <path> [path...]`
- `musicplayerctl remove --index <n>` / `musicplayerctl remove <关键词...>`
- `musicplayerctl screenshot --out /tmp/musicplayer.png`

说明：
- CLI 通过 `DistributedNotificationCenter` 与正在运行的 `MusicPlayer.app` 通信（需先启动 App）。
- `remove` 只会从播放列表移除条目，不会删除磁盘文件。
- `rate`（倍速）仅对当前运行生效，重启后恢复 `1.0×`。

## DMG 内置 README

DMG 中显示的说明文件来自仓库根目录的 `readme.txt`。

## 隐私

应用纯本地运行、不访问网络；仅访问你通过“打开面板/拖拽”提供的本地文件路径。
