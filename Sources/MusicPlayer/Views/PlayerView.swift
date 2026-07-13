import AppKit
import SwiftUI

struct PlayerView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        FileSelectionView(showFlowingBorder: playlistManager.audioFiles.isEmpty) { urls in
          playlistManager.enqueueAddFiles(urls)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        if playlistManager.isAddingFiles {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)

              VStack(alignment: .leading, spacing: 2) {
                Text(
                  playlistManager.addFilesPhase.isEmpty ? "正在处理…" : playlistManager.addFilesPhase
                )
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

              Text(
                "\(playlistManager.addFilesProgressCurrent)/\(playlistManager.addFilesProgressTotal)"
              )
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
          .padding(.horizontal, 20)
        }
        HStack(spacing: 7) {
          Image(
            systemName: audioPlayer.isInternalSpeakerOutput ? "laptopcomputer" : "hifispeaker.fill"
          )
          .font(.caption)
          .foregroundColor(theme.mutedText)
          Text(audioPlayer.currentOutputDeviceName)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(
              audioPlayer.isInternalSpeakerOutput ? theme.mutedText : theme.accent
            )
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前音频输出设备：\(audioPlayer.currentOutputDeviceName)")

        CurrentTrackView(audioPlayer: audioPlayer, playlistManager: playlistManager)

        PlaybackControlsView(audioPlayer: audioPlayer, playlistManager: playlistManager)
          .padding(.horizontal, 20)

        AudioControlsView(audioPlayer: audioPlayer)
          .padding(.horizontal, 20)

        LyricsContainerView(audioPlayer: audioPlayer)
          .padding(.horizontal, 20)

        Spacer(minLength: 20)
      }
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
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Button(action: selectFiles) {
      HStack(spacing: 9) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(theme.accent)
        Text("添加音乐")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(theme.mutedText)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(hovering ? theme.elevatedSurface : theme.mutedSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(showFlowingBorder ? theme.accent.opacity(0.46) : theme.stroke, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .animation(AppTheme.smoothTransition, value: hovering)
    }
    .buttonStyle(PlainButtonStyle())
    .accessibilityLabel("添加音乐文件或文件夹")
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

struct CurrentTrackView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @ObservedObject private var weights = PlaybackWeights.shared
  @State private var showEphemeralTip: Bool = false
  @State private var showRatePicker: Bool = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 16) {
      if let currentFile = audioPlayer.currentFile {
        let coverContainerSize: CGFloat = 276
        let artworkSize: CGFloat = coverContainerSize

        AlbumArtworkView(image: audioPlayer.artworkImage)
          .frame(width: artworkSize, height: artworkSize)
          .frame(width: coverContainerSize, height: coverContainerSize)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(Color.white.opacity(colorScheme == .dark ? 0.13 : 0.48), lineWidth: 0.75)
          )
          .shadow(color: theme.subtleShadow, radius: 16, x: 0, y: 8)

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
        VStack(spacing: 5) {
          Text(currentFile.metadata.title)
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundColor(.primary)

          Text(currentFile.metadata.artist)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)

          Text(currentFile.metadata.album)
            .font(.system(size: 12))
            .foregroundColor(theme.mutedText)
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

          WeightDotsView(level: weights.level(for: currentFile.url, scope: weightScope())) {
            newLevel in
            weights.setLevel(newLevel, for: currentFile.url, scope: weightScope())
          }
          .padding(.vertical, 2)
          .help("随机权重（当前范围：\(weightScopeLabel())）")
        }
        .padding(.horizontal, 24)

        // 歌词来源标签（如果有歌词）
        if let timeline = audioPlayer.lyricsTimeline {
          HStack(spacing: 12) {
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
        VStack(spacing: 18) {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.mutedSurface)
            .overlay(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.stroke, lineWidth: 1)
            )
            .overlay(
              Image(systemName: "music.note")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.mutedText)
            )
            .frame(width: 230, height: 230)

          VStack(spacing: 8) {
            Text("等待播放")
              .font(.system(size: 20, weight: .semibold))
              .foregroundColor(.primary)

            Text("选择音乐文件开始聆听")
              .font(.system(size: 14))
              .foregroundColor(theme.mutedText)
          }
        }
        .frame(height: 290)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
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

  private func weightScope() -> PlaybackWeights.Scope {
    switch playlistManager.playbackScope {
    case .queue:
      return .queue
    case .playlist(let id):
      return .playlist(id)
    }
  }

