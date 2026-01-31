import SwiftUI
import AppKit

import AVFoundation

struct MetadataEditView: View {
    let audioFile: AudioFile
    // onSave(title, artist, album, year, genre, lyrics)
    let onSave: (String, String, String, String, String, String) -> Void
    let onCancel: () -> Void
    
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var year: String
    @State private var genre: String
    @State private var lyricsText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCopiedMessage = false
    // Lyrics embedding helper states
    @State private var lyricsSongPath: String = ""
    @State private var lyricsLrcPath: String = ""
    @State private var showCopiedLyricsMessage = false
    
    init(audioFile: AudioFile, onSave: @escaping (String, String, String, String, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.audioFile = audioFile
        self.onSave = onSave
        self.onCancel = onCancel
        
        // 初始化当前的元数据
        _title = State(initialValue: audioFile.metadata.title)
        _artist = State(initialValue: audioFile.metadata.artist)
        _album = State(initialValue: audioFile.metadata.album)
        _year = State(initialValue: audioFile.metadata.year ?? "")
        _genre = State(initialValue: audioFile.metadata.genre ?? "")
    }
    
    // 判断是否为不支持的格式，但可以显示ffmpeg命令
    private var shouldShowFFmpegCommand: Bool {
        let canEdit = MetadataEditor.canEditMetadata(for: audioFile.url)
        let canShowButton = MetadataEditor.canShowEditButton(for: audioFile.url)
        return !canEdit && canShowButton
    }
    
    // 生成ffmpeg命令
    private var ffmpegCommand: String {
        let inputPath = escapeShellPath(audioFile.url.path)
        let tempPath = escapeShellPath(generateTempPath())
        let fileExtension = audioFile.url.pathExtension.lowercased()
        
        var metadataFlags: [String] = []
        
        // 仅当用户填写了值时才覆盖对应字段；否则保留原值
        let titleValue = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleValue.isEmpty { metadataFlags.append("-metadata title=\(escapeShellValue(titleValue))") }
        
        let artistValue = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artistValue.isEmpty { metadataFlags.append("-metadata artist=\(escapeShellValue(artistValue))") }
        
        let albumValue = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !albumValue.isEmpty { metadataFlags.append("-metadata album=\(escapeShellValue(albumValue))") }
        
        let yearValue = year.trimmingCharacters(in: .whitespacesAndNewlines)
        if !yearValue.isEmpty {
            // 对于不同格式使用适当的年份标签
            switch fileExtension {
            case "mp3":
                metadataFlags.append("-metadata date=\(escapeShellValue(yearValue))")
            case "flac", "ogg":
                metadataFlags.append("-metadata DATE=\(escapeShellValue(yearValue))")
            default:
                metadataFlags.append("-metadata date=\(escapeShellValue(yearValue))")
            }
        }
        
        let genreValue = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        if !genreValue.isEmpty {
            // 对于不同格式使用适当的类型标签
            switch fileExtension {
            case "mp3":
                metadataFlags.append("-metadata genre=\(escapeShellValue(genreValue))")
            case "flac", "ogg":
                metadataFlags.append("-metadata GENRE=\(escapeShellValue(genreValue))")
            default:
                metadataFlags.append("-metadata genre=\(escapeShellValue(genreValue))")
            }
        }
        
        let metadataString = metadataFlags.joined(separator: " ")
        
        // 使用临时文件然后替换原文件的方式，添加错误处理
        // 先使用ffprobe检测实际格式，然后选择合适的扩展名
        let probeCommand = "ffprobe -v quiet -select_streams a:0 -show_entries format=format_name -of csv=p=0 \(inputPath)"
        
        return """
        FORMAT=$(\(probeCommand)) && \\
        case "$FORMAT" in
            *mp3*) EXT=".mp3" ;;
            *mp4*|*m4a*) EXT=".m4a" ;;
            *flac*) EXT=".flac" ;;
            *ogg*) EXT=".ogg" ;;
            *wav*) EXT=".wav" ;;
            *) EXT=".tmp" ;;
        esac && \\
        # 保留原始元数据（包括歌词），仅覆盖标题/艺术家/专辑/年份/类型
        ffmpeg -y -i \(inputPath) -map_metadata 0 \(metadataString) -c copy \(tempPath)$EXT && mv \(tempPath)$EXT \(inputPath) || (rm -f \(tempPath)$EXT && echo "Error: FFmpeg failed to process the file")
        """
    }
    
    // 根据文件格式获取适当的编解码器选项
    private func getCodecOptions(for fileExtension: String) -> String {
        switch fileExtension {
        case "mp3":
            return "-c copy -id3v2_version 3 -write_id3v1 1"  // MP3更完整的标签支持
        case "flac":
            return "-c:a flac -compression_level 5 -f flac"  // FLAC降低压缩级别，提高稳定性
        case "ogg":
            return "-c:a libvorbis -q:a 6 -f ogg"  // OGG指定格式
        case "m4a", "aac":
            return "-c copy -movflags +faststart"  // M4A/AAC优化
        case "wav":
            return "-c:a pcm_s16le -f wav"  // WAV指定格式
        case "wma":
            return "-c:a wmav2 -f asf"  // WMA指定格式
        case "ape":
            return "-c:a flac -f flac"  // APE转换为FLAC更稳定
        case "opus":
            return "-c:a libopus -b:a 128k -f opus"  // OPUS指定格式
        default:
            return "-c copy"  // 默认复制数据流
        }
    }
    
    // 转义shell路径（先移除用户粘贴的外围引号，再进行安全包裹）
    private func escapeShellPath(_ path: String) -> String {
        let sanitized = sanitizePathInput(path)
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    
    // 转义shell值
    private func escapeShellValue(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    
    // 生成临时文件路径，使用通用扩展名让FFmpeg自动检测格式
    private func generateTempPath() -> String {
        let originalURL = audioFile.url
        let directory = originalURL.deletingLastPathComponent().path
        let tempFileName = "temp_\(UUID().uuidString)"  // 不指定扩展名
        
        return "\(directory)/\(tempFileName)"
    }

    // 去除用户输入路径外围的成对引号（'...' 或 "..."）与首尾空白
    private func sanitizePathInput(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s.removeFirst()
            s.removeLast()
        }
        return s
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
            // 标题
            HStack {
                Text(shouldShowFFmpegCommand ? "生成FFmpeg命令" : "编辑歌曲信息")
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
            }
            
            // 专辑封面预览
            HStack {
                // 简单的专辑封面显示
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 30))
                            .foregroundColor(.gray)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件名: \(audioFile.url.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if shouldShowFFmpegCommand {
                        Text("⚠️ 此格式不支持直接编辑，但您可以复制下面的命令在终端运行")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else if MetadataEditor.canEditMetadata(for: audioFile.url) {
                        Text("✅ 支持元数据编辑")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("⚠️ 此格式不支持元数据编辑")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
            }
            
            Divider()
            
            if shouldShowFFmpegCommand {
                // FFmpeg命令模式
                ffmpegCommandView
            } else {
                // 直接编辑模式
                directEditView
            }
            
            // 错误信息
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // 按钮
            HStack(spacing: 15) {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                if !shouldShowFFmpegCommand {
                    Button("保存") {
                        saveMetadata()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || !MetadataEditor.canEditMetadata(for: audioFile.url))
                }
            }
        }
        }
        .padding()
        .frame(minWidth: 500, idealWidth: 600, maxWidth: .infinity,
               minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .overlay(
            // 加载遮罩
            Group {
                if isLoading {
                    Color.black.opacity(0.3)
                        .overlay(
                            ProgressView("保存中...")
                                .padding()
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(10)
                        )
                }
            }
        )
        .onAppear {
            // 确保窗口可移动
            DispatchQueue.main.async {
                if let window = NSApplication.shared.keyWindow {
                    window.isMovable = true
                    window.isMovableByWindowBackground = true
                }
            }
            // 初始化歌词助手默认路径：歌曲路径填当前文件，歌词路径留空
            if lyricsSongPath.isEmpty { lyricsSongPath = audioFile.url.path }
            // 预填充歌词输入：尝试从文件元数据读取 ©lyr（如失败则留空）
            preloadEmbeddedLyrics()
        }
    }
    
    // 直接编辑视图
    private var directEditView: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("歌曲标题")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("输入歌曲标题", text: $title)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            VStack(alignment: .leading, spacing: 5) {
                Text("艺术家")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("输入艺术家名称", text: $artist)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            VStack(alignment: .leading, spacing: 5) {
                Text("专辑")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("输入专辑名称", text: $album)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("年份")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("输入发行年份", text: $year)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("类型")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("输入音乐类型", text: $genre)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }

            // 歌词输入（支持 LRC 或纯文本）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "text.alignleft")
                        .foregroundColor(.purple)
                    Text("歌词（可输入 LRC 或纯文本）")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    // 简单识别提示
                    let detected = looksLikeLRC(lyricsText)
                    Text(detected ? "已检测到时间戳：将按动态歌词保存" : "未检测到时间戳：将按静态歌词保存")
                        .font(.caption)
                        .foregroundColor(detected ? .purple : .secondary)
                }
                TextEditor(text: $lyricsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
            }
        }
    }
    
