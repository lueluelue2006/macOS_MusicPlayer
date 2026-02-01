import SwiftUI
import AppKit

// 窗口代理类，处理窗口关闭事件，避免强引用循环
class MetadataWindowDelegate: NSObject, NSWindowDelegate {
    weak var parentView: NSObject?
    
    init(parentView: NSObject?) {
        self.parentView = parentView
        super.init()
    }
    
    func windowWillClose(_ notification: Notification) {
        // 窗口即将关闭时的清理工作
        // 由于使用了弱引用，不会造成循环引用问题
    }
}

struct PlaylistView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @State private var showingMetadataEdit = false
    @State private var selectedFileForEdit: AudioFile?
    @State private var metadataEditWindow: NSWindow?
    @State private var windowDelegate: MetadataWindowDelegate?
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    
    // 确保窗口在视图销毁时被清理
    init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 标题和操作按钮
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.accentGradient)
                    Text("播放列表")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    // 清空按钮
                    Button(action: {
                        playlistManager.clearAllFiles()
                        audioPlayer.stopAndClearCurrent()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.caption)
                            Text("清空")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(theme.mutedSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                                )
                        )
                        .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(playlistManager.audioFiles.isEmpty)
                    
                    // 刷新按钮
                    Button(action: {
                        Task {
                            await playlistManager.refreshAllMetadata(audioPlayer: audioPlayer)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("完全刷新")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(theme.mutedSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.accentGradient, lineWidth: 1)
                                )
                        )
                        .foregroundStyle(theme.accentGradient)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("完全刷新：重载元数据、歌词、封面（清空歌词/封面缓存；保留音量均衡缓存）")
                }
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
            .onTapGesture {
                // 点击标题栏/操作按钮区域时，也取消搜索框聚焦
                NotificationCenter.default.post(name: .blurSearchField, object: nil)
            }
            
            // 搜索框
            SearchBarView(searchText: $playlistManager.searchText) { query in
                playlistManager.searchFiles(query)
            }
            .padding(.horizontal, 20)
            // 搜索框以外区域：点击自动取消搜索框聚焦
            VStack(alignment: .leading, spacing: 20) {
                // 子文件夹扫描开关（移除右侧文件夹图标）
                HStack {
                    Toggle("扫描子文件夹", isOn: $playlistManager.scanSubfolders)
                        .font(.subheadline)
                        .help("开启后会递归扫描所选文件夹中的所有子文件夹")
                }
                .padding(.horizontal, 20)
                
                // 搜索统计
                if !playlistManager.searchText.isEmpty {
                    HStack {
                        Text("找到 \(playlistManager.filteredFiles.count) / \(playlistManager.audioFiles.count) 首歌曲")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                }
                
                // 播放列表
                if playlistManager.filteredFiles.isEmpty {
                    EmptyPlaylistView()
                } else {
                    List(playlistManager.filteredFiles) { file in
                        PlaylistItemView(
                            file: file,
                            isCurrentTrack: audioPlayer.currentFile?.url == file.url,
                            isVolumeAnalyzed: audioPlayer.hasVolumeNormalizationCache(for: file.url),
                            unplayableReason: playlistManager.unplayableReason(for: file.url),
                            searchText: playlistManager.searchText
                        ) { selectedFile in
                            // 点击列表条目也顺便取消搜索聚焦
                            NotificationCenter.default.post(name: .blurSearchField, object: nil)
                            if let index = playlistManager.audioFiles.firstIndex(of: selectedFile) {
                                if let file = playlistManager.selectFile(at: index) {
                                    audioPlayer.play(file)
                                }
                            }
                        } deleteAction: { fileToDelete in
                            NotificationCenter.default.post(name: .blurSearchField, object: nil)
                            // 删除前判断是否命中当前播放
                            let isDeletingCurrent = (audioPlayer.currentFile?.url == fileToDelete.url)
                            if let index = playlistManager.audioFiles.firstIndex(of: fileToDelete) {
                                // 先执行删除
                                playlistManager.removeFile(at: index)
                                
                                // 若删除的是当前播放，根据播放模式处理
                                if isDeletingCurrent {
                                    // 删除后剩余文件列表（从真实数据源拿）
                                    let remaining = playlistManager.audioFiles
                                    
                                    // 如果后续需要顺序“下一首”，可在此提供闭包：playNext: { playlistManager.nextAfterDeletion(from: index) }
                                    // 现阶段按约定：单曲循环->停止并清空；随机->随机一首；其他->停止并清空
                                    audioPlayer.handleCurrentTrackRemoved(remainingFiles: remaining, playNext: nil)
                                }
                            }
                        } editAction: { fileToEdit in
                            NotificationCenter.default.post(name: .blurSearchField, object: nil)
                            selectedFileForEdit = fileToEdit
                            showingMetadataEdit = true
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listStyle(PlainListStyle())
                    .background(Color.clear)
                    .scrollContentBackground(.hidden)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                NotificationCenter.default.post(name: .blurSearchField, object: nil)
            }
        }
        .background(theme.surface)
        .onChange(of: showingMetadataEdit) { isShowing in
            if isShowing, let file = selectedFileForEdit {
                showMetadataEditWindow(for: file)
                showingMetadataEdit = false
            }
        }
        .onDisappear {
            // 视图消失时确保清理窗口资源
            if let window = metadataEditWindow {
                window.close()
                metadataEditWindow = nil
                selectedFileForEdit = nil
                windowDelegate = nil
            }
        }
    }
    
    private func showMetadataEditWindow(for file: AudioFile) {
        // 如果已经有窗口打开，先关闭它
        if let existingWindow = metadataEditWindow {
            existingWindow.close()
            metadataEditWindow = nil
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // 保存窗口引用
        metadataEditWindow = window
        
        // 创建并设置窗口代理
        windowDelegate = MetadataWindowDelegate(parentView: nil)
        window.delegate = windowDelegate
        
        let metadataEditView = MetadataEditView(
            audioFile: file,
            onSave: { title, artist, album, year, genre, _ in
                // 此处不再调用 MetadataEditor.updateMetadata：由编辑窗口自身完成保存
                // 仅更新列表显示的元数据，并刷新歌词解析结果
                Task {
                    await MainActor.run {
                        playlistManager.updateFileMetadata(file, title: title, artist: artist, album: album, year: year, genre: genre)
                    }

                    // 刷新该文件的歌词缓存并加载最新时间轴
                    await LyricsService.shared.invalidate(for: file.url)
                    let result = await LyricsService.shared.loadLyrics(for: file.url)
                    await MainActor.run {
                        switch result {
                        case .success(let timeline):
                            // 更新列表里的条目
                            if let idx = playlistManager.audioFiles.firstIndex(where: { $0.url == file.url }) {
                                let f = playlistManager.audioFiles[idx]
                                playlistManager.audioFiles[idx] = AudioFile(url: f.url, metadata: f.metadata, lyricsTimeline: timeline)
                            }
                            // 如果正在播放当前歌曲，更新播放器里的时间轴
                            if let current = audioPlayer.currentFile, current.url == file.url {
                                audioPlayer.lyricsTimeline = timeline
                                audioPlayer.currentFile = AudioFile(url: current.url, metadata: current.metadata, lyricsTimeline: timeline)
                                // 重新载入底层播放器以确保持续播放但读取到新文件内容
                                audioPlayer.reloadCurrentPreservingState()
                            }
                        case .failure:
                            // 清空时间轴
                            if let idx = playlistManager.audioFiles.firstIndex(where: { $0.url == file.url }) {
                                let f = playlistManager.audioFiles[idx]
                                playlistManager.audioFiles[idx] = AudioFile(url: f.url, metadata: f.metadata, lyricsTimeline: nil)
                            }
                            if let current = audioPlayer.currentFile, current.url == file.url {
                                audioPlayer.lyricsTimeline = nil
                                audioPlayer.currentFile = AudioFile(url: current.url, metadata: current.metadata, lyricsTimeline: nil)
                                audioPlayer.reloadCurrentPreservingState()
                            }
                        }

                        // 关闭窗口
                        selectedFileForEdit = nil
                        window.close()
                        metadataEditWindow = nil
                    }
                }
            },
            onCancel: {
                selectedFileForEdit = nil
                window.close()
                metadataEditWindow = nil
            }
        )
        
        let hostingController = NSHostingController(rootView: metadataEditView)
        
        window.title = "编辑元数据 - \(file.url.lastPathComponent)"
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // 设置窗口的最小大小
        window.minSize = NSSize(width: 400, height: 500)
        
        // 防止子窗口关闭时退出整个应用
        window.isReleasedWhenClosed = false
    }
}

struct SearchBarView: View {
    @Binding var searchText: String
    let onSearchChanged: (String) -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(theme.mutedText)
                .font(.headline)
            
            TextField("🔍 搜索歌曲、艺术家或专辑...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.subheadline)
                .focused($isFocused)
                .onChange(of: searchText) { newValue in
                    onSearchChanged(newValue)
                }
                .onChange(of: isFocused) { focused in
                    AppFocusState.shared.isSearchFocused = focused
                }
            
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    onSearchChanged("")
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.mutedText)
                        .font(.headline)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.mutedSurface)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.stroke, lineWidth: 1)
                if isFocused {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.accent.opacity(0.45), lineWidth: 2)
                        .shadow(color: theme.accent.opacity(0.35), radius: 8)
                }
            }
            .shadow(color: theme.subtleShadow, radius: 6, x: 0, y: 2)
        )
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isFocused = true
            AppFocusState.shared.isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .blurSearchField)) { _ in
            isFocused = false
            AppFocusState.shared.isSearchFocused = false
        }
        .onAppear {
            // 防止窗口初次展示时自动获得焦点
            DispatchQueue.main.async {
                isFocused = false
                AppFocusState.shared.isSearchFocused = false
            }
        }
    }
}

