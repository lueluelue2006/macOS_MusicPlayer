import SwiftUI

struct VolumeNormalizationAnalysisView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showOnlyMissing: Bool = false
    @State private var searchText: String = ""

    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    private var filteredFiles: [AudioFile] {
        var files = playlistManager.audioFiles

        if !searchText.isEmpty {
            let q = searchText
            files = files.filter { f in
                f.metadata.title.localizedCaseInsensitiveContains(q) ||
                    f.metadata.artist.localizedCaseInsensitiveContains(q) ||
                    f.metadata.album.localizedCaseInsensitiveContains(q) ||
                    f.url.lastPathComponent.localizedCaseInsensitiveContains(q)
            }
        }

        if showOnlyMissing {
            files = files.filter { !audioPlayer.hasVolumeNormalizationCache(for: $0.url) }
        }

        return files
    }

    private var analyzedCountInPlaylist: Int {
        let total = playlistManager.audioFiles.count
        guard total > 0 else { return 0 }
        return playlistManager.audioFiles.reduce(0) { acc, f in
            acc + (audioPlayer.hasVolumeNormalizationCache(for: f.url) ? 1 : 0)
        }
    }

    var body: some View {
        let _ = audioPlayer.volumeNormalizationCacheCount // drive refresh
        VStack(spacing: 0) {
            HStack {
                Text("音量均衡分析")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 10) {
                let total = playlistManager.audioFiles.count
                Text("当前播放列表：已分析 \(analyzedCountInPlaylist) / \(total)")
                    .foregroundStyle(theme.mutedText)

                if audioPlayer.isVolumePreanalysisRunning {
                    ProgressView(
                        value: Double(audioPlayer.volumePreanalysisCompleted),
                        total: Double(max(audioPlayer.volumePreanalysisTotal, 1))
                    )
                    .progressViewStyle(.linear)

                    Text("正在分析：\(audioPlayer.volumePreanalysisCurrentFileName)（\(audioPlayer.volumePreanalysisCompleted)/\(audioPlayer.volumePreanalysisTotal)）")
                        .font(.caption)
                        .foregroundStyle(theme.mutedText)
                }

                HStack(spacing: 12) {
                    Button("分析未缓存") {
                        let urls = playlistManager.audioFiles.map { $0.url }
                        audioPlayer.startVolumeNormalizationPreanalysis(urls: urls)
                    }
                    .disabled(audioPlayer.isVolumePreanalysisRunning || !audioPlayer.isNormalizationEnabled)

                    Button("停止") {
                        audioPlayer.cancelVolumeNormalizationPreanalysis()
                    }
                    .disabled(!audioPlayer.isVolumePreanalysisRunning)

                    Spacer()

                    Button("清空缓存") {
                        Task { @MainActor in
                            let confirmed = DestructiveConfirmation.confirm(
                                title: "清空音量均衡缓存？",
                                message: "将删除已分析的音量均衡缓存。下次播放或预分析时会重新计算，可能耗时。",
                                confirmTitle: "清除",
                                cancelTitle: "不清除"
                            )
                            guard confirmed else { return }
                            audioPlayer.clearVolumeCache()
                        }
                    }
                }

                Toggle(isOn: Binding(
                    get: { audioPlayer.autoPreanalyzeVolumesWhenIdle },
                    set: { audioPlayer.autoPreanalyzeVolumesWhenIdle = $0; audioPlayer.saveAutoPreanalyzeVolumesWhenIdlePreference() }
                )) {
                    Text("无操作 10 秒后自动分析未缓存歌曲（播放时也会）")
                }
                .help("检测鼠标/键盘操作；无操作一段时间后自动后台分析，任意操作会暂停自动预分析。")

                Toggle(isOn: Binding(
                    get: { audioPlayer.analyzeVolumesDuringPlayback },
                    set: { audioPlayer.analyzeVolumesDuringPlayback = $0; audioPlayer.saveAnalyzeVolumesDuringPlaybackPreference() }
                )) {
                    Text("播放时也允许后台分析（可能导致音量稍后变化）")
                }
                .help("开启后，播放未分析歌曲时会在后台分析当前曲目并回写缓存，可能导致音量随后变化。")

                Toggle(isOn: Binding(
                    get: { audioPlayer.requireVolumeAnalysisBeforePlayback },
                    set: { audioPlayer.requireVolumeAnalysisBeforePlayback = $0; audioPlayer.saveRequireVolumeAnalysisBeforePlaybackPreference() }
                )) {
                    Text("未分析歌曲播放前先分析（避免音量跳变）")
                }
                .help("开启后，若歌曲没有均衡缓存，将在开始播放前先完成一次分析。")

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("目标响度（RMS）")
                        Spacer()
                        Text("\(audioPlayer.normalizationTargetLevelDb, specifier: "%.1f") dB")
                            .foregroundStyle(theme.mutedText)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(audioPlayer.normalizationTargetLevelDb) },
                            set: { newValue in
                                audioPlayer.normalizationTargetLevelDb = Float(newValue)
                                audioPlayer.saveNormalizationTargetLevelPreference()
                                audioPlayer.reapplyVolumeNormalizationForCurrentFile(smoothIfPlaying: true)
                            }
                        ),
                        in: -30 ... -8,
                        step: 0.5
                    )
                    .disabled(!audioPlayer.isNormalizationEnabled)
                    .help("该目标基于当前的 RMS(dB) 算法，不等同于 LUFS/EBU R128。")

                    HStack {
                        Text("淡入时长")
                        Spacer()
                        Text("\(audioPlayer.normalizationFadeDuration, specifier: "%.2f") s")
                            .foregroundStyle(theme.mutedText)
                    }
                    Slider(
                        value: Binding(
                            get: { audioPlayer.normalizationFadeDuration },
                            set: { newValue in
                                audioPlayer.normalizationFadeDuration = newValue
                                audioPlayer.saveNormalizationFadeDurationPreference()
                                audioPlayer.reapplyVolumeNormalizationForCurrentFile(smoothIfPlaying: true)
                            }
                        ),
                        in: 0...1.5,
                        step: 0.05
                    )
                    .help("分析结果回写或切换均衡状态时，平滑过渡到新的播放音量。设为 0 可关闭淡入。")
                }

                HStack {
                    TextField("搜索（标题/歌手/专辑/文件名）", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Toggle("仅看未分析", isOn: $showOnlyMissing)
                }
            }
            .padding(16)
            .background(theme.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            List {
                ForEach(filteredFiles) { file in
                    let cached = audioPlayer.hasVolumeNormalizationCache(for: file.url)
                    HStack(spacing: 10) {
                        Image(systemName: cached ? "checkmark.seal.fill" : "circle")
                            .foregroundStyle(cached ? theme.accent : theme.mutedText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.metadata.title)
                                .lineLimit(1)
                            Text("\(file.metadata.artist) · \(file.metadata.album)")
                                .font(.caption)
                                .foregroundStyle(theme.mutedText)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(cached ? "已分析" : "未分析")
                            .font(.caption)
                            .foregroundStyle(cached ? theme.accent : theme.mutedText)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .padding(.top, 10)
        }
        .padding(.bottom, 14)
        .frame(minWidth: 720, minHeight: 520)
        .background(theme.backgroundGradient)
    }
}
