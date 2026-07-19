import Combine
import Foundation
import SwiftUI

struct VolumeNormalizationAnalysisView: View {
  @ObservedObject var audioPlayer: AudioPlayer
  @ObservedObject var playlistManager: PlaylistManager
  @ObservedObject private var sortState = SearchSortState.shared
  @ObservedObject private var weights: PlaybackWeights

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @State private var showOnlyMissing = false
  @State private var searchText = ""
  @State private var visibleRows: [AnalysisTrackRow] = []
  @State private var visibleRowIndexByID: [String: Int] = [:]
  @State private var cachedFileIDs: Set<String> = []
  @State private var cacheRefreshTask: Task<Void, Never>?
  @State private var cacheRefreshGeneration: UInt64 = 0
  @State private var previousSearchTarget: SearchFocusTarget = .queue
  @FocusState private var isSearchFieldFocused: Bool

  private var theme: AppTheme { AppTheme(scheme: colorScheme) }
  private var playlistCount: Int { playlistManager.audioFiles.count }
  private var analyzedCount: Int { cachedFileIDs.count }

  init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager) {
    self.audioPlayer = audioPlayer
    self.playlistManager = playlistManager
    _weights = ObservedObject(wrappedValue: playlistManager.playbackWeights)
  }

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
            detail: "全机闲置 60 秒后，每批最多 2 首；播放、低电量模式或升温时暂停。",
            isOn: autoPreanalysisBinding
          )
          .help("其他应用中的输入会在监测到后暂停；在播放器内操作或开始播放会立即暂停当前自动分析。")

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
            title: "目标综合响度",
            value: String(format: "%.1f LUFS", audioPlayer.normalizationTargetLUFS),
            binding: targetLevelBinding,
            range: -30 ... -8,
            step: 0.5
          )
          .disabled(!audioPlayer.isNormalizationEnabled)
          .help("按 ITU-R BS.1770 综合响度调节；峰值保护使用过采样估算值。")

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
      get: { Double(audioPlayer.normalizationTargetLUFS) },
      set: {
        audioPlayer.normalizationTargetLUFS = Float($0)
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
    scheduleCacheDerivedDataRefresh()
  }

  private func refreshCacheDerivedData() {
    scheduleCacheDerivedDataRefresh()
  }

  private func scheduleCacheDerivedDataRefresh() {
    cacheRefreshGeneration &+= 1
    let generation = cacheRefreshGeneration
    let urls = playlistManager.audioFiles.map(\.url)
    cacheRefreshTask?.cancel()
    cacheRefreshTask = Task { @MainActor in
      let refreshed = await audioPlayer.volumeNormalizationValidCacheKeysAsync(for: urls)
      guard !Task.isCancelled, cacheRefreshGeneration == generation else { return }
      cachedFileIDs = refreshed
      rebuildVisibleRows()
      cacheRefreshTask = nil
    }
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
    switch audioPlayer.clearVolumeCache() {
    case .cleared:
      return
    case .failed(let message):
      PersistenceLogger.notifyUser(title: "缓存清除失败", subtitle: message)
    case .requiresConfirmation(let reason):
      let forceConfirmed = DestructiveConfirmation.confirm(
        title: "删除受保护的缓存？",
        message: protectedCacheMessage(reason),
        confirmTitle: "仍然删除",
        cancelTitle: "保留"
      )
      guard forceConfirmed else { return }
      if case .failed(let message) = audioPlayer.clearVolumeCache(forceProtectedData: true) {
        PersistenceLogger.notifyUser(title: "缓存清除失败", subtitle: message)
      }
    }
  }

  private func protectedCacheMessage(_ reason: ProtectedVolumeCacheReason) -> String {
    switch reason {
    case .futureLegacyJSON(let version):
      return "发现由更高版本创建的音量缓存（版本 \(version)）。删除后，其中的数据不能由当前版本恢复。"
    case .unknownLegacyJSON:
      return "现有音量缓存格式无法识别。删除会移除原文件，无法由当前版本恢复。"
    case .futureDatabase(let version):
      return "发现更高版本的音量数据库（版本 \(version)）。删除后，其中的数据不能由当前版本恢复。"
    case .foreignDatabase:
      return "该数据库不属于当前音量缓存格式。删除会移除原数据库，无法恢复。"
    }
  }

  private func handleAppear() {
    previousSearchTarget = AppFocusState.shared.activeSearchTarget
    AppFocusState.shared.activeSearchTarget = .volumeAnalysis
    refreshAllDerivedData()
  }

  private func restoreSearchFocusContext() {
    cacheRefreshGeneration &+= 1
    cacheRefreshTask?.cancel()
    cacheRefreshTask = nil
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