struct PlaylistItemView: View {
    let file: AudioFile
    let isCurrentTrack: Bool
    let isVolumeAnalyzed: Bool
    let unplayableReason: String?
    let searchText: String
    let playAction: (AudioFile) -> Void
    let deleteAction: (AudioFile) -> Void
    let editAction: (AudioFile) -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    private var iconStyle: AnyShapeStyle {
        if isCurrentTrack { return AnyShapeStyle(theme.accentGradient) }
        if unplayableReason != nil { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Color.primary)
    }
    private var titleStyle: AnyShapeStyle {
        if isCurrentTrack { return AnyShapeStyle(theme.accentGradient) }
        if unplayableReason != nil { return AnyShapeStyle(Color.secondary) }
        return AnyShapeStyle(Color.primary)
    }

    var body: some View {
        HStack(spacing: 14) {
            // 播放按钮（扩大可点击区域：占满除操作按钮外的整行空间）
            Button(action: { playAction(file) }) {
                HStack(alignment: .center, spacing: 14) {
                    // 播放图标
                    ZStack {
                        // 当前播放项的发光背景
                        if isCurrentTrack {
                            Circle()
                                .fill(theme.accent.opacity(0.2))
                                .frame(width: 36, height: 36)
                                .blur(radius: 4)
                                .scaleEffect(1.2)
                                .opacity(0.6)
                        }

                        let iconName: String = {
                            if isCurrentTrack { return "speaker.wave.2.fill" }
                            if unplayableReason != nil { return "exclamationmark.triangle.fill" }
                            return "play.circle.fill"
                        }()
                        Image(systemName: iconName)
                            .foregroundStyle(iconStyle)
                            .font(.system(size: 22))
                            .frame(width: 28, height: 28)
                            .help(unplayableReason.map { "不可播放：\($0)" } ?? "")
                    }
                    .frame(width: 36, height: 36)

                    // 歌曲信息
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(highlightedText(file.metadata.title, searchText: searchText))
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(titleStyle)
                                .layoutPriority(1)

                            let badgeTextStyle: AnyShapeStyle = isVolumeAnalyzed ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText)
                            let badgeStrokeStyle: AnyShapeStyle = isVolumeAnalyzed ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText.opacity(0.45))
                            Text("均")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(badgeTextStyle)
                                .frame(width: 18, height: 18)
                                .background(
                                    Circle()
                                        .fill(isVolumeAnalyzed ? theme.accent.opacity(theme.scheme == .dark ? 0.20 : 0.15) : Color.clear)
                                        .overlay(
                                            Circle()
                                                .stroke(badgeStrokeStyle, lineWidth: 1)
                                                .opacity(isVolumeAnalyzed ? 0.85 : 1)
                                        )
                                )
                                .help(isVolumeAnalyzed ? "音量均衡：已分析" : "音量均衡：未分析")
                                .accessibilityLabel(isVolumeAnalyzed ? "音量均衡已分析" : "音量均衡未分析")
                        }

                        Text("\(highlightedText(file.metadata.artist, searchText: searchText)) - \(highlightedText(file.metadata.album, searchText: searchText))")
                            .font(.system(size: 12))
                            .foregroundColor(theme.mutedText)
                            .lineLimit(1)

                        Text(file.url.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundColor(theme.mutedText.opacity(0.7))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            // 让按钮的可点击区域覆盖整行（含顶部/底部留白），避免只“选中”但点不到播放
            .padding(.leading, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 操作按钮组
            HStack(spacing: 10) {
                // 编辑按钮
                Button(action: { editAction(file) }) {
                    Image(systemName: "pencil")
                        .foregroundColor(buttonColor(for: file))
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(isHovered ? theme.mutedSurface : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!MetadataEditor.canShowEditButton(for: file.url))
                .help(helpText(for: file))

                // 删除按钮
                Button(action: { deleteAction(file) }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(isHovered ? 1 : 0.7))
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(isHovered ? Color.red.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.trailing, 16)
            .padding(.vertical, 14)
            .opacity(isHovered ? 1 : 0.6)
        }
        .background(
            Group {
                // 当前播放项的发光底层
                if isCurrentTrack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.rowBackground(isActive: true))
                        .shadow(color: theme.accentShadow, radius: 12, x: 0, y: 4)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.elevatedSurface)
                        .shadow(color: theme.subtleShadow, radius: 8, x: 0, y: 2)
                } else {
                    // 默认态不加阴影，提升滚动性能
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.surface.opacity(0.6))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isCurrentTrack ? theme.glowStroke : (isHovered ? theme.stroke : Color.clear),
                    lineWidth: isCurrentTrack ? 1.5 : 1
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func buttonColor(for file: AudioFile) -> Color {
        let buttonType = MetadataEditor.getEditButtonType(for: file.url)
        
        switch buttonType {
        case .directEdit:
            return .blue
        case .ffmpegCommand:
            return .orange
        case .notSupported:
            return .gray
        case .hidden:
            return .gray
        }
    }
    
    private func helpText(for file: AudioFile) -> String {
        let format = file.url.pathExtension.uppercased()
        let buttonType = MetadataEditor.getEditButtonType(for: file.url)
        
        switch buttonType {
        case .directEdit:
            return "编辑 \(format) 元数据"
        case .ffmpegCommand:
            return "\(format) 格式支持FFmpeg命令编辑（点击生成命令）"
        case .notSupported:
            return "\(format) 格式元数据支持有限（点击了解详情）"
        case .hidden:
            return "此格式不支持元数据编辑"
        }
    }
    
    private func highlightedText(_ text: String, searchText: String) -> AttributedString {
        guard !searchText.isEmpty else {
            return AttributedString(text)
        }
        
        var attributedString = AttributedString(text)
        
        if let range = text.range(of: searchText, options: .caseInsensitive) {
            let nsRange = NSRange(range, in: text)
            if let attributedRange = Range(nsRange, in: attributedString) {
                attributedString[attributedRange].backgroundColor = theme.accent.opacity(0.25)
                attributedString[attributedRange].foregroundColor = (colorScheme == .dark ? Color.white : Color.black)
            }
        }
        
        return attributedString
    }
}

struct EmptyPlaylistView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                theme.surface.opacity(1.0),
                                theme.surface.opacity(0.7)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "music.note.list")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.accentGradient)
                    .opacity(0.9)
            }
            
            VStack(spacing: 12) {
                Text("播放列表为空")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("将音乐文件拖拽到左侧区域来添加歌曲")
                    .font(.body)
                    .foregroundColor(theme.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.mutedSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.stroke, lineWidth: 1)
                )
                .shadow(color: theme.subtleShadow, radius: 8, x: 0, y: 4)
        )
    }
}
