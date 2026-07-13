import Combine
import Foundation
import SwiftUI

struct VolumeNormalizationAnalysisView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @ObservedObject private var sortState = SearchSortState.shared
  @ObservedObject private var weights = PlaybackWeights.shared

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @State private var showOnlyMissing = false
  @State private var searchText = ""
  @State private var visibleRows: [AnalysisTrackRow] = []
  @State private var visibleRowIndexByID: [String: Int] = [:]
  @State private var cachedFileIDs: Set<String> = []
  @State private var previousSearchTarget: SearchFocusTarget = .queue
  @FocusState private var isSearchFieldFocused: Bool

  private var theme: AppTheme { AppTheme(scheme: colorScheme) }
  private var playlistCount: Int { playlistManager.audioFiles.count }
  private var analyzedCount: Int { cachedFileIDs.count }

  var body: some View {
    VStack(spacing: 0) {
      header

      VStack(spacing: 12) {
        analysisSummary

        HStack(alignment: .top, spacing: 12) {
          preferencesPanel
            .frame(width: 310)

          tracksPanel
        }
        .frame(maxHeight: .infinity)
      }
      .padding(16)
    }
    .frame(minWidth: 760, minHeight: 580)
    .tint(theme.accent)
    .background(theme.backgroundGradient)
    .onAppear(perform: handleAppear)
    .onDisappear(perform: restoreSearchFocusContext)
    .onReceive(playlistManager.$audioFiles.dropFirst()) { _ in
      refreshAllDerivedData()
    }
    .onChange(of: searchText) { _ in
      rebuildVisibleRows()
    }
    .onChange(of: showOnlyMissing) { _ in
      rebuildVisibleRows()
    }
    .onChange(of: sortState.option(for: .volumeAnalysis)) { _ in
      rebuildVisibleRows()
    }
    .onChange(of: weights.revision) { _ in
      rebuildVisibleRows()
    }
    .onChange(of: audioPlayer.volumeNormalizationCacheCount) { _ in
      refreshCacheDerivedData()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .focusSearchField), perform: handleFocusRequest
    )
    .onReceive(NotificationCenter.default.publisher(for: .blurSearchField)) { _ in
      blurSearchField()
    }
    .onExitCommand {
      // Analysis belongs to AudioPlayer and intentionally continues after this view closes.
      dismiss()
    }
  }

  // MARK: - Layout

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform.circle.fill")
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(theme.accentGradient)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("音量均衡分析")
          .font(.title3.weight(.semibold))

        Text("提前分析队列响度，让曲目切换保持稳定。")
          .font(.caption)
          .foregroundStyle(theme.mutedText)
      }

      Spacer()

      Button("关闭") { dismiss() }
        .keyboardShortcut(.escape, modifiers: [])
        .help(audioPlayer.isVolumePreanalysisRunning ? "关闭后仍会在后台继续分析；点击“停止”才会停止" : "关闭（Esc）")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(theme.panelBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(theme.stroke)
        .frame(height: 1)
    }
  }

  private var analysisSummary: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("队列分析进度")
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.mutedText)

          Text("\(analyzedCount) / \(playlistCount)")
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
        }

        Spacer(minLength: 24)

        Button {
          let urls = playlistManager.audioFiles.map(\.url)
          audioPlayer.startVolumeNormalizationPreanalysis(urls: urls)
        } label: {
          Label("分析未缓存的", systemImage: "waveform.badge.magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .disabled(audioPlayer.isVolumePreanalysisRunning || !audioPlayer.isNormalizationEnabled)

        Button {
          audioPlayer.cancelVolumeNormalizationPreanalysis()
        } label: {
          Label("停止", systemImage: "stop.fill")
        }
        .disabled(!audioPlayer.isVolumePreanalysisRunning)

        Button(role: .destructive) {
          Task { @MainActor in
            confirmAndClearCache()
          }
        } label: {
          Label("清空缓存", systemImage: "trash")
        }
      }

      ProgressView(
        value: Double(
          audioPlayer.isVolumePreanalysisRunning
            ? audioPlayer.volumePreanalysisCompleted : analyzedCount),
        total: Double(
          max(
            audioPlayer.isVolumePreanalysisRunning
              ? audioPlayer.volumePreanalysisTotal : playlistCount, 1))
      )
      .progressViewStyle(.linear)
      .accessibilityLabel(audioPlayer.isVolumePreanalysisRunning ? "当前分析任务进度" : "队列分析进度")

      if audioPlayer.isVolumePreanalysisRunning {
        HStack(spacing: 7) {
          Image(systemName: "waveform")
            .foregroundStyle(theme.accent)
            .accessibilityHidden(true)

          Text("正在分析：\(audioPlayer.volumePreanalysisCurrentFileName)")
            .lineLimit(1)

          Spacer(minLength: 12)

          Text("\(audioPlayer.volumePreanalysisCompleted) / \(audioPlayer.volumePreanalysisTotal)")
            .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(theme.mutedText)
      } else {
        Text(playlistCount == 0 ? "队列为空，添加歌曲后即可开始分析。" : "分析会在后台顺序进行，关闭此窗口不会中断任务。")
          .font(.caption)
          .foregroundStyle(theme.mutedText)
      }
    }
    .padding(14)
    .cardStyle(theme: theme)
  }

  private var preferencesPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        panelTitle("分析设置", systemImage: "slider.horizontal.3")

        VStack(alignment: .leading, spacing: 12) {
          preferenceToggle(
            title: "闲置时自动分析",
            detail: "无操作 10 秒后开始，任意输入会暂停。",
            isOn: autoPreanalysisBinding
          )
          .help("检测鼠标/键盘操作；无操作一段时间后自动后台分析，任意操作会暂停自动预分析。")

          Divider().opacity(0.55)

          preferenceToggle(
            title: "播放时允许后台分析",
            detail: "结果写回后，当前歌曲音量可能平滑变化。",
            isOn: playbackAnalysisBinding
          )
          .help("开启后，播放未分析歌曲时会在后台分析当前曲目并回写缓存，可能导致音量随后变化。")

          Divider().opacity(0.55)

          preferenceToggle(
            title: "播放前完成分析",
            detail: "先分析未缓存歌曲，避免播放中出现音量跳变。",
            isOn: requireAnalysisBinding
          )
          .help("开启后，若歌曲没有均衡缓存，将在开始播放前先完成一次分析。")
        }

        Divider().opacity(0.55)

        VStack(alignment: .leading, spacing: 14) {
          sliderSetting(
            title: "目标响度（RMS）",
            value: String(format: "%.1f dB", audioPlayer.normalizationTargetLevelDb),
            binding: targetLevelBinding,
            range: -30 ... -8,
            step: 0.5
          )
          .disabled(!audioPlayer.isNormalizationEnabled)
          .help("该目标基于当前的 RMS(dB) 算法，不等同于 LUFS/EBU R128。")

          sliderSetting(
            title: "淡入时长",
            value: String(format: "%.2f s", audioPlayer.normalizationFadeDuration),
            binding: fadeDurationBinding,
            range: 0...1.5,
            step: 0.05
          )
          .help("分析结果回写或切换均衡状态时，平滑过渡到新的播放音量。设为 0 可关闭淡入。")
        }
      }
      .padding(14)
    }
    .scrollIndicators(.hidden)
    .frame(maxHeight: .infinity)
    .cardStyle(theme: theme)
  }

  private var tracksPanel: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 11) {
        HStack {
          panelTitle("队列歌曲", systemImage: "music.note.list")

          Spacer()

          Text("\(visibleRows.count) 首")
            .font(.caption)
            .foregroundStyle(theme.mutedText)
            .monospacedDigit()
        }

        HStack(spacing: 10) {
          TextField("搜索标题、歌手、专辑或文件名", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .focused($isSearchFieldFocused)
            .onChange(of: isSearchFieldFocused, perform: handleSearchFocusChange)

          Toggle("仅看未分析", isOn: $showOnlyMissing)
            .toggleStyle(.switch)
            .controlSize(.small)

          SearchSortButton(target: .volumeAnalysis, helpSuffix: "仅影响列表显示，不改变队列顺序。")
        }
      }
      .padding(14)

      Divider().opacity(0.65)

      if visibleRows.isEmpty {
        emptyTracksState
      } else {
        List(visibleRows) { row in
          analysisTrackRow(row)
            .listRowBackground(Color.clear)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .cardStyle(theme: theme)
  }

  private var emptyTracksState: some View {
    VStack(spacing: 9) {
      Image(systemName: showOnlyMissing ? "checkmark.seal" : "music.note.list")
        .font(.system(size: 30, weight: .regular))
        .foregroundStyle(theme.mutedText)

      Text(emptyStateTitle)
        .font(.headline)

      Text(emptyStateDetail)
        .font(.caption)
        .foregroundStyle(theme.mutedText)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private var emptyStateTitle: String {
    if playlistCount == 0 { return "队列为空" }
    if showOnlyMissing && searchText.isEmpty { return "全部歌曲均已分析" }
    return "没有匹配的歌曲"
  }

  private var emptyStateDetail: String {
    if playlistCount == 0 { return "先向播放队列添加歌曲，再进行音量分析。" }
    if showOnlyMissing && searchText.isEmpty { return "当前队列已经准备好稳定播放。" }
    return "尝试调整搜索内容或关闭“仅看未分析”。"
  }

  private func panelTitle(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.headline)
      .foregroundStyle(.primary)
  }

  private func preferenceToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.medium))

        Text(detail)
          .font(.caption)
          .foregroundStyle(theme.mutedText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.switch)
  }

  private func sliderSetting(
    title: String,
    value: String,
    binding: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
          .font(.subheadline.weight(.medium))

        Spacer()

        Text(value)
          .font(.caption.monospacedDigit())
          .foregroundStyle(theme.mutedText)
      }

      Slider(value: binding, in: range, step: step)
    }
  }

  private func analysisTrackRow(_ row: AnalysisTrackRow) -> some View {
    HStack(spacing: 10) {
      Image(systemName: row.isAnalyzed ? "checkmark.seal.fill" : "circle.dashed")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(
          row.isAnalyzed ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText)
        )
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(row.file.metadata.title)
          .lineLimit(1)

        Text("\(row.file.metadata.artist) · \(row.file.metadata.album)")
          .font(.caption)
          .foregroundStyle(theme.mutedText)
          .lineLimit(1)
      }

      Spacer(minLength: 10)

      Text(row.isAnalyzed ? "已分析" : "待分析")
        .font(.caption.weight(.medium))
        .foregroundStyle(
          row.isAnalyzed ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(row.isAnalyzed ? theme.accent.opacity(0.10) : theme.mutedSurface)
        )
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Preference bindings

  private var autoPreanalysisBinding: Binding<Bool> {
    Binding(
      get: { audioPlayer.autoPreanalyzeVolumesWhenIdle },
      set: {
        audioPlayer.autoPreanalyzeVolumesWhenIdle = $0
        audioPlayer.saveAutoPreanalyzeVolumesWhenIdlePreference()
      }
    )
  }

  private var playbackAnalysisBinding: Binding<Bool> {
    Binding(
      get: { audioPlayer.analyzeVolumesDuringPlayback },
      set: {
        audioPlayer.analyzeVolumesDuringPlayback = $0
        audioPlayer.saveAnalyzeVolumesDuringPlaybackPreference()
      }
    )
  }

  private var requireAnalysisBinding: Binding<Bool> {
    Binding(
      get: { audioPlayer.requireVolumeAnalysisBeforePlayback },
      set: {
        audioPlayer.requireVolumeAnalysisBeforePlayback = $0
        audioPlayer.saveRequireVolumeAnalysisBeforePlaybackPreference()
      }
    )
  }

  private var targetLevelBinding: Binding<Double> {
    Binding(
      get: { Double(audioPlayer.normalizationTargetLevelDb) },
      set: {
        audioPlayer.normalizationTargetLevelDb = Float($0)
        audioPlayer.saveNormalizationTargetLevelPreference()
        audioPlayer.reapplyVolumeNormalizationForCurrentFile(smoothIfPlaying: true)
      }
    )
  }

  private var fadeDurationBinding: Binding<Double> {
    Binding(
      get: { audioPlayer.normalizationFadeDuration },
      set: {
        audioPlayer.normalizationFadeDuration = $0
        audioPlayer.saveNormalizationFadeDurationPreference()
        audioPlayer.reapplyVolumeNormalizationForCurrentFile(smoothIfPlaying: true)
      }
    )
  }

  // MARK: - Derived list data

  /// Invariant: expensive filtering, sorting and cache membership work is driven only by
  /// queue/query/sort/weight/cache changes. Progress publications can re-render status
  /// without rescanning the playlist or taking one cache lock per row.
  private func refreshAllDerivedData() {
    cachedFileIDs = currentQueueCachedFileIDs()
    rebuildVisibleRows()
  }

  private func refreshCacheDerivedData() {
    let newCachedFileIDs = currentQueueCachedFileIDs()
    let addedIDs = newCachedFileIDs.subtracting(cachedFileIDs)
    let removedIDs = cachedFileIDs.subtracting(newCachedFileIDs)

    guard !addedIDs.isEmpty || !removedIDs.isEmpty else { return }
    cachedFileIDs = newCachedFileIDs

    // Removals are uncommon (normally an explicit clear) and can reintroduce rows,
    // so rebuild ordering then. Normal analysis additions update only affected rows.
    guard removedIDs.isEmpty else {
      rebuildVisibleRows()
      return
    }

    if showOnlyMissing {
      visibleRows.removeAll { addedIDs.contains($0.id) }
      rebuildVisibleRowIndex()
      return
    }

    for id in addedIDs {
      guard let index = visibleRowIndexByID[id] else { continue }
      visibleRows[index].isAnalyzed = true
    }
  }

  private func currentQueueCachedFileIDs() -> Set<String> {
    // Take one locked snapshot, then resolve all queue membership lock-free.
    let cacheKeys = audioPlayer.volumeNormalizationCacheKeysSnapshot()
    var result = Set<String>()
    result.reserveCapacity(min(cacheKeys.count, playlistManager.audioFiles.count))

    for file in playlistManager.audioFiles {
      if cacheKeys.contains(file.id) || cacheKeys.contains(file.id.lowercased()) {
        result.insert(file.id)
      }
    }
    return result
  }

  private func rebuildVisibleRows() {
    var files = playlistManager.audioFiles

    if !searchText.isEmpty {
      let query = searchText
      files = files.filter { file in
        file.metadata.title.localizedCaseInsensitiveContains(query)
          || file.metadata.artist.localizedCaseInsensitiveContains(query)
          || file.metadata.album.localizedCaseInsensitiveContains(query)
          || file.url.lastPathComponent.localizedCaseInsensitiveContains(query)
      }
    }

    if showOnlyMissing {
      files = files.filter { !cachedFileIDs.contains($0.id) }
    }

    let sortedFiles = sortState.option(for: .volumeAnalysis).applying(
      to: files, weightScope: .queue)
    visibleRows = sortedFiles.map { file in
      AnalysisTrackRow(file: file, isAnalyzed: cachedFileIDs.contains(file.id))
    }
    rebuildVisibleRowIndex()
  }

  private func rebuildVisibleRowIndex() {
    var indexes: [String: Int] = [:]
    indexes.reserveCapacity(visibleRows.count)
    for (index, row) in visibleRows.enumerated() {
      indexes[row.id] = index
    }
    visibleRowIndexByID = indexes
  }

  // MARK: - Actions and focus routing

  @MainActor
  private func confirmAndClearCache() {
    let confirmed = DestructiveConfirmation.confirm(
      title: "清空音量均衡缓存？",
      message: "将删除已分析的音量均衡缓存。下次播放或预分析时会重新计算，可能耗时。",
      confirmTitle: "清除",
      cancelTitle: "不清除"
    )
    guard confirmed else { return }
    audioPlayer.clearVolumeCache()
  }

  private func handleAppear() {
    previousSearchTarget = AppFocusState.shared.activeSearchTarget
    AppFocusState.shared.activeSearchTarget = .volumeAnalysis
    refreshAllDerivedData()
  }

  private func restoreSearchFocusContext() {
    guard AppFocusState.shared.activeSearchTarget == .volumeAnalysis else { return }
    AppFocusState.shared.activeSearchTarget = previousSearchTarget
    AppFocusState.shared.isSearchFocused = false
  }

  private func handleSearchFocusChange(_ focused: Bool) {
    if focused {
      AppFocusState.shared.activeSearchTarget = .volumeAnalysis
      AppFocusState.shared.isSearchFocused = true
    } else if AppFocusState.shared.activeSearchTarget == .volumeAnalysis {
      AppFocusState.shared.isSearchFocused = false
    }
  }

  private func handleFocusRequest(_ notification: Notification) {
    let requestedTarget = (notification.userInfo?["target"] as? String)
      .flatMap(SearchFocusTarget.init(rawValue:))

    if let requestedTarget {
      guard requestedTarget == .volumeAnalysis else { return }
    } else {
      guard AppFocusState.shared.activeSearchTarget == .volumeAnalysis else { return }
    }

    AppFocusState.shared.activeSearchTarget = .volumeAnalysis
    isSearchFieldFocused = true
    AppFocusState.shared.isSearchFocused = true
  }

  private func blurSearchField() {
    isSearchFieldFocused = false
    if AppFocusState.shared.activeSearchTarget == .volumeAnalysis {
      AppFocusState.shared.isSearchFocused = false
    }
  }
}

private struct AnalysisTrackRow: Identifiable {
  let file: AudioFile
  var isAnalyzed: Bool

  var id: String { file.id }
}

extension View {
  fileprivate func cardStyle(theme: AppTheme) -> some View {
    background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(theme.elevatedSurface)
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.stroke, lineWidth: 1)
        }
        .shadow(color: theme.subtleShadow, radius: 8, y: 3)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