    // FFmpeg命令视图
    private var ffmpegCommandView: some View {
        VStack(spacing: 15) {
            // 编辑表单
            VStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("歌曲标题")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("输入歌曲标题", text: $title)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("艺术家")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("输入艺术家名称", text: $artist)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("专辑")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("输入专辑名称", text: $album)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("年份")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("输入发行年份", text: $year)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text("类型")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("输入音乐类型", text: $genre)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
            }
            
            // 分割线
            Divider()
            
            // 命令说明
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundColor(.blue)
                    Text("生成的FFmpeg命令")
                        .font(.headline)
                        .foregroundColor(.blue)
                    Spacer()
                }
                
                Text("复制下面的命令到终端执行，即可编辑元数据：")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 命令框
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ffmpegCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            .frame(maxHeight: 120)

            // 基础命令复制按钮（仅作用于上面的基础元数据命令）
            HStack {
                Button(showCopiedMessage ? "已复制!" : "复制基础元数据命令") {
                    copyFFmpegCommand()
                }
                .buttonStyle(.borderedProminent)
                .disabled(showCopiedMessage)
                Spacer()
            }

            // 说明文字
            VStack(alignment: .leading, spacing: 4) {
                Text("💡 使用说明：")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                
                Text("• 复制上面的命令到终端执行")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("• 命令使用-c copy保持原始音频质量和格式")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("• 自动检测真实音频格式，无需担心扩展名错误")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("• 空值字段会被清除，包含完整错误处理")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("• 需要先安装FFmpeg: brew install ffmpeg")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("• 建议先备份重要文件")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            .padding(.top, 8)

            // 分割线
            Divider().padding(.vertical, 8)

            // Lyrics embedding helper section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "text.quote")
                        .foregroundColor(.purple)
                    Text("嵌入歌词元数据（辅助命令）")
                        .font(.headline)
                        .foregroundColor(.purple)
                    Spacer()
                }
                Text("在 Finder 里选中文件，按 Option+Command+C 可复制其完整路径")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("歌曲文件完整路径")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("/完整/路径/到/歌曲文件（例如 .mp3 / .m4a）", text: $lyricsSongPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("歌词文件完整路径（.lrc 或 .txt）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("/完整/路径/到/歌词文本文件（.lrc 或 .txt）", text: $lyricsLrcPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                // 生成的歌词嵌入命令（智能编码处理：优先 UTF-8，失败则尝试 GB18030，最后原样）
                VStack(alignment: .leading, spacing: 6) {
                    Text("生成的嵌入歌词命令")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(lyricsSmartFFmpegCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .frame(maxHeight: 120)
                }

                // 复制按钮
                HStack(spacing: 12) {
                    Button(showCopiedLyricsMessage ? "已复制!" : "复制嵌入歌词命令") {
                        copyLyricsFFmpegCommand()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(showCopiedLyricsMessage || lyricsSongPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lyricsLrcPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    // 复制FFmpeg命令到剪贴板
    private func copyFFmpegCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ffmpegCommand, forType: .string)
        
        showCopiedMessage = true
        
        // 2秒后重置按钮状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedMessage = false
        }
    }
    
    private func saveMetadata() {
        guard MetadataEditor.canEditMetadata(for: audioFile.url) else {
            errorMessage = "此文件格式不支持元数据编辑"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                try await MetadataEditor.updateMetadata(
                    for: audioFile.url,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                    album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                    year: year.trimmingCharacters(in: .whitespacesAndNewlines),
                    genre: genre.trimmingCharacters(in: .whitespacesAndNewlines),
                    lyrics: lyricsText
                )
                
                    await MainActor.run {
                        isLoading = false
                        onSave(title, artist, album, year, genre, lyricsText)
                    }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Lyrics FFmpeg generator
    private var lyricsSmartFFmpegCommand: String {
        buildLyricsSmartCommand()
    }

    private func buildLyricsSmartCommand() -> String {
        let song = sanitizePathInput(lyricsSongPath)
        let lrc = sanitizePathInput(lyricsLrcPath)
        guard !song.isEmpty, !lrc.isEmpty else {
            return "# 请输入上面的歌曲与歌词完整路径后生成命令"
        }

        let songURL = URL(fileURLWithPath: song)
        let ext = songURL.pathExtension.lowercased()
        let base = songURL.deletingPathExtension().path
        let outPath = base + ".lyrics." + (ext.isEmpty ? "mp3" : ext)

        let songEsc = escapeShellPath(song)
        let lrcEsc = escapeShellPath(lrc)
        let outEsc = escapeShellPath(outPath)

        var flags: [String] = []
        if ext == "mp3" { flags += ["-id3v2_version 3", "-write_id3v1 1"] }
        // 智能读取：优先 UTF-8，再尝试 UTF-16/UTF-32（常见于 Windows 文本），再尝试 GB18030，最后原样
        let lyricsValue = "\"$(iconv -f UTF-8 -t UTF-8 \(lrcEsc) 2>/dev/null || iconv -f UTF-16LE -t UTF-8 \(lrcEsc) 2>/dev/null || iconv -f UTF-16BE -t UTF-8 \(lrcEsc) 2>/dev/null || iconv -f UTF-32LE -t UTF-8 \(lrcEsc) 2>/dev/null || iconv -f UTF-32BE -t UTF-8 \(lrcEsc) 2>/dev/null || iconv -f GB18030 -t UTF-8 \(lrcEsc) 2>/dev/null || cat \(lrcEsc))\""

        let cmd = [
            "ffmpeg -i \(songEsc)",
            flags.joined(separator: " "),
            "-metadata lyrics=\(lyricsValue)",
            "-codec copy \(outEsc)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        return cmd
    }

    private func copyLyricsFFmpegCommand() {
        let cmd = lyricsSmartFFmpegCommand
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(cmd, forType: .string)
        showCopiedLyricsMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedLyricsMessage = false
        }
    }
}

// MARK: - Helpers
private extension MetadataEditView {
    func looksLikeLRC(_ text: String) -> Bool {
        let s = text
        guard s.contains("[") && s.contains(":") && s.contains("]") else { return false }
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d+))?\]"#
        if let r = try? NSRegularExpression(pattern: pattern, options: []) {
            let count = r.numberOfMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length))
            return count >= 2
        }
        return false
    }

