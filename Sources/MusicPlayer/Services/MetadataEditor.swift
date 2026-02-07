import Foundation
import AVFoundation

// MARK: - Format Support Configuration
struct FormatSupport {
    static let directEditFormats = ["m4a", "mp4", "aac"]
    static let ffmpegSupportedFormats = ["mp3", "flac", "ogg", "wma", "ape", "opus"]
    static let limitedSupportFormats = ["wav", "aiff"]
    
    static func getSupportType(for fileExtension: String) -> EditButtonType {
        let ext = fileExtension.lowercased()
        if directEditFormats.contains(ext) {
            return .directEdit
        } else if ffmpegSupportedFormats.contains(ext) {
            return .ffmpegCommand
        } else if limitedSupportFormats.contains(ext) {
            return .notSupported
        } else {
            return .hidden
        }
    }
}

enum EditButtonType {
    case directEdit    // 蓝色铅笔 - 直接编辑
    case ffmpegCommand // 橙色铅笔 - FFmpeg命令
    case notSupported  // 灰色铅笔 - 不支持
    case hidden        // 不显示按钮
}

class MetadataEditor: ObservableObject {
    
    static func canEditMetadata(for url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return FormatSupport.directEditFormats.contains(fileExtension)
    }
    
    static func canShowEditButton(for url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let supportType = FormatSupport.getSupportType(for: fileExtension)
        return supportType != .hidden
    }
    
    static func getEditButtonType(for url: URL) -> EditButtonType {
        let fileExtension = url.pathExtension.lowercased()
        return FormatSupport.getSupportType(for: fileExtension)
    }
    
    static func updateMetadata(for url: URL, title: String, artist: String, album: String, year: String?, genre: String?, lyrics: String?) async throws {
        let fileExtension = url.pathExtension.lowercased()
        
        // 对于不同格式给出具体的错误信息
        switch fileExtension {
        case "mp3":
            throw MetadataError.mp3NotSupported
        case "flac":
            throw MetadataError.flacNotSupported
        case "ogg":
            throw MetadataError.oggNotSupported
        case "wav":
            throw MetadataError.wavNotSupported
        case "wma":
            throw MetadataError.wmaNotSupported
        case "ape":
            throw MetadataError.apeNotSupported
        case "opus":
            throw MetadataError.opusNotSupported
        case "m4a", "mp4", "aac":
            // 使用 AVFoundation 处理苹果格式
            try await updateAVFoundationMetadata(url: url, title: title, artist: artist, album: album, year: year, genre: genre, lyrics: lyrics)
        default:
            throw MetadataError.unsupportedFormat
        }
    }
    
