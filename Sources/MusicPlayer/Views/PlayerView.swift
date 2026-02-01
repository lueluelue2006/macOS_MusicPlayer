import SwiftUI
import Combine
import AppKit

struct PlayerView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 文件选择按钮
                FileSelectionView(showFlowingBorder: playlistManager.audioFiles.isEmpty) { urls in
                    playlistManager.enqueueAddFiles(urls)
                }
                .padding(.horizontal)

                // 导入/扫描进度（可取消）
                if playlistManager.isAddingFiles {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlistManager.addFilesPhase.isEmpty ? "正在处理…" : playlistManager.addFilesPhase)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)

                                if !playlistManager.addFilesDetail.isEmpty {
                                    Text(playlistManager.addFilesDetail)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Button("取消") {
                                playlistManager.cancelAddFiles()
                            }
                            .font(.caption)
                        }

                        if playlistManager.addFilesProgressTotal > 0 {
                            ProgressView(
                                value: Double(playlistManager.addFilesProgressCurrent),
                                total: Double(playlistManager.addFilesProgressTotal)
                            )
                            .controlSize(.small)

                            Text("\(playlistManager.addFilesProgressCurrent)/\(playlistManager.addFilesProgressTotal)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if playlistManager.addFilesProgressCurrent > 0 {
                            Text("已发现 \(playlistManager.addFilesProgressCurrent) 首")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(theme.mutedSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(theme.accent.opacity(0.22), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal)
                }
                // 在文件/文件夹选择按钮下方展示当前音频输出设备
                HStack {
                    Text("当前音频输出设备：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(audioPlayer.currentOutputDeviceName)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(
                            audioPlayer.isInternalSpeakerOutput ? theme.mutedText : theme.accent
                        )
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                // 当前播放信息
                CurrentTrackView(audioPlayer: audioPlayer)
                
                // 歌词显示/切换（不再通过悬停禁用外层滚动，避免“被限制住”的体验）
                LyricsContainerView(audioPlayer: audioPlayer)
                    .padding(.horizontal, 24)
                
                // 播放控制
                PlaybackControlsView(audioPlayer: audioPlayer, playlistManager: playlistManager)
                
                // 音量和音频效果控制
                AudioControlsView(audioPlayer: audioPlayer)
                
                Spacer(minLength: 20)
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 在播放器区域任意位置点击时，取消搜索框聚焦
            NotificationCenter.default.post(name: .blurSearchField, object: nil)
        }
        // 移除基于悬停禁用外层滚动的逻辑，恢复更直觉的滚动行为
    }
}

struct FileSelectionView: View {
    let showFlowingBorder: Bool
    let onFilesSelected: ([URL]) -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    
    var body: some View {
        Button(action: selectFiles) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.45), radius: 3, x: 0, y: 2)
                Text("选择音乐文件或文件夹")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.45), radius: 3, x: 0, y: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(
                theme.accentGradient
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .overlay(
                Group {
                    if showFlowingBorder {
                        FlowingBorder(
                            cornerRadius: 16,
                            lineWidth: hovering ? 2.4 : 2.0,
                            base: theme.accent,
                            secondary: theme.accentSecondary,
                            enabled: !reduceMotion
                        )
                        .opacity(hovering ? 1.0 : 0.92)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                }
            )
            .shadow(color: theme.subtleShadow, radius: 10, x: 0, y: 5)
            .scaleEffect(hovering ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering in
            hovering = isHovering
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        
        if panel.runModal() == .OK {
            onFilesSelected(panel.urls)
        }
    }
}

struct FlowingBorder: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let base: Color
    let secondary: Color
    let enabled: Bool
    // One full cycle duration. Larger = slower flow.
    var period: TimeInterval = 10.4
    var phaseOffset: Double = 0

    var body: some View {
        if enabled {
            TimelineView(.animation) { timeline in
                let angle = rotationAngle(for: timeline.date)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(gradient(angle: angle), lineWidth: lineWidth)
            }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(gradient(angle: 0), lineWidth: lineWidth)
        }
    }

    private func rotationAngle(for date: Date) -> Double {
        guard period > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / period + phaseOffset).truncatingRemainder(dividingBy: 1)
        return phase * 360
    }

    private func gradient(angle: Double) -> AngularGradient {
        let glowA = base.opacity(0.95)
        let glowB = secondary.opacity(0.95)

        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.40),
                .init(color: glowA, location: 0.47),
                .init(color: .white.opacity(0.95), location: 0.50),
                .init(color: glowB, location: 0.53),
                .init(color: .clear, location: 0.60),
                .init(color: .clear, location: 1.00),
            ]),
            center: .center,
            startAngle: .degrees(angle),
            endAngle: .degrees(angle + 360)
        )
    }
}

