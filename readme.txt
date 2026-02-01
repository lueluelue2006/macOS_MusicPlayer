# 安装与运行（DMG）— 快速开始（v3.0）

1) 下载发布页面中的 DMG 安装包（文件名示例：MusicPlayer-v3.0.dmg）
2) 双击打开 DMG，将“MusicPlayer.app”**拖入**“应用程序”或任意文件夹
3) 首次运行故障排除（无法验证开发者或者显示“文件已损坏”）
   - 方法一（推荐）：打开“系统设置 → 隐私与安全性”，在底部“安全性”区域找到被阻止的“MusicPlayer”，点击“仍要打开”。随后再次从“应用程序”启动。
   - 方法二（终端）：在“终端”执行以下命令移除隔离属性（比 -cr 更安全精确）：
     ```
     xattr -dr com.apple.quarantine /Applications/MusicPlayer.app
     ```
     说明：
     - 通常无需 sudo；若“应用程序”目录权限被修改导致无权限，可在命令前加 sudo：
       ```
       sudo xattr -dr com.apple.quarantine /Applications/MusicPlayer.app
       ```
     - 若 app 不在 /Applications，请替换为实际 .app 路径。
4) 之后可从“应用程序”或 Launchpad 启动

卸载方法：将“MusicPlayer.app”移至废纸篓（可选删除位于用户默认的播放列表与缓存）

————————————————————————————————————————————————————————

# MusicPlayer for macOS — 项目介绍

一款基于 SwiftUI 与 AVFoundation 打造的简洁音乐播放器。支持拖拽添加歌曲/文件夹、播放列表管理、随机/循环、断点续播、音量均衡（自动分析不同音源的响度）、动态歌词显示（内嵌/外置 .lrc），并提供基础的音频元数据（标题/艺术家/专辑）编辑能力（原生支持 M4A/MP4/AAC；其他格式给出 FFmpeg 命令引导）。

## 目录
- 项目亮点
- 快速上手（面向普通用户）
- 功能详解
- 常见问题与限制
- FFmpeg 元数据编辑指引
- 隐私与权限
- 项目结构（面向开发者）
- 作者

## 项目亮点

- 易用的拖拽体验：把音乐文件或文件夹拖到窗口即可添加，支持“扫描子文件夹”开关
- 播放体验细节：
  - 随机/循环（二者互斥，防止冲突）
  - 记忆播放进度与上次播放歌曲，应用重启后自动恢复
  - 轻量级音量均衡：按文件分析响度，持久化缓存，避免切歌音量差异
- 歌词体验：
  - 自动识别内嵌歌词（支持静态与部分动态/时间轴）
  - 支持同名 .lrc 外置歌词（自动尝试 UTF-8/UTF-16/UTF-32/GB18030）
  - 同步歌词自动跟随、定位当前句、用户滚动后延迟恢复跟随；双击句子可跳转进度
- 性能说明：
  - 加载“无歌词”的歌曲表现良好；实测加载约 200 首歌时，预计内存占用小于 150 MB
  - 加载“含歌词”的歌曲性能与内存占用尚未系统化测试，结果可能随歌词数量与长度波动
- 元数据编辑：
  - 原生写入 M4A/MP4/AAC 元数据
  - 其他格式（MP3/FLAC/OGG/WMA/APE/OPUS）给出可复制的 FFmpeg 命令说明
- 纯本地、无网络依赖；界面自适应窄/宽布局

—

## 快速上手（面向普通用户）

1) 添加音乐
   - 点击“选择音乐文件或文件夹”，或直接把文件/文件夹拖入窗口
   - 需要递归扫描子目录时，打开“扫描子文件夹”开关

2) 播放与控制
   - 在列表中单击一首歌即可播放
   - 使用播放控制区进行播放/暂停、上一首/下一首、进度拖动
   - “随机”和“循环”互斥：同时开启会自动关闭另一个

