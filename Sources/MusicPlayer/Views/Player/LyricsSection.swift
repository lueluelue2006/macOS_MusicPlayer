import SwiftUI

struct LyricsSection: View {
  @ObservedObject var viewModel: PlayerViewModel
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
          viewModel.showLyrics.toggle()
        } label: {
          Image(systemName: viewModel.showLyrics ? "eye" : "eye.slash")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.stageSecondaryText)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(viewModel.showLyrics ? "隐藏歌词" : "显示歌词")
      }

      if viewModel.showLyrics, let timeline = viewModel.audioPlayer.lyricsTimeline {
        Group {
          if timeline.isSynced {
            SyncedLyricsView(
              timeline: timeline,
              playbackClock: viewModel.audioPlayer.playbackClock,
              onSeek: { viewModel.seek(to: $0) }
            )
          } else {
            StaticLyricsView(timeline: timeline)
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}

struct StaticLyricsView: View {
  let timeline: LyricsTimeline
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .center, spacing: 0) {
        ForEach(timeline.lines) { line in
          Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(theme.stagePrimaryText)
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

  @State private var isUserScrolling: Bool = false
  @State private var autoFollowEnabled: Bool = true
  @State private var lastScrolledLineID: Int? = nil
  @State private var activeLineID: Int? = nil

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Button {
            if let activeLineID {
              scrollToLine(activeLineID, using: proxy)
            }
            autoFollowEnabled = true
            isUserScrolling = false
          } label: {
            Label("当前句", systemImage: "location.viewfinder")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(theme.stageSecondaryText)
              .frame(height: 26)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("定位当前歌词并恢复自动跟随")
          .accessibilityLabel("定位当前句")
          .accessibilityHint("滚动到当前歌词并开启自动跟随")

          Toggle(
            isOn: Binding(
              get: { autoFollowEnabled },
              set: { isEnabled in
                autoFollowEnabled = isEnabled
                if isEnabled {
                  isUserScrolling = false
                  if let activeLineID {
                    scrollToLine(activeLineID, using: proxy)
                  }
                }
              }
            )
          ) {
            Label(
              "自动跟随",
              systemImage: autoFollowEnabled ? "location.fill" : "location.slash"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
              autoFollowEnabled ? theme.interactiveAccent : theme.stageTertiaryText
            )
            .frame(height: 26)
            .contentShape(Rectangle())
          }
          .toggleStyle(.button)
          .buttonStyle(.plain)
          .help(autoFollowEnabled ? "自动跟随已开启；点按关闭" : "自动跟随已关闭；点按开启")
          .accessibilityLabel("自动跟随歌词")
          .accessibilityValue(autoFollowEnabled ? "已开启" : "已关闭")
          .accessibilityHint(autoFollowEnabled ? "按一下关闭自动跟随" : "按一下开启并定位当前句")

          Spacer()

          if !autoFollowEnabled {
            Text("自动跟随已关闭")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .padding(.horizontal, 4)

        ScrollView {
          LazyVStack(alignment: .center, spacing: 0) {
            ForEach(timeline.lines) { line in
              let isActive = (activeLineID == line.id)
              Text(line.text.isEmpty ? " " : line.text)
                .font(
                  isActive
                    ? AppTheme.musicDisplayFont(size: 18, weight: .semibold)
                    : .system(size: 13, weight: .regular)
                )
                .foregroundColor(isActive ? theme.accent : theme.stageSecondaryText)
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
        .simultaneousGesture(
          DragGesture()
            .onChanged { _ in
              if !isUserScrolling {
                isUserScrolling = true
                autoFollowEnabled = false
              }
            }
            .onEnded { _ in
              isUserScrolling = false
            }
        )
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
            scrollToLine(id, using: proxy)
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

  private func scrollToLine(_ id: Int, using proxy: ScrollViewProxy) {
    if reduceMotion {
      proxy.scrollTo(id, anchor: .center)
    } else {
      withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(id, anchor: .center)
      }
    }
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
