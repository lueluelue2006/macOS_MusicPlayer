import SwiftUI

struct TrackRowView: View {
  let trackNumber: Int
  let file: AudioFile
  let isCurrentTrack: Bool
  let isVolumeAnalyzed: Bool
  let unplayableReason: String?
  let searchText: String
  let playAction: (AudioFile) -> Void
  let deleteAction: (AudioFile) -> Void
  let editAction: (AudioFile) -> Void
  let weightLevel: PlaybackWeights.Level
  let onWeightSelect: (PlaybackWeights.Level) -> Void
  var weightScopeLabel: String = "歌单"
  @State private var isHovered = false
  @State private var isPlaybackRegionHovered = false
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(isCurrentTrack ? theme.accent : Color.clear)
        .frame(width: 3, height: 34)
        .padding(.trailing, 11)

      HStack(spacing: 11) {
        Button {
          playAction(file)
        } label: {
          HStack(spacing: 11) {
            Group {
              if unplayableReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 11, weight: .semibold))
              } else if isPlaybackRegionHovered {
                Image(systemName: "play.fill")
                  .font(.system(size: 11, weight: .semibold))
              } else {
                Text(String(format: "%02d", trackNumber))
                  .font(.system(size: 11, weight: .medium, design: .rounded))
                  .monospacedDigit()
              }
            }
            .foregroundStyle(leadingColor)
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 7) {
                Text(highlightedText(file.metadata.title, searchText: searchText))
                  .font(.system(size: 13, weight: .semibold))
                  .lineLimit(1)
                  .foregroundStyle(unplayableReason == nil ? Color.primary : Color.secondary)

                if isVolumeAnalyzed {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.mutedText.opacity(0.72))
                    .help("音量均衡已分析")
                    .accessibilityLabel("音量均衡已分析")
                }
              }

              Text(
                "\(highlightedText(file.metadata.artist, searchText: searchText)) · \(highlightedText(file.metadata.album, searchText: searchText))"
              )
              .font(.system(size: 11))
              .foregroundColor(theme.mutedText)
              .lineLimit(1)
              .help(file.url.lastPathComponent)
            }

            Spacer(minLength: 10)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(trackAccessibilityLabel)
        .accessibilityHint(unplayableReason.map { "不可播放：\($0)" } ?? "播放歌曲")
        .accessibilityAddTraits(isCurrentTrack ? .isSelected : [])
        .onHover { hovering in
          isPlaybackRegionHovered = hovering
        }

        WeightBlocksCompact(
          level: weightLevel,
          scopeLabel: weightScopeLabel,
          itemLabel: file.metadata.title
        ) { newLevel in
          onWeightSelect(newLevel)
        }
        .padding(.horizontal, 4)
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(2)

        Text(durationLabel)
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .foregroundColor(theme.mutedText.opacity(file.duration == nil ? 0.55 : 0.9))
          .frame(width: 42, alignment: .trailing)
          .accessibilityLabel(file.duration == nil ? "时长加载中" : "时长 \(durationLabel)")
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 2) {
        Button(action: { editAction(file) }) {
          Image(systemName: "pencil")
            .foregroundColor(buttonColor(for: file))
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!MetadataEditor.canShowEditButton(for: file.url))
        .help(helpText(for: file))

        Button(action: { deleteAction(file) }) {
          Image(systemName: "trash")
            .foregroundColor(theme.destructive)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("从列表移除")
      }
      .padding(.leading, 4)
      .opacity(isHovered ? 1 : 0)
      .allowsHitTesting(isHovered)
      .animation(AppTheme.smoothTransition, value: isHovered)
    }
    .padding(.horizontal, 8)
    .frame(minHeight: 54)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isCurrentTrack
            ? theme.selectedSurface
            : (isHovered ? theme.hoverSurface : Color.clear)
        )
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(isCurrentTrack || isHovered ? Color.clear : theme.paneDivider)
        .frame(height: 1)
        .padding(.leading, 46)
    }
    .onHover { hovering in
      isHovered = hovering
    }
    .contextMenu {
      Menu("随机权重") {
        ForEach(PlaybackWeights.Level.allCases, id: \.rawValue) { level in
          Button {
            onWeightSelect(level)
          } label: {
            if level == weightLevel {
              Label(weightLabel(level), systemImage: "checkmark")
            } else {
              Text(weightLabel(level))
            }
          }
        }
      }

      Divider()

      if MetadataEditor.canShowEditButton(for: file.url) {
        Button("编辑元数据…") {
          editAction(file)
        }

        Divider()
      }

      Button("从列表移除", role: .destructive) {
        deleteAction(file)
      }
    }
  }

  private var trackAccessibilityLabel: String {
    [file.metadata.title, file.metadata.artist, file.metadata.album]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "，")
  }

  private var leadingColor: Color {
    if isCurrentTrack { return theme.accent }
    if unplayableReason != nil { return theme.warning }
    return isPlaybackRegionHovered ? theme.stagePrimaryText : theme.stageTertiaryText
  }

  private func weightLabel(_ level: PlaybackWeights.Level) -> String {
    let value = weightValueLabel(level)
    return level == .defaultLevel ? "\(value)（默认）" : value
  }

  private func weightValueLabel(_ level: PlaybackWeights.Level) -> String {
    "第 \(level.rawValue + 1) 档 · \(String(format: "%.1f", level.multiplier))×"
  }

  private func buttonColor(for file: AudioFile) -> Color {
    let buttonType = MetadataEditor.getEditButtonType(for: file.url)

    switch buttonType {
    case .directEdit, .ffmpegCommand:
      return theme.stageSecondaryText
    case .notSupported, .hidden:
      return theme.disabledText
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

  private var durationLabel: String {
    guard let seconds = file.duration else { return "--:--" }
    return formatDuration(seconds)
  }

  private func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "--:--" }
    let total = Int(seconds.rounded(.towardZero))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
  }

  private func highlightedText(_ text: String, searchText: String) -> AttributedString {
    guard !searchText.isEmpty else {
      return AttributedString(text)
    }

    var attributedString = AttributedString(text)

    if let range = text.range(of: searchText, options: .caseInsensitive) {
      let nsRange = NSRange(range, in: text)
      if let attributedRange = Range(nsRange, in: attributedString) {
        attributedString[attributedRange].backgroundColor = theme.accent.opacity(
          theme.scheme == .dark ? 0.28 : 0.18)
        attributedString[attributedRange].foregroundColor = Color.primary
      }
    }

    return attributedString
  }
}