3) 歌词
   - 若识别到歌词，可在播放器面板中打开“显示歌词”
   - 同步歌词支持自动跟随与“定位当前句”，双击某行可跳转到该时间

4) 元数据编辑
   - 在播放列表条目中点击“铅笔”图标
   - 蓝色图标：可直接编辑（M4A/MP4/AAC）
   - 橙色图标：提供 FFmpeg 命令指引（复制到终端执行）
   - 灰色图标：当前格式不支持编辑

5) 进度与列表恢复
   - 应用会自动保存当前播放的歌曲与进度以及播放列表；再次打开后自动恢复

—

## 功能详解

- 播放与播放列表
  - 拖拽添加、批量添加文件夹（可选递归）
  - 关键词搜索（标题/艺术家/专辑/文件名）
  - 清空、删除单曲、刷新全部元数据
  - 随机播放采用队列式洗牌，记录当前位置，前后切歌行为可预期

- 歌词系统
  - 内嵌歌词：从音频元数据中扫描（ID3/QuickTime/iTunes 相关域）
  - 外置 .lrc：同名文件自动解析；多种编码猜测
  - 同步歌词：自动跟随播放时间，支持暂停自动跟随和手动定位
  - UI 交互：双击歌词行可跳转；显示歌词来源标签（内嵌/外置/手动）

- 音量均衡
  - 基于 RMS 的轻量分析，计算每首歌的增益系数
  - 结果缓存并持久化，避免重复分析
  - 可随时开关音量均衡

- 元数据编辑
  - M4A/MP4/AAC：使用 AVAssetExportSession 直接写回
  - 其他格式：生成对应的 FFmpeg 命令（保持原码流拷贝或给出转换建议）

—

## 常见问题与限制

- 为什么 MP3 不能直接写元数据？
  - macOS 原生 API 不支持直接写入 MP3 元数据，需第三方库；当前版本提供 FFmpeg 命令引导
- 为什么歌词有时识别不到？
  - 不同封装器对歌词存储不一致；可放置同名 .lrc 文件作为兜底
- 音量均衡与专业标准（ReplayGain/R128）
  - 当前为轻量方案，非严格标准；后续计划提供更专业的分析

—

## 安装与运行（DMG）

1) 下载发布页面中的 DMG 安装包（文件名示例：MusicPlayer-v3.0.dmg）
2) 双击打开 DMG，将“MusicPlayer.app”拖入“应用程序”或任意文件夹
3) 首次运行故障排除（无法验证开发者或者显示“文件已损坏”）
   - 方法一（推荐）：打开“系统设置 → 隐私与安全性”，在底部“安全性”区域找到被阻止的“MusicPlayer”，点击“仍要打开”。随后再次从“应用程序”启动。
   - 方法二（终端）：在“终端”执行以下命令移除隔离属性（比 -cr 更安全精确）：
     ```
     xattr -dr com.apple.quarantine /Applications/MusicPlayer.app
     ```
     说明：
     - 通常无需 sudo；若“应用程序”目录权限被修改导致无权限，可在命令前加 sudo：
       ```
       sudo xattr -dr com.apple.quarantine /Applications/MusicPlayer.app
       ```
     - 若 app 不在 /Applications，请替换为实际 .app 路径。
4) 之后可从“应用程序”或 Launchpad 启动

卸载方法：将“MusicPlayer.app”移至废纸篓（可选删除位于用户默认的播放列表与缓存）
——

## FFmpeg 元数据编辑指引（针对非苹果格式）

- 在播放列表中点击橙色“铅笔”按钮，会显示适合该格式的命令示例（如 MP3/FLAC/OGG/WMA/APE/OPUS）
- 使用方法（示例）：
  1) 通过 Homebrew 安装 FFmpeg：brew install ffmpeg
  2) 复制命令到“终端”执行，生成带新元数据的文件（一般会带 .edited 后缀或转换格式）
  3) 检查新文件正确后，可替换原文件或直接使用新文件