struct CurrentTrackView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @State private var showEphemeralTip: Bool = false
    @State private var showRatePicker: Bool = false
    @State private var glowRotation: Double = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 20) {
            if let currentFile = audioPlayer.currentFile {
                let coverContainerSize: CGFloat = 300
                let artworkSize: CGFloat = coverContainerSize

                // 专辑封面
                ZStack {
                    // 动态光晕背景（播放时旋转）
                    if audioPlayer.isPlaying {
                        // 外层彩色光晕
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: [
                                        theme.accent.opacity(0.5),
                                        theme.accentSecondary.opacity(0.4),
                                        theme.accentTertiary.opacity(0.3),
                                        theme.accent.opacity(0.5)
                                    ],
                                    center: .center,
                                    startAngle: .degrees(0),
                                    endAngle: .degrees(360)
                                )
                            )
                            .frame(width: coverContainerSize - 40, height: coverContainerSize - 40)
                            .blur(radius: 40)
                            .rotationEffect(.degrees(glowRotation))
                            .opacity(0.6)
                    }

                    // 主封面
                    AlbumArtworkView(artwork: currentFile.metadata.artwork, cacheKey: currentFile.url.path, isPlaying: audioPlayer.isPlaying)
                        .frame(width: artworkSize, height: artworkSize)
                        .shadow(color: audioPlayer.isPlaying ? theme.accentShadow : theme.subtleShadow, radius: audioPlayer.isPlaying ? 20 : 12, x: 0, y: 8)
                }
                .frame(width: coverContainerSize, height: coverContainerSize)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(
                    FlowingBorder(
                        cornerRadius: 24,
                        lineWidth: 2.0,
                        base: theme.accent,
                        secondary: theme.accentSecondary,
                        enabled: audioPlayer.isPlaying && !reduceMotion
                    )
                    .opacity(audioPlayer.isPlaying ? 0.9 : 0)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.3), value: audioPlayer.isPlaying)
                )
                .onAppear {
                    if audioPlayer.isPlaying {
                        startGlowAnimation()
                    }
                }
                .onChange(of: audioPlayer.isPlaying) { playing in
                    if playing {
                        startGlowAnimation()
                    }
                }

                // 临时播放标注：提示关闭或再次临时打开会丢失当前进度
                if audioPlayer.persistPlaybackState == false {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                        Text("临时播放 · 关闭或再次临时打开将丢失进度")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundColor(Color.orange)
                    .help("通过 Finder/Dock 打开的临时播放：关闭应用或再次以临时方式打开其他歌曲都会丢失当前进度")
                }

                // 进入临时播放时的临时提示条（数秒自动消失）
                if showEphemeralTip {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("临时播放：关闭应用或再次临时打开其他歌曲将丢失当前进度")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                    .foregroundColor(Color.orange)
                    .transition(.opacity)
                }
                
                // 歌曲信息
                VStack(spacing: 8) {
                    Text(currentFile.metadata.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                    
                    Text(currentFile.metadata.artist)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text(currentFile.metadata.album)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
                
                // 进度条
                ProgressSliderView(
                    playbackClock: audioPlayer.playbackClock,
                    onSeek: { audioPlayer.seek(to: $0) }
                )
                    .padding(.horizontal, 24)

                // 倍速选择（也可由 CLI 设置；重启默认恢复 1.0×）
                let isNormalRate = abs(audioPlayer.playbackRate - 1.0) < 0.001
                HStack {
                    Button {
                        let clickCount = NSApp.currentEvent?.clickCount ?? 1
                        if clickCount >= 2 {
                            audioPlayer.setPlaybackRate(1.0)
                            showRatePicker = false
                        } else {
                            showRatePicker.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(format: "倍速 %.2f×", audioPlayer.playbackRate))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(isNormalRate ? theme.mutedText : theme.accent)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundColor(theme.mutedText)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surface.opacity(0.6)))
                        .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("单击选择倍速；双击重置为 1.00×（重启恢复 1.0×）")
                    .popover(isPresented: $showRatePicker, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("倍速")
                                .font(.headline)

                            let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
                            ForEach(rates, id: \.self) { rate in
                                Button {
                                    audioPlayer.setPlaybackRate(rate)
                                    showRatePicker = false
                                } label: {
                                    if abs(audioPlayer.playbackRate - rate) < 0.001 {
                                        Label(String(format: "%.2f×", rate), systemImage: "checkmark")
                                    } else {
                                        Text(String(format: "%.2f×", rate))
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(minWidth: 160)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                
                // 歌词来源与显示控制（如果有歌词）
                if let timeline = audioPlayer.lyricsTimeline {
                    HStack(spacing: 12) {
                        // 显示/隐藏开关
                        Toggle(isOn: Binding(get: { audioPlayer.showLyrics }, set: { audioPlayer.showLyrics = $0 })) {
                            Text("显示歌词")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .toggleStyle(SwitchToggleStyle())
                        
                        // 来源标签
                        Text(sourceLabel(for: timeline.source))
                            .font(.caption)
                            .foregroundColor(theme.mutedText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(theme.surface.opacity(0.6))
                            )
                        
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }
                
            } else {
                VStack(spacing: 24) {
                    ZStack {
                        // 微妙的光晕背景
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        theme.accent.opacity(0.08),
                                        theme.accentSecondary.opacity(0.04),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 60,
                                    endRadius: 120
                                )
                            )
                            .frame(width: 240, height: 240)
                            .blur(radius: 20)

                        // 主圆形容器
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .fill(theme.surface.opacity(0.5))
                            )
                            .overlay(
                                Circle()
                                    .stroke(theme.stroke, lineWidth: 1)
                            )
                            .frame(width: 180, height: 180)
                            .shadow(color: theme.subtleShadow, radius: 16, x: 0, y: 8)

                        // 音符图标
                        Image(systemName: "music.note")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(theme.accentGradient)
                    }

                    VStack(spacing: 8) {
                        Text("等待播放")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)

                        Text("选择音乐文件开始聆听")
                            .font(.system(size: 14))
                            .foregroundColor(theme.mutedText)
                    }
                }
                .frame(height: 300)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.elevatedSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.stroke, lineWidth: 1)
                )
                .shadow(color: theme.subtleShadow, radius: 12, x: 0, y: 6)
        )
        .onChange(of: audioPlayer.currentFile?.url) { _ in
            if audioPlayer.persistPlaybackState == false {
                showEphemeralTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    withAnimation { showEphemeralTip = false }
                }
            } else {
                showEphemeralTip = false
            }
        }
    }

    private func startGlowAnimation() {
        glowRotation = 0
        withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) {
            glowRotation = 360
        }
    }
}