    // 生成 FFmpeg 命令
    static func generateFFmpegCommand(for url: URL, title: String, artist: String, album: String) -> String {
        let fileExtension = url.pathExtension.lowercased()
        let inputPath = url.path.replacingOccurrences(of: " ", with: "\\ ")
        let outputPath = url.deletingPathExtension().appendingPathExtension("edited.\(fileExtension)").path.replacingOccurrences(of: " ", with: "\\ ")
        
        var metadataOptions: [String] = []
        
        // 添加元数据选项
        if !title.isEmpty {
            metadataOptions.append("-metadata title=\"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        if !artist.isEmpty {
            metadataOptions.append("-metadata artist=\"\(artist.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        if !album.isEmpty {
            metadataOptions.append("-metadata album=\"\(album.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        
        let metadataString = metadataOptions.joined(separator: " ")
        
        // 根据格式生成不同的命令
        switch fileExtension {
        case "mp3":
            return "ffmpeg -i \(inputPath) \(metadataString) -codec copy \(outputPath)"
        case "flac":
            return "ffmpeg -i \(inputPath) \(metadataString) -codec copy \(outputPath)"
        case "ogg":
            return "ffmpeg -i \(inputPath) \(metadataString) -codec copy \(outputPath)"
        case "wav":
            // WAV 格式转换为支持元数据的格式
            let m4aOutput = url.deletingPathExtension().appendingPathExtension("m4a").path.replacingOccurrences(of: " ", with: "\\ ")
            return "ffmpeg -i \(inputPath) \(metadataString) -codec:a aac -b:a 256k \(m4aOutput)"
        case "wma":
            return "ffmpeg -i \(inputPath) \(metadataString) -codec copy \(outputPath)"
        case "ape":
            // APE 转换为 FLAC
            let flacOutput = url.deletingPathExtension().appendingPathExtension("flac").path.replacingOccurrences(of: " ", with: "\\ ")
            return "ffmpeg -i \(inputPath) \(metadataString) -codec:a flac \(flacOutput)"
        case "opus":
            return "ffmpeg -i \(inputPath) \(metadataString) -codec copy \(outputPath)"
        default:
            return "# 不支持的格式: \(fileExtension)"
        }
    }
    
    // 生成完整的 FFmpeg 命令说明
    static func generateFFmpegCommandWithInstructions(for url: URL, title: String, artist: String, album: String) -> String {
        let command = generateFFmpegCommand(for: url, title: title, artist: artist, album: album)
        let fileExtension = url.pathExtension.lowercased()
        
        var instructions = """
        # 音频元数据编辑命令
        # 文件: \(url.lastPathComponent)
        # 格式: \(fileExtension.uppercased())
        
        # 使用说明:
        # 1. 确保已安装 FFmpeg (可通过 Homebrew 安装: brew install ffmpeg)
        # 2. 复制下面的命令到终端执行
        # 3. 执行完成后会生成新文件，原文件保持不变
        
        """
        
        // 添加格式特定说明
        switch fileExtension {
        case "wav":
            instructions += """
            # 注意: WAV 格式将转换为 M4A 格式以支持元数据
            
            """
        case "ape":
            instructions += """
            # 注意: APE 格式将转换为 FLAC 格式以获得更好的兼容性
            
            """
        default:
            instructions += """
            # 注意: 将生成带有 .edited 后缀的新文件
            
            """
        }
        
        instructions += command
        
        // 添加后续操作说明
        instructions += """
        
        
        # 执行完成后:
        # - 检查生成的文件是否正确
        # - 如果满意，可以删除原文件并重命名新文件
        # - 或者直接使用新生成的文件
        """
        
        return instructions
    }
    
    // 使用 AVFoundation 更新 M4A/MP4/AAC 元数据
    private static func updateAVFoundationMetadata(url: URL, title: String, artist: String, album: String, year: String?, genre: String?, lyrics: String?) async throws {
        // 创建可变资源
        let asset = AVURLAsset(url: url)
        
        // 汇总源文件的所有元数据项
        var sourceItems: [AVMetadataItem] = []
        if #available(macOS 13.0, *) {
            if let m = try? await asset.load(.metadata) { sourceItems.append(contentsOf: m) }
            if let m = try? await asset.load(.commonMetadata) { sourceItems.append(contentsOf: m) }
            if let formats = try? await asset.load(.availableMetadataFormats) {
                for format in formats {
                    if let m = try? await asset.loadMetadata(for: format) {
                        sourceItems.append(contentsOf: m)
                    }
                }
            }
        } else {
            sourceItems.append(contentsOf: asset.metadata)
            sourceItems.append(contentsOf: asset.commonMetadata)
            for format in asset.availableMetadataFormats {
                sourceItems.append(contentsOf: asset.metadata(forFormat: format))
            }
        }

        // 判断哪些字段需要覆盖
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedYear = year?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenre = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLyrics = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideTitle = !trimmedTitle.isEmpty
        let overrideArtist = !trimmedArtist.isEmpty
        let overrideAlbum = !trimmedAlbum.isEmpty
        let overrideYear = (trimmedYear?.isEmpty == false)
        let overrideGenre = (trimmedGenre?.isEmpty == false)
        let overrideLyrics = (trimmedLyrics?.isEmpty == false)

        // 先保留“未被覆盖”的原始项（包括封面 artwork、其它标签、以及歌词当不覆盖时）
        var preserved: [AVMetadataItem] = []
        preserved.reserveCapacity(sourceItems.count)
        for item in sourceItems {
            let common = item.commonKey?.rawValue.lowercased()
            let id = item.identifier?.rawValue.lowercased()
            // 被覆盖的键：仅当对应字段有新值时才移除旧值，否则保留旧值
            if overrideTitle, common == "title" { continue }
            if overrideArtist, common == "artist" { continue }
            if overrideAlbum, common == "albumname" { continue }
            if overrideYear, common == "creationdate" { continue }
            if overrideGenre, common == "type" { continue }
            if overrideLyrics {
                if common == "lyrics" { continue }
                if let id = id, id.contains("lyrics") || id.contains("lyric") || id.contains("sylt") { continue }
                if let k = item.key as? String, k.lowercased().contains("lyrics") || k.lowercased().contains("lyric") { continue }
            }
            preserved.append(item)
        }

        // 创建新的元数据项集合：在保留基础上追加我们要覆盖的字段
        var newMetadata: [AVMetadataItem] = []
        newMetadata.reserveCapacity(preserved.count + 6)
        for src in preserved {
            let m = AVMutableMetadataItem()
            m.keySpace = src.keySpace
            m.identifier = src.identifier
            m.key = src.key
            if #available(macOS 13.0, *) {
                if let v = try? await src.load(.value) { m.value = v }
                if let attrs = try? await src.load(.extraAttributes) { m.extraAttributes = attrs }
            } else {
                if let v = src.value { m.value = v }
                m.extraAttributes = src.extraAttributes
            }
            newMetadata.append(m)
        }
        
        // 添加标题
        if overrideTitle {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = trimmedTitle as NSString
            newMetadata.append(titleItem)
        }
        
        // 添加艺术家
        if overrideArtist {
            let artistItem = AVMutableMetadataItem()
            artistItem.identifier = .commonIdentifierArtist
            artistItem.value = trimmedArtist as NSString
            newMetadata.append(artistItem)
        }
        
        // 添加专辑
        if overrideAlbum {
            let albumItem = AVMutableMetadataItem()
            albumItem.identifier = .commonIdentifierAlbumName
            albumItem.value = trimmedAlbum as NSString
            newMetadata.append(albumItem)
        }
        
        // 添加年份（CreationDate）
        if overrideYear, let y = trimmedYear {
            let yearItem = AVMutableMetadataItem()
            yearItem.identifier = .commonIdentifierCreationDate
            yearItem.value = y as NSString
            newMetadata.append(yearItem)
        }
        
        // 添加类型（Genre）
        if overrideGenre, let g = trimmedGenre {
            let genreItem = AVMutableMetadataItem()
            genreItem.identifier = .commonIdentifierType
            genreItem.value = g as NSString
            newMetadata.append(genreItem)
        }
        
        // 歌词策略：
        // - 若传入非空歌词：覆盖为新的歌词项
        // - 若未传入歌词（nil 或空白）：从原文件提取并保留所有歌词相关元数据
        if overrideLyrics, let lyrics = trimmedLyrics {
            let lyricsItem = AVMutableMetadataItem()
            lyricsItem.identifier = AVMetadataIdentifier.iTunesMetadataLyrics
            lyricsItem.value = lyrics as NSString
            newMetadata.append(lyricsItem)
        }
        
        // 使用导出会话来保存带有新元数据的文件
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MetadataError.exportSessionCreationFailed
        }
        
        // 设置元数据（仅含我们覆盖的字段和保留的歌词；其他未指定字段由文件容器策略处理）
        exportSession.metadata = newMetadata
        
        // 创建临时文件URL
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        
        exportSession.outputURL = tempURL
        exportSession.outputFileType = getAVFileType(for: url.pathExtension)
        exportSession.shouldOptimizeForNetworkUse = false
        
        // 导出文件
        await exportSession.export()
        
        switch exportSession.status {
        case .completed:
            // 成功导出，替换原文件
            do {
                // 备份原文件权限
                let fileManager = FileManager.default
                let attributes = try fileManager.attributesOfItem(atPath: url.path)

                // 原子替换原文件，避免“先删后移”窗口导致异常时文件丢失
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)

                var attrsToRestore: [FileAttributeKey: Any] = [:]
                if let p = attributes[.posixPermissions] { attrsToRestore[.posixPermissions] = p }
                if let o = attributes[.ownerAccountID] { attrsToRestore[.ownerAccountID] = o }
                if let g = attributes[.groupOwnerAccountID] { attrsToRestore[.groupOwnerAccountID] = g }
                if !attrsToRestore.isEmpty {
                    try? fileManager.setAttributes(attrsToRestore, ofItemAtPath: url.path)
                }
                
            } catch {
                // 清理临时文件
                try? FileManager.default.removeItem(at: tempURL)
                throw MetadataError.fileReplacementFailed(error)
            }
            
        case .failed:
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
            throw MetadataError.exportFailed(exportSession.error)
            
        case .cancelled:
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
            throw MetadataError.exportCancelled
            
        default:
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
            throw MetadataError.unknownError
        }
    }
    