- WAV/AIFF 等不支持元数据或支持有限的格式，会给出转换为 M4A 的建议命令

—

## 隐私与权限

- 应用仅访问你通过“打开面板”或“拖拽”提供的本地文件路径
- 应用不访问网络、无远程上传；不包含统计/追踪代码

—


## 项目结构（面向开发者）

- 入口与框架
  - [`SwiftUI.ContentView()`](Sources/MusicPlayer/Views/ContentView.swift:1)：应用主界面，负责加载/恢复播放列表、刷新元数据、处理拖拽、监听恢复通知
  - [`Swift.MusicPlayerApp`](Sources/MusicPlayer/MusicPlayerApp.swift:6)：App 入口，DEBUG 下运行格式测试

- 模型与服务
  - 模型：[`Swift.AudioFile`](Sources/MusicPlayer/Models/AudioFile.swift:124)、[`Swift.AudioMetadata`](Sources/MusicPlayer/Models/AudioFile.swift:4)
  - 歌词：[`Swift.LyricsService`](Sources/MusicPlayer/Models/Lyrics.swift:56)、[`Swift.LyricsTimeline`](Sources/MusicPlayer/Models/Lyrics.swift:24)
  - 播放：[`Swift.AudioPlayer`](Sources/MusicPlayer/Services/AudioPlayer.swift:5)（AVAudioPlayer，计时器、进度保存、音量均衡、歌词加载）
  - 列表：[`Swift.PlaylistManager`](Sources/MusicPlayer/Services/PlaylistManager.swift:4)（扫描/搜索/洗牌/持久化/刷新元数据）
  - 元数据：[`Swift.MetadataEditor`](Sources/MusicPlayer/Services/MetadataEditor.swift:31)（原生写 Apple 格式 + 生成 FFmpeg 命令）

- 界面
  - 播放器面板：[`Swift.PlayerView`](Sources/MusicPlayer/Views/PlayerView.swift:1)（文件选择、当前歌曲信息、歌词容器、播放/音量控制）
  - 播放列表：[`Swift.PlaylistView`](Sources/MusicPlayer/Views/PlaylistView.swift:19)（搜索、子目录开关、条目操作、元数据编辑窗口）

- 打包发布
- 构建应用：`./build.sh`（生成 `MusicPlayer.app`，Info.plist 版本号 v3.0）
- 创建 DMG：`./create_dmg.sh`（输出文件：`MusicPlayer-v3.0.dmg`）
  - DMG 内容：`MusicPlayer.app`、`Applications` 快捷方式、`README.txt`

- CLI（调试/自动化）
  - 构建：`swift build -c release`
  - 位置：`.build/release/musicplayerctl`
  - 用法示例：
    - `musicplayerctl ping`
    - `musicplayerctl status --json`
    - `musicplayerctl toggle|pause|resume|next|prev|random|shuffle|loop`
    - `musicplayerctl play 乡间小路 蔡琴`
    - `musicplayerctl play --index 185`
    - `musicplayerctl seek 2:50`
    - `musicplayerctl volume 80%`
    - `musicplayerctl rate 1.25`
    - `musicplayerctl normalization off`
    - `musicplayerctl add <path> [path...]`
    - `musicplayerctl remove --index 185`
    - `musicplayerctl remove 乡间小路 蔡琴`
    - `musicplayerctl remove --all 未知艺术家`
    - `musicplayerctl screenshot --out /tmp/musicplayer.png`
  - 说明：
    - CLI 通过 `DistributedNotificationCenter` 与正在运行的 `MusicPlayer.app` 通信（因此需要先启动 App）。
    - `screenshot` 由 App 自己渲染窗口并导出 PNG（通常不需要“屏幕录制”权限）；若目标路径已存在会自动追加 `-1/-2` 避免覆盖。
    - `rate`（倍速）仅对当前运行生效，重启后恢复 `1.0×`。
    - `remove` 只会从播放列表移除条目，不会删除磁盘上的音频文件。

—

## 作者

- lueluelue