// MARK: - Lyrics Views

struct LyricsContainerView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @State private var expanded: Bool = true
    var onHoverChange: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("歌词", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                // 仅在存在歌词时间轴时提供“显示/隐藏”开关
                if audioPlayer.lyricsTimeline != nil {
                    Toggle(isOn: Binding(get: { audioPlayer.showLyrics }, set: { audioPlayer.showLyrics = $0 })) {
                        Text(audioPlayer.showLyrics ? "显示" : "隐藏")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(SwitchToggleStyle())
                }
            }
            .padding(.horizontal, 8)

            // 无歌词：不显示歌词面板，仅展示“暂无歌词”，且不拦截滚动/悬停
            if audioPlayer.lyricsTimeline == nil {
                Text("暂无歌词")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            } else if audioPlayer.showLyrics {
                Group {
	                    if let timeline = audioPlayer.lyricsTimeline {
	                        if timeline.isSynced {
	                            SyncedLyricsView(
	                                timeline: timeline,
	                                playbackClock: audioPlayer.playbackClock,
	                                onSeek: { audioPlayer.seek(to: $0) }
	                            )
	                        } else {
	                            StaticLyricsView(timeline: timeline)
	                        }
	                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                        .shadow(color: theme.subtleShadow, radius: 6, x: 0, y: 2)
                )
                // 仅当展示实际歌词面板时才触发悬停（从而禁用外层滚动）
                .onHover { hovering in
                    onHoverChange?(hovering)
                }
            }
        }
    }
}