  private func weightScopeLabel() -> String {
    switch playlistManager.playbackScope {
    case .queue:
      return "队列"
    case .playlist:
      return "歌单"
    }
  }

}

// MARK: - Lyrics Views

struct LyricsContainerView: View {
  @ObservedObject var audioPlayer: AudioPlayer
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
          Toggle(
            isOn: Binding(get: { audioPlayer.showLyrics }, set: { audioPlayer.showLyrics = $0 })
          ) {
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
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.mutedSurface)
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.stroke, lineWidth: 1)
            )
        )
        // 歌词面板展示区域
      }
    }
  }
}

struct StaticLyricsView: View {
  let timeline: LyricsTimeline

  var body: some View {
    ScrollView {
      // 将“行间距”做进每行的 padding，这样点击/双击不会在两行之间出现“无效区域”
      LazyVStack(alignment: .center, spacing: 0) {
        ForEach(timeline.lines) { line in
          Text(line.text.isEmpty ? " " : line.text)
            .font(.body)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 220)
  }
}

struct SyncedLyricsView: View {
  let timeline: LyricsTimeline
  let playbackClock: PlaybackClock
  let onSeek: (TimeInterval) -> Void

  // User interaction state
  @State private var isUserScrolling: Bool = false
  @State private var autoFollowEnabled: Bool = true
  @State private var lastScrolledLineID: Int? = nil
  @State private var activeLineID: Int? = nil

  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    // Place control bar and lyrics list inside one ScrollViewReader so we can scroll from the button
    ScrollViewReader { proxy in
      VStack(spacing: 8) {
        // Top control bar: locate/follow toggle and hint when paused
        HStack(spacing: 8) {
          Button {
            if let activeLineID {
              withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(activeLineID, anchor: .center)
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
          // 将“行间距”做进每行的 padding，这样双击跳转不会在两行之间出现“无效区域”
          LazyVStack(alignment: .center, spacing: 0) {
            ForEach(timeline.lines) { line in
              let isActive = (activeLineID == line.id)
              Text(line.text.isEmpty ? " " : line.text)
                .font(isActive ? .title3.bold() : .body)
                .foregroundColor(isActive ? theme.accent : .primary)
                .opacity(isActive ? 1.0 : 0.75)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 5)
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
        .onReceive(
          playbackClock.$currentTime.throttle(
            for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
        ) { t in
          let newActiveLineID = activeLineIDForTime(t)
          if newActiveLineID != activeLineID {
            activeLineID = newActiveLineID
          }
          guard autoFollowEnabled, let id = newActiveLineID else { return }
          if id != lastScrolledLineID {
            lastScrolledLineID = id
            withAnimation(.easeInOut(duration: 0.25)) {
              proxy.scrollTo(id, anchor: .center)
            }
          }
        }
        .onAppear {
          let initialActiveLineID = activeLineIDForTime(playbackClock.currentTime)
          activeLineID = initialActiveLineID
          if let initialActiveLineID {
            lastScrolledLineID = initialActiveLineID
            proxy.scrollTo(initialActiveLineID, anchor: .center)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
  }

  private func activeLineIDForTime(_ time: TimeInterval) -> Int? {
    guard let idx = timeline.currentIndex(at: time),
      idx >= 0,
      idx < timeline.lines.count
    else {
      return nil
    }
    return timeline.lines[idx].id
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
  let image: NSImage?
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .clipShape(RoundedRectangle(cornerRadius: 16))
      } else {
        RoundedRectangle(cornerRadius: 16)
          .fill(theme.mutedSurface)
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: 40, weight: .light))
              .foregroundStyle(theme.mutedText)
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
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 8) {
      Slider(
        value: $sliderValue,
        in: 0...sliderMax,
        onEditingChanged: { editing in
          isEditing = editing
          if !editing {
            onSeek(sliderValue)
          }
        }
      )
      .controlSize(.small)
      .accessibilityLabel("播放进度")
      .accessibilityValue(formatTime(isEditing ? sliderValue : playbackClock.currentTime))

      HStack {
        Text(formatTime(isEditing ? sliderValue : playbackClock.currentTime))
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundColor(theme.mutedText)
          .monospacedDigit()

        Spacer()

        Text(
          "-"
            + formatTime(
              max(0, playbackClock.duration - (isEditing ? sliderValue : playbackClock.currentTime))
            )
        )
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
