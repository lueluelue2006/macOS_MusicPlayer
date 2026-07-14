import AppKit
import SwiftUI

struct PlayerView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Label("正在播放", systemImage: "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.stageSecondaryText)

          Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)

        if playlistManager.isAddingFiles {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
                .tint(theme.accent)

              VStack(alignment: .leading, spacing: 2) {
                Text(
                  playlistManager.addFilesPhase.isEmpty ? "正在处理…" : playlistManager.addFilesPhase
                )
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(theme.stagePrimaryText)

                if !playlistManager.addFilesDetail.isEmpty {
                  Text(playlistManager.addFilesDetail)
                    .font(.caption2)
                    .foregroundColor(theme.stageSecondaryText)
                    .lineLimit(1)
                }
              }

              Spacer()

              Button("取消") {
                playlistManager.cancelAddFiles()
              }
              .font(.caption)
              .buttonStyle(.borderless)
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
              .foregroundColor(theme.stageSecondaryText)
            } else if playlistManager.addFilesProgressCurrent > 0 {
              Text("已发现 \(playlistManager.addFilesProgressCurrent) 首")
                .font(.caption2)
                .foregroundColor(theme.stageSecondaryText)
            }
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(theme.surface)
          )
          .padding(.horizontal, 24)
          .padding(.bottom, 16)
        }

        CurrentTrackView(audioPlayer: audioPlayer, playlistManager: playlistManager)

        PlaybackControlsView(audioPlayer: audioPlayer, playlistManager: playlistManager)
          .padding(.horizontal, 28)
          .padding(.top, 20)

        AudioControlsView(audioPlayer: audioPlayer)
          .padding(.horizontal, 28)
          .padding(.top, 20)

        if audioPlayer.lyricsTimeline != nil {
          Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
            .padding(.horizontal, 28)
            .padding(.top, 24)

          LyricsContainerView(audioPlayer: audioPlayer)
            .padding(.horizontal, 24)
            .padding(.top, 18)
        }

        HStack(spacing: 7) {
          Image(
            systemName: audioPlayer.isInternalSpeakerOutput ? "laptopcomputer" : "hifispeaker.fill"
          )
          .font(.system(size: 11, weight: .medium))

          Text(audioPlayer.currentOutputDeviceName)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)

          Spacer(minLength: 0)
        }
        .foregroundStyle(theme.stageTertiaryText)
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前音频输出设备：\(audioPlayer.currentOutputDeviceName)")
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
  let isLibraryEmpty: Bool
  let onFilesSelected: ([URL]) -> Void
  @State private var hovering = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    Button(action: selectFiles) {
      HStack(spacing: 7) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 12, weight: .semibold))
        Text(isLibraryEmpty ? "添加音乐" : "导入")
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(theme.accentForeground)
      .padding(.vertical, 7)
      .padding(.horizontal, 11)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(hovering ? theme.accent.opacity(0.86) : theme.accent)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let currentFile = audioPlayer.currentFile {
        AlbumArtworkView(
          image: audioPlayer.artworkImage,
          title: currentFile.metadata.title,
          artist: currentFile.metadata.artist
        )
          .frame(width: 300, height: 300)
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .stroke(theme.stroke, lineWidth: 0.75)
          )
          .shadow(color: Color.black.opacity(0.42), radius: 18, x: 0, y: 10)
          .frame(maxWidth: .infinity)

        if audioPlayer.persistPlaybackState == false {
          HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
              .font(.caption)
            Text("临时播放")
              .font(.caption)
              .fontWeight(.semibold)
            Text("关闭窗口后不会保存进度")
              .font(.caption)
              .foregroundStyle(theme.stageSecondaryText)
          }
          .foregroundColor(Color.orange.opacity(0.92))
          .padding(.top, 16)
          .help("通过 Finder/Dock 打开的临时播放：关闭应用或再次以临时方式打开其他歌曲都会丢失当前进度")
        }

        VStack(alignment: .leading, spacing: 5) {
          Text(currentFile.metadata.title)
            .font(.system(size: 26, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .foregroundColor(theme.stagePrimaryText)

          Text(currentFile.metadata.artist)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(theme.stageSecondaryText)
            .lineLimit(1)

          Text(currentFile.metadata.album)
            .font(.system(size: 12))
            .foregroundColor(theme.stageTertiaryText)
            .lineLimit(1)
        }
        .padding(.top, 20)

        ProgressSliderView(
          playbackClock: audioPlayer.playbackClock,
          playbackStart: audioPlayer.effectivePlaybackStartTime,
          playbackEnd: audioPlayer.effectivePlaybackEndTime,
          onSeek: { audioPlayer.seek(to: $0) }
        )
        .padding(.top, 17)

        HStack(spacing: 18) {
          Menu {
            let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
            ForEach(rates, id: \.self) { rate in
              Button {
                audioPlayer.setPlaybackRate(rate)
              } label: {
                if abs(audioPlayer.playbackRate - rate) < 0.001 {
                  Label(String(format: "%.2f×", rate), systemImage: "checkmark")
                } else {
                  Text(String(format: "%.2f×", rate))
                }
              }
            }
            Divider()
            Button("重置为 1.00×") { audioPlayer.setPlaybackRate(1.0) }
          } label: {
            Label(String(format: "%.2f×", audioPlayer.playbackRate), systemImage: "speedometer")
              .font(.system(size: 11, weight: .medium))
          }
          .buttonStyle(.plain)
          .help("播放速度")

          Menu {
            ForEach(PlaybackWeights.Level.allCases, id: \.rawValue) { level in
              Button {
                weights.setLevel(level, for: currentFile.url, scope: weightScope())
              } label: {
                if weights.level(for: currentFile.url, scope: weightScope()) == level {
                  Label(weightLabel(level), systemImage: "checkmark")
                } else {
                  Text(weightLabel(level))
                }
              }
            }
          } label: {
            Label(
              weightValueLabel(weights.level(for: currentFile.url, scope: weightScope())),
              systemImage: "dial.medium"
            )
            .font(.system(size: 11, weight: .medium))
          }
          .buttonStyle(.plain)
          .help(
            "随机权重：\(weightLabel(weights.level(for: currentFile.url, scope: weightScope())))（范围：\(weightScopeLabel())）"
          )
          .accessibilityLabel("随机权重")
          .accessibilityValue(
            "\(weightLabel(weights.level(for: currentFile.url, scope: weightScope())))，范围：\(weightScopeLabel())"
          )

          Button {
            playRandomTrack()
          } label: {
            Image(systemName: "die.face.5")
              .font(.system(size: 12, weight: .medium))
              .frame(width: 22, height: 22)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(
            playlistManager.playbackScopePlayableCount() < 2
              || audioPlayer.persistPlaybackState == false
          )
          .help(audioPlayer.persistPlaybackState == false ? "临时播放模式下不可切歌" : "随机选一首")

          Spacer()

          if audioPlayer.lyricsTimeline != nil {
            Label("歌词已载入", systemImage: "text.quote")
              .font(.system(size: 11, weight: .medium))
          }
        }
        .foregroundStyle(theme.stageTertiaryText)
        .padding(.top, 12)

      } else {
        VStack(alignment: .leading, spacing: 18) {
          AlbumArtworkView(image: nil, title: "MusicPlayer", artist: "本地音乐")
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.38), radius: 18, x: 0, y: 10)

          VStack(alignment: .leading, spacing: 6) {
            Text("等待播放")
              .font(.system(size: 26, weight: .semibold))
              .foregroundColor(theme.stagePrimaryText)

            Text("添加音乐，开始你的本地唱片架")
              .font(.system(size: 14))
              .foregroundColor(theme.stageSecondaryText)
          }
        }
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .frame(maxWidth: 320)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
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

  private func weightLabel(_ level: PlaybackWeights.Level) -> String {
    let value = weightValueLabel(level)
    return level == .defaultLevel ? "\(value)（默认）" : value
  }

  private func weightValueLabel(_ level: PlaybackWeights.Level) -> String {
    "档位 \(level.rawValue) · \(String(format: "%.1f", level.multiplier))×"
  }

  private func playRandomTrack() {
    guard audioPlayer.persistPlaybackState else { return }
    if let randomFile = playlistManager.getRandomFileExcludingCurrent() {
      audioPlayer.play(randomFile)
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
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.stageSecondaryText)
        Spacer()
        Button {
          audioPlayer.showLyrics.toggle()
        } label: {
          Image(systemName: audioPlayer.showLyrics ? "eye" : "eye.slash")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.stageSecondaryText)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(audioPlayer.showLyrics ? "隐藏歌词" : "显示歌词")
      }

      if audioPlayer.showLyrics {
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
            Label("当前句", systemImage: "location.viewfinder")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(theme.accent)
              .frame(height: 26)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          Button {
            autoFollowEnabled.toggle()
            if autoFollowEnabled {
              isUserScrolling = false
              if let activeLineID {
                proxy.scrollTo(activeLineID, anchor: .center)
              }
            }
          } label: {
            Label(
              "自动跟随",
              systemImage: autoFollowEnabled ? "location.fill" : "location.slash"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(
              autoFollowEnabled ? theme.stageSecondaryText : theme.stageTertiaryText
            )
            .frame(height: 26)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

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

struct AlbumArtworkView: View {
  let image: NSImage?
  let title: String
  let artist: String

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        GeometryReader { proxy in
          let side = min(proxy.size.width, proxy.size.height)
          ZStack(alignment: .topLeading) {
            Color(red: 0.94, green: 0.36, blue: 0.31)

            Circle()
              .fill(Color.black.opacity(0.88))
              .frame(width: side * 0.80, height: side * 0.80)
              .overlay {
                ZStack {
                  ForEach(1..<7, id: \.self) { ring in
                    Circle()
                      .stroke(Color.white.opacity(0.055), lineWidth: 1)
                      .padding(CGFloat(ring) * side * 0.035)
                  }
                  Circle()
                    .fill(Color(red: 0.98, green: 0.71, blue: 0.35))
                    .frame(width: side * 0.19, height: side * 0.19)
                  Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: side * 0.035, height: side * 0.035)
                }
              }
              .offset(x: side * 0.41, y: side * 0.31)

            VStack(alignment: .leading, spacing: 3) {
              Text(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
                .font(.system(size: side * 0.30, weight: .black, design: .rounded))
                .tracking(-3)
                .foregroundStyle(Color.black.opacity(0.88))
                .lineLimit(1)

              Text(artist.isEmpty ? "LOCAL RECORDS" : artist.uppercased())
                .font(.system(size: max(9, side * 0.035), weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.black.opacity(0.68))
                .lineLimit(1)
            }
            .padding(side * 0.08)
            .frame(width: side * 0.63, alignment: .leading)
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image == nil ? "\(title) 的唱片封面占位图" : "\(title) 的专辑封面")
  }
}

struct ProgressSliderView: View {
  @ObservedObject var playbackClock: PlaybackClock
  let playbackStart: TimeInterval
  let playbackEnd: TimeInterval
  let onSeek: (TimeInterval) -> Void
  @State private var isEditing = false
  @State private var sliderValue: Double = 0
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(spacing: 8) {
      Slider(
        value: $sliderValue,
        in: sliderMin...sliderMax,
        onEditingChanged: { editing in
          isEditing = editing
          if !editing {
            onSeek(sliderValue)
          }
        }
      )
      .controlSize(.small)
      .tint(theme.accent)
      .accessibilityLabel("播放进度")
      .accessibilityValue(formatTime(displayedElapsedTime))

      HStack {
        Text(formatTime(displayedElapsedTime))
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundColor(theme.mutedText)
          .monospacedDigit()

        Spacer()

        Text(
          "-"
            + formatTime(
              max(0, sliderMax - displayedAbsoluteTime)
            )
        )
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundColor(theme.mutedText)
        .monospacedDigit()
      }
    }
    .onAppear {
      sliderValue = clamp(playbackClock.currentTime, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackClock.currentTime) { newTime in
      guard !isEditing else { return }
      sliderValue = clamp(newTime, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackClock.duration) { _ in
      sliderValue = clamp(sliderValue, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackStart) { _ in
      sliderValue = clamp(playbackClock.currentTime, min: sliderMin, max: sliderMax)
    }
    .onChange(of: playbackEnd) { _ in
      sliderValue = clamp(playbackClock.currentTime, min: sliderMin, max: sliderMax)
    }
  }

  private var sliderMin: Double {
    guard playbackStart.isFinite, playbackStart >= 0 else { return 0 }
    return min(playbackStart, max(0, playbackClock.duration))
  }

  private var sliderMax: Double {
    let physicalEnd = max(playbackClock.duration, sliderMin + 0.001)
    guard playbackEnd.isFinite, playbackEnd > sliderMin else { return physicalEnd }
    return min(playbackEnd, physicalEnd)
  }

  private var displayedAbsoluteTime: TimeInterval {
    isEditing ? sliderValue : playbackClock.currentTime
  }

  private var displayedElapsedTime: TimeInterval {
    max(0, displayedAbsoluteTime - sliderMin)
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