    func preloadEmbeddedLyrics() {
        Task {
            let embedded = await fetchEmbeddedLyricsText()
            await MainActor.run {
                // 若用户已开始输入，不覆盖
                if !lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
                if let embedded, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lyricsText = embedded
                    return
                }
                // 兜底：如果播放器当前已解析出时间轴，可以将其拼接为纯文本预填（不追加时间戳，避免误导）
                if let timeline = audioFile.lyricsTimeline {
                    let joined = timeline.lines.map { $0.text }.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lyricsText = joined
                    }
                }
            }
        }
    }

    func fetchEmbeddedLyricsText() async -> String? {
        let asset = AVURLAsset(url: audioFile.url)
        let all: [AVMetadataItem]
        if #available(macOS 13.0, *) {
            let m1 = (try? await asset.load(.metadata)) ?? []
            let m2 = (try? await asset.load(.commonMetadata)) ?? []
            all = m1 + m2
        } else {
            all = asset.metadata + asset.commonMetadata
        }

        guard let item = all.first(where: { $0.commonKey?.rawValue == "lyrics" || $0.identifier?.rawValue.lowercased().contains("lyrics") == true }) else {
            return nil
        }

        if #available(macOS 13.0, *) {
            return try? await item.load(.stringValue)
        } else {
            return item.stringValue
        }
    }
}