    private static func getAVFileType(for pathExtension: String) -> AVFileType {
        switch pathExtension.lowercased() {
        case "m4a", "aac":
            return .m4a
        case "mp4":
            return .mp4
        default:
            return .m4a
        }
    }
}

enum MetadataError: LocalizedError {
    case exportSessionCreationFailed
    case exportFailed(Error?)
    case exportCancelled
    case unsupportedFormat
    case fileReplacementFailed(Error)
    case unknownError
    case mp3NotSupported
    case flacNotSupported
    case oggNotSupported
    case wavNotSupported
    case wmaNotSupported
    case apeNotSupported
    case opusNotSupported
    
    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "无法创建导出会话"
        case .exportFailed(let error):
            return "导出失败: \(error?.localizedDescription ?? "未知错误")"
        case .exportCancelled:
            return "导出被取消"
        case .unsupportedFormat:
            return "不支持的文件格式"
        case .fileReplacementFailed(let error):
            return "文件替换失败: \(error.localizedDescription)"
        case .unknownError:
            return "发生未知错误"
        case .mp3NotSupported:
            return """
            MP3 元数据编辑暂不支持
            
            技术原因：
            • MP3 元数据编辑需要专门的第三方库
            • macOS 原生 API 不支持 MP3 元数据写入
            
            解决方案：
            • 当前版本支持 M4A、MP4、AAC 格式
            • 可以考虑将 MP3 转换为 M4A 格式后编辑
            """
        case .flacNotSupported:
            return """
            FLAC 元数据编辑暂不支持
            
            技术原因：
            • FLAC 格式需要专门的解码库支持
            • 当前版本优先支持苹果原生格式
            
            替代方案：
            • 建议使用 M4A 无损格式
            • 未来版本会考虑添加 FLAC 支持
            """
        case .oggNotSupported:
            return """
            OGG 元数据编辑暂不支持
            
            技术原因：
            • OGG 格式需要 Vorbis 库支持
            • 当前版本专注于主流格式
            
            替代方案：
            • 建议转换为 M4A 格式
            • 或使用专门的 OGG 编辑工具
            • 复制生成的 FFmpeg 命令到终端执行
            """
        case .wavNotSupported:
            return """
            WAV 元数据编辑暂不支持
            
            技术原因：
            • WAV 格式的元数据支持有限
            • 当前版本专注于压缩格式
            
            替代方案：
            • 建议转换为 M4A 格式获得更好的元数据支持
            • 复制生成的 FFmpeg 命令到终端执行
            """
        case .wmaNotSupported:
            return """
            WMA 元数据编辑暂不支持
            
            技术原因：
            • WMA 是微软专有格式，需要特殊库支持
            • macOS 原生不完全支持 WMA 编辑
            
            替代方案：
            • 建议转换为开放格式如 M4A
            • 复制生成的 FFmpeg 命令到终端执行
            """
        case .apeNotSupported:
            return """
            APE 元数据编辑暂不支持
            
            技术原因：
            • APE 是无损压缩格式，需要专门解码器
            • 当前版本不包含 APE 支持库
            
            替代方案：
            • 建议转换为 FLAC 或 M4A 格式
            • 复制生成的 FFmpeg 命令到终端执行
            """
        case .opusNotSupported:
            return """
            OPUS 元数据编辑暂不支持
            
            技术原因：
            • OPUS 是较新的开源编解码器
            • 需要专门的 Opus 库支持
            
            替代方案：
            • 建议转换为 M4A 格式
            • 复制生成的 FFmpeg 命令到终端执行
            """
        }
    }
}