struct StaticLyricsView: View {
    let timeline: LyricsTimeline
    
    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 8) {
                ForEach(timeline.lines) { line in
                    Text(line.text)
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 220)
    }
}

	struct SyncedLyricsView: View {
	    let timeline: LyricsTimeline
	    @ObservedObject var playbackClock: PlaybackClock
	    let onSeek: (TimeInterval) -> Void

    // User interaction state
	    @State private var isUserScrolling: Bool = false
	    @State private var autoFollowEnabled: Bool = true
	    @State private var lastScrolledLineID: Int? = nil

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        // Place control bar and lyrics list inside one ScrollViewReader so we can scroll from the button
        ScrollViewReader { proxy in
            VStack(spacing: 8) {
                // Top control bar: locate/follow toggle and hint when paused
                HStack(spacing: 8) {
                    Button {
                        if let idx = timeline.currentIndex(at: playbackClock.currentTime),
                           idx >= 0, idx < timeline.lines.count {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                let id = timeline.lines[idx].id
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                        autoFollowEnabled = true
                        isUserScrolling = false
                    } label: {
                        Label("定位当前句", systemImage: "location.viewfinder")
                    }
                    .buttonStyle(.bordered)

                    Toggle(isOn: $autoFollowEnabled) {
                        Text("自动跟随")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.switch)

                    Spacer()

                    if isUserScrolling && !autoFollowEnabled {
                        Text("已暂停自动跟随")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 4)

                // Lyrics list with programmatic scroll — 默认渲染完整歌词
	                ScrollView {
	                    LazyVStack(alignment: .center, spacing: 10) {
	                        let activeLineID: Int? = {
	                            guard let idx = timeline.currentIndex(at: playbackClock.currentTime),
	                                  idx >= 0, idx < timeline.lines.count else { return nil }
	                            return timeline.lines[idx].id
	                        }()
	                        ForEach(timeline.lines) { line in
	                            let isActive = (activeLineID == line.id)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(isActive ? .title3.bold() : .body)
                                .foregroundColor(isActive ? theme.accent : .primary)
                                .opacity(isActive ? 1.0 : 0.75)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .contentShape(Rectangle())
                                .id(line.id)
                                .onTapGesture(count: 2) {
                                    if let t = line.timestamp {
                                        onSeek(t)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
                // Detect user scrolling: mark on any drag start/end.
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { _ in
                            if !isUserScrolling {
                                isUserScrolling = true
                                autoFollowEnabled = false
                            }
                        }
                        .onEnded { _ in
                            // 结束拖拽后仅结束"正在滚动"态，不自动恢复跟随
                            isUserScrolling = false
                        }
                )
                // 使用更快的节流频率（100ms）以提升同步跟随流畅度
                .onReceive(playbackClock.$currentTime.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)) { t in
                    guard autoFollowEnabled else { return }
                    let newIndex = timeline.currentIndex(at: t)
                    guard let idx = newIndex, idx >= 0, idx < timeline.lines.count else { return }
                    let id = timeline.lines[idx].id
                    if id != lastScrolledLineID {
                        lastScrolledLineID = id
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let idx = timeline.currentIndex(at: playbackClock.currentTime),
                       idx >= 0, idx < timeline.lines.count {
                        proxy.scrollTo(timeline.lines[idx].id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
    }
}

private func sourceLabel(for source: LyricsSource) -> String {
   switch source {
   case .embeddedUnsynced: return "来源: 内嵌(静态)"
   case .embeddedSynced: return "来源: 内嵌(动态)"
   case .sidecarLRC(let url): return "来源: LRC (\(url.lastPathComponent))"
   case .manual: return "来源: 手动"
   }
}

struct AlbumArtworkView: View {
    let artwork: Data?
    let cacheKey: String
    var isPlaying: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        Group {
            if let artwork = artwork,
               let nsImage = ArtworkCache.shared.image(for: cacheKey, data: artwork, targetSize: CGSize(width: 220, height: 220)) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                // 无封面时的优雅占位符
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.surface.opacity(0.5))
                    .overlay(
                        ZStack {
                            Circle()
                                .fill(theme.accentGradient.opacity(0.15))
                                .frame(width: 80, height: 80)
                            Image(systemName: "music.note")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(theme.accentGradient)
                        }
                    )
            }
        }
    }
}

struct ProgressSliderView: View {
    @ObservedObject var playbackClock: PlaybackClock
    let onSeek: (TimeInterval) -> Void
    @State private var isEditing = false
    @State private var sliderValue: Double = 0
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 14) {
            // 自定义进度条
            GeometryReader { geometry in
                let progress = sliderMax > 0 ? sliderValue / sliderMax : 0
                let progressWidth = geometry.size.width * CGFloat(progress)

                ZStack(alignment: .leading) {
                    // 背景轨道
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.mutedSurface)
                        .frame(height: isHovering || isEditing ? 8 : 6)

                    // 进度填充（渐变）
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.progressGradient)
                        .frame(width: max(0, progressWidth), height: isHovering || isEditing ? 8 : 6)
                        .shadow(color: theme.accentShadow, radius: isHovering || isEditing ? 6 : 3, x: 0, y: 0)

                    // 进度指示器（圆点）
                    Circle()
                        .fill(.white)
                        .frame(width: isHovering || isEditing ? 16 : 12, height: isHovering || isEditing ? 16 : 12)
                        .shadow(color: theme.accent.opacity(0.5), radius: 4, x: 0, y: 2)
                        .overlay(
                            Circle()
                                .fill(theme.progressGradient)
                                .frame(width: isHovering || isEditing ? 10 : 6, height: isHovering || isEditing ? 10 : 6)
                        )
                        .offset(x: max(0, min(progressWidth - (isHovering || isEditing ? 8 : 6), geometry.size.width - (isHovering || isEditing ? 16 : 12))))
                        .opacity(isHovering || isEditing ? 1 : 0.8)
                }
                .frame(height: isHovering || isEditing ? 16 : 12)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isEditing = true
                            let newProgress = max(0, min(1, value.location.x / geometry.size.width))
                            sliderValue = newProgress * sliderMax
                        }
                        .onEnded { _ in
                            isEditing = false
                            onSeek(sliderValue)
                        }
                )
                .onHover { hovering in
                    withAnimation(AppTheme.quickSpring) {
                        isHovering = hovering
                    }
                }
            }
            .frame(height: 16)

            HStack {
                Text(formatTime(isEditing ? sliderValue : playbackClock.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(theme.mutedText)
                    .monospacedDigit()

                Spacer()

                Text("-" + formatTime(max(0, playbackClock.duration - (isEditing ? sliderValue : playbackClock.currentTime))))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(theme.mutedText)
                    .monospacedDigit()
            }
        }
        .onAppear {
            sliderValue = clamp(playbackClock.currentTime, min: 0, max: sliderMax)
        }
        .onChange(of: playbackClock.currentTime) { newTime in
            guard !isEditing else { return }
            sliderValue = clamp(newTime, min: 0, max: sliderMax)
        }
        .onChange(of: playbackClock.duration) { _ in
            sliderValue = clamp(sliderValue, min: 0, max: sliderMax)
        }
        .animation(AppTheme.quickSpring, value: isHovering)
        .animation(AppTheme.quickSpring, value: isEditing)
    }

    private var sliderMax: Double {
        max(playbackClock.duration, 1)
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
