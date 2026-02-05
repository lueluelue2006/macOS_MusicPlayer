import Foundation
import AppKit
import MusicPlayerIPC

final class IPCServer {
    private let audioPlayer: AudioPlayer
    private let playlistManager: PlaylistManager
    private let center = DistributedNotificationCenter.default()
    private var observer: NSObjectProtocol?

    init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        start()
    }

    deinit {
        if let observer {
            center.removeObserver(observer)
        }
    }

    private func start() {
        observer = center.addObserver(
            forName: MusicPlayerIPC.requestNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] notification in
            self?.handle(notification)
        }
    }

    private func handle(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let data = userInfo[MusicPlayerIPC.payloadKey] as? Data,
            let request = try? MusicPlayerIPC.decodePayload(IPCRequest.self, from: data)
        else { return }

        Task { @MainActor in
            let reply = await self.handleRequest(request)
            self.postReply(reply)
        }
    }

    @MainActor
    private func handleRequest(_ request: IPCRequest) async -> IPCReply {
        switch request.command {
        case .ping:
            return IPCReply(id: request.id, ok: true, message: "pong")

        case .status:
            return IPCReply(
                id: request.id,
                ok: true,
                message: audioPlayer.currentFile?.url.lastPathComponent ?? "",
                data: statusSnapshot()
            )

        case .benchmarkLoad:
            guard let raw = request.arguments?["path"] else {
                return IPCReply(id: request.id, ok: false, message: "missing path")
            }
            let expanded = (raw as NSString).expandingTildeInPath
            let folderURL = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
                return IPCReply(id: request.id, ok: false, message: "not a directory: \(expanded)")
            }

            let limit: Int = {
                if let rawLimit = request.arguments?["limit"], let n = Int(rawLimit), n >= 0 { return n }
                return 0
            }()

            let report = await LoadBenchmark.run(folderURL: folderURL, limit: limit)
            let outURL = LoadBenchmark.defaultReportURL()
            do {
                try LoadBenchmark.writeReport(report, to: outURL)
            } catch {
                return IPCReply(id: request.id, ok: false, message: "failed to write report: \(error)")
            }

            let s = report.summary
            let summaryLine = [
                "files=\(s.totalFiles)",
                "lyrics=\(s.testedLyricsFiles) avg cold=\(formatMs(s.lyricsColdAvgMs)) warm=\(formatMs(s.lyricsWarmAvgMs))",
                "artwork=\(s.testedArtworkFiles) avg fetch=\(formatMs(s.artworkFetchAvgMs)) decode cold=\(formatMs(s.artworkDecodeColdAvgMs)) warm=\(formatMs(s.artworkDecodeWarmAvgMs))",
                "report=\(outURL.path)"
            ].joined(separator: " | ")

            return IPCReply(
                id: request.id,
                ok: true,
                message: summaryLine,
                data: [
                    "reportPath": outURL.path,
                    "totalFiles": "\(s.totalFiles)",
                    "testedLyricsFiles": "\(s.testedLyricsFiles)",
                    "testedArtworkFiles": "\(s.testedArtworkFiles)"
                ]
            )

        case .clearLyricsCache:
            await LyricsService.shared.invalidateAll()
            // Also clear in-memory timeline attached to the current track to avoid confusing "still showing old lyrics".
            audioPlayer.lyricsTimeline = nil
            if let current = audioPlayer.currentFile {
                audioPlayer.currentFile = AudioFile(url: current.url, metadata: current.metadata, lyricsTimeline: nil, duration: current.duration)
            }
            return IPCReply(id: request.id, ok: true)

        case .clearArtworkCache:
            audioPlayer.clearArtworkCache()
            return IPCReply(id: request.id, ok: true)

        case .setSearchSortOption:
            guard let rawTarget = request.arguments?["target"] else {
                return IPCReply(id: request.id, ok: false, message: "missing target")
            }
            guard let target = SearchFocusTarget(rawValue: rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return IPCReply(id: request.id, ok: false, message: "invalid target: \(rawTarget)")
            }
            guard let rawField = request.arguments?["field"] else {
                return IPCReply(id: request.id, ok: false, message: "missing field")
            }
            let fieldKey = rawField.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let field: SearchSortField? = {
                switch fieldKey {
                case "original", "default", "none":
                    return .original
                case "weight":
                    return .weight
                case "title", "name":
                    return .title
                case "artist":
                    return .artist
                case "duration", "time":
                    return .duration
                case "format", "ext", "extension":
                    return .format
                default:
                    return nil
                }
            }()
            guard let field else {
                return IPCReply(id: request.id, ok: false, message: "invalid field: \(rawField)")
            }

            let directionKey = request.arguments?["direction"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let direction: SearchSortDirection = {
                switch directionKey {
                case "desc", "descending", "down":
                    return .descending
                case "asc", "ascending", "up", nil:
                    return .ascending
                default:
                    return .ascending
                }
            }()

            SearchSortState.shared.setOption(SearchSortOption(field: field, direction: direction), for: target)
            return IPCReply(
                id: request.id,
                ok: true,
                message: "sort=\(field.displayName) (\(direction.displayName)) target=\(target.rawValue)",
                data: ["target": target.rawValue, "field": field.rawValue, "direction": direction.rawValue]
            )

        case .resetSearchSortOption:
            guard let rawTarget = request.arguments?["target"] else {
                return IPCReply(id: request.id, ok: false, message: "missing target")
            }
            guard let target = SearchFocusTarget(rawValue: rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return IPCReply(id: request.id, ok: false, message: "invalid target: \(rawTarget)")
            }
            SearchSortState.shared.setOption(.default, for: target)
            return IPCReply(id: request.id, ok: true, message: "sort reset target=\(target.rawValue)")

        case .toggleSearchSortOption:
            guard let rawTarget = request.arguments?["target"] else {
                return IPCReply(id: request.id, ok: false, message: "missing target")
            }
            guard let target = SearchFocusTarget(rawValue: rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return IPCReply(id: request.id, ok: false, message: "invalid target: \(rawTarget)")
            }
            let current = SearchSortState.shared.option(for: target)
            if current.field == .original {
                SearchSortState.shared.setOption(SearchSortOption(field: .title, direction: .ascending), for: target)
                return IPCReply(id: request.id, ok: true, message: "sort enabled target=\(target.rawValue)")
            }
            SearchSortState.shared.setOption(.default, for: target)
            return IPCReply(id: request.id, ok: true, message: "sort disabled target=\(target.rawValue)")

        case .togglePlayPause:
            audioPlayer.togglePlayPause()
            return IPCReply(id: request.id, ok: true)

        case .pause:
            audioPlayer.pause()
            return IPCReply(id: request.id, ok: true)

        case .resume:
            audioPlayer.resume()
            return IPCReply(id: request.id, ok: true)

        case .toggleShuffle:
            audioPlayer.toggleShuffle()
            return IPCReply(id: request.id, ok: true)

        case .toggleLoop:
            audioPlayer.toggleLoop()
            return IPCReply(id: request.id, ok: true)

        case .next:
            guard let nextFile = playlistManager.nextFile(isShuffling: audioPlayer.isShuffling) else {
                return IPCReply(id: request.id, ok: false, message: "no next track")
            }
            audioPlayer.play(nextFile)
            return IPCReply(id: request.id, ok: true)

        case .previous:
            guard let prevFile = playlistManager.previousFile(isShuffling: audioPlayer.isShuffling) else {
                return IPCReply(id: request.id, ok: false, message: "no previous track")
            }
            audioPlayer.play(prevFile)
            return IPCReply(id: request.id, ok: true)

        case .random:
            guard let f = playlistManager.getRandomFileExcludingCurrent() else {
                return IPCReply(id: request.id, ok: false, message: "no random track available")
            }
            audioPlayer.play(f)
            return IPCReply(id: request.id, ok: true)

        case .playIndex:
            guard let raw = request.arguments?["index"], let idx = Int(raw) else {
                return IPCReply(id: request.id, ok: false, message: "missing/invalid index")
            }
            playlistManager.setPlaybackScopeQueue()
            guard let f = playlistManager.selectFile(at: idx) else {
                return IPCReply(id: request.id, ok: false, message: "index out of range")
            }
            audioPlayer.play(f)
            return IPCReply(id: request.id, ok: true, message: f.url.lastPathComponent)

        case .playQuery:
            guard let raw = request.arguments?["query"] else {
                return IPCReply(id: request.id, ok: false, message: "missing query")
            }
            playlistManager.setPlaybackScopeQueue()
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = query
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "empty query")
            }

            if let match = playlistManager.audioFiles.enumerated().first(where: { (_, file) in
                let fields = [
                    file.metadata.title,
                    file.metadata.artist,
                    file.metadata.album,
                    file.url.lastPathComponent,
                    file.url.path
                ]
                return tokens.allSatisfy { token in
                    fields.contains(where: { $0.localizedCaseInsensitiveContains(token) })
                }
            }) {
                guard let selected = playlistManager.selectFile(at: match.offset) else {
                    return IPCReply(id: request.id, ok: false, message: "failed to select match")
                }
                audioPlayer.play(selected)
                return IPCReply(id: request.id, ok: true, message: selected.url.lastPathComponent)
            }
            return IPCReply(id: request.id, ok: false, message: "no match for query")

        case .seek:
            guard audioPlayer.currentFile != nil else {
                return IPCReply(id: request.id, ok: false, message: "no track loaded")
            }
            guard let raw = request.arguments?["time"], let t = Double(raw), t.isFinite else {
                return IPCReply(id: request.id, ok: false, message: "missing/invalid time")
            }
            let duration = audioPlayer.playbackClock.duration
            let clamped = duration > 0 ? max(0, min(t, duration)) : max(0, t)
            audioPlayer.seek(to: clamped)
            return IPCReply(id: request.id, ok: true, data: ["time": String(format: "%.3f", clamped)])

        case .setVolume:
            guard let raw = request.arguments?["value"], let v = Float(raw), v.isFinite else {
                return IPCReply(id: request.id, ok: false, message: "missing/invalid value")
            }
            audioPlayer.setVolume(max(0, min(1, v)))
            return IPCReply(id: request.id, ok: true)

        case .setRate:
            guard let raw = request.arguments?["value"], let v = Float(raw), v.isFinite else {
                return IPCReply(id: request.id, ok: false, message: "missing/invalid value")
            }
            audioPlayer.setPlaybackRate(v)
            return IPCReply(id: request.id, ok: true, data: ["rate": String(format: "%.3f", audioPlayer.playbackRate)])

        case .toggleNormalization:
            audioPlayer.toggleNormalization()
            return IPCReply(id: request.id, ok: true)

        case .setNormalizationEnabled:
            guard let raw = request.arguments?["enabled"] else {
                return IPCReply(id: request.id, ok: false, message: "missing enabled")
            }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let enabled: Bool?
            switch normalized {
            case "1", "true", "yes", "on":
                enabled = true
            case "0", "false", "no", "off":
                enabled = false
            default:
                enabled = nil
            }
            guard let enabled else {
                return IPCReply(id: request.id, ok: false, message: "invalid enabled value")
            }
            audioPlayer.setNormalizationEnabled(enabled)
            return IPCReply(id: request.id, ok: true)

        case .add:
            guard let paths = request.paths, !paths.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "missing paths")
            }
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            playlistManager.enqueueAddFiles(urls)
            return IPCReply(id: request.id, ok: true, message: "enqueued \(urls.count) item(s)")

        case .remove:
            let currentURL = audioPlayer.currentFile?.url

            if let raw = request.arguments?["index"], let idx = Int(raw), idx >= 0 {
                guard idx < playlistManager.audioFiles.count else {
                    return IPCReply(id: request.id, ok: false, message: "index out of range")
                }
                let urlToRemove = playlistManager.audioFiles[idx].url
                playlistManager.removeFile(at: idx)
                if let currentURL, currentURL == urlToRemove {
                    audioPlayer.handleCurrentTrackRemoved(remainingFiles: playlistManager.audioFiles, playNext: nil)
                }
                return IPCReply(
                    id: request.id,
                    ok: true,
                    message: "removed \(urlToRemove.lastPathComponent)",
                    data: ["removedCount": "1", "removedIndex": "\(idx)"]
                )
            }

            guard let raw = request.arguments?["query"] else {
                return IPCReply(id: request.id, ok: false, message: "missing query or index")
            }
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = query
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "empty query")
            }

            func matches(_ file: AudioFile) -> Bool {
                let fields = [
                    file.metadata.title,
                    file.metadata.artist,
                    file.metadata.album,
                    file.url.lastPathComponent,
                    file.url.path
                ]
                return tokens.allSatisfy { token in
                    fields.contains(where: { $0.localizedCaseInsensitiveContains(token) })
                }
            }

            let matchesList: [(Int, AudioFile)] = playlistManager.audioFiles.enumerated().compactMap { (idx, file) in
                matches(file) ? (idx, file) : nil
            }

            guard !matchesList.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "no match for query")
            }

            let mode = request.arguments?["mode"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let removeAll = (mode == "all")

            if !removeAll, matchesList.count > 1 {
                let preview = matchesList.prefix(8).map { (idx, file) in
                    let title = file.metadata.title.isEmpty ? file.url.lastPathComponent : file.metadata.title
                    return "[\(idx)] \(title)"
                }.joined(separator: "\n")
                let suffix = matchesList.count > 8 ? "\n…" : ""
                return IPCReply(
                    id: request.id,
                    ok: false,
                    message: "\(matchesList.count) matches. Use remove --index <n> or remove --all <query>.\n\(preview)\(suffix)"
                )
            }

            let indicesToRemove: [Int] = removeAll ? matchesList.map { $0.0 } : [matchesList[0].0]
            let urlsToRemove: [URL] = indicesToRemove.compactMap { idx in
                guard idx >= 0, idx < playlistManager.audioFiles.count else { return nil }
                return playlistManager.audioFiles[idx].url
            }

            for idx in indicesToRemove.sorted(by: >) {
                if idx >= 0, idx < playlistManager.audioFiles.count {
                    playlistManager.removeFile(at: idx)
                }
            }

            if let currentURL, urlsToRemove.contains(currentURL) {
                audioPlayer.handleCurrentTrackRemoved(remainingFiles: playlistManager.audioFiles, playNext: nil)
            }

            return IPCReply(
                id: request.id,
                ok: true,
                message: "removed \(urlsToRemove.count) item(s)",
                data: ["removedCount": "\(urlsToRemove.count)"]
            )

        case .screenshot:
            let outPathRaw = request.arguments?["outPath"]
            let outPath = (outPathRaw as NSString?)?.expandingTildeInPath

            guard let window = bestWindowForScreenshot() else {
                return IPCReply(id: request.id, ok: false, message: "no window to capture")
            }
            guard let data = capturePNG(of: window) else {
                return IPCReply(id: request.id, ok: false, message: "failed to render window")
            }

            do {
                let outURL = try writeScreenshot(data: data, preferredPath: outPath)
                return IPCReply(id: request.id, ok: true, data: ["outPath": outURL.path])
            } catch {
                return IPCReply(id: request.id, ok: false, message: "write failed: \(error.localizedDescription)")
            }
        }
    }

    private func postReply(_ reply: IPCReply) {
        guard let data = try? MusicPlayerIPC.encodePayload(reply) else { return }
        center.postNotificationName(
            MusicPlayerIPC.replyNotification,
            object: nil,
            userInfo: [MusicPlayerIPC.payloadKey: data],
            deliverImmediately: true
        )
    }

    private func formatMs(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.1fms", value)
    }

    @MainActor
    private func statusSnapshot() -> [String: String] {
        var data: [String: String] = [:]
        data["isPlaying"] = audioPlayer.isPlaying ? "true" : "false"
        data["volume"] = String(format: "%.3f", audioPlayer.volume)
        data["rate"] = String(format: "%.3f", audioPlayer.playbackRate)
        data["isLooping"] = audioPlayer.isLooping ? "true" : "false"
        data["isShuffling"] = audioPlayer.isShuffling ? "true" : "false"
        data["normalizationEnabled"] = audioPlayer.isNormalizationEnabled ? "true" : "false"
        data["outputDeviceName"] = audioPlayer.currentOutputDeviceName
        data["playlistCount"] = "\(playlistManager.audioFiles.count)"
        data["currentIndex"] = "\(playlistManager.currentIndex)"
        switch playlistManager.playbackScope {
        case .queue:
            data["playbackScope"] = "queue"
        case .playlist(let id):
            data["playbackScope"] = "playlist"
            data["playbackScopePlaylistID"] = id.uuidString
        }
        data["currentTime"] = String(format: "%.3f", audioPlayer.playbackClock.currentTime)
        data["duration"] = String(format: "%.3f", audioPlayer.playbackClock.duration)

        if let f = audioPlayer.currentFile {
            data["currentPath"] = f.url.path
            data["title"] = f.metadata.title
            data["artist"] = f.metadata.artist
            data["album"] = f.metadata.album
        }
        return data
    }

    @MainActor
    private func bestWindowForScreenshot() -> NSWindow? {
        if let w = NSApp.keyWindow { return w }
        if let w = NSApp.windows.first(where: { $0.isVisible }) { return w }
        return NSApp.windows.first
    }

    @MainActor
    private func capturePNG(of window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }
        let rect = view.bounds
        guard rect.width > 1, rect.height > 1 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        rep.size = rect.size
        return rep.representation(using: .png, properties: [:])
    }

    private func writeScreenshot(data: Data, preferredPath: String?) throws -> URL {
        let fm = FileManager.default
        let baseURL = fm.homeDirectoryForCurrentUser
        let defaultName = "MusicPlayer.png"

        let raw = (preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let initialURL: URL = {
            if let raw {
                return URL(fileURLWithPath: raw)
            }
            return baseURL.appendingPathComponent(defaultName, isDirectory: false)
        }()

        let ensuredPNG: URL = initialURL.pathExtension.lowercased() == "png"
            ? initialURL
            : initialURL.deletingPathExtension().appendingPathExtension("png")

        let outURL = uniqueURL(ensuredPNG)
        let dir = outURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try data.write(to: outURL, options: [.atomic])
        return outURL
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }

        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension

        for i in 1...9999 {
            let candidate = dir.appendingPathComponent("\(base)-\(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString)").appendingPathExtension(ext)
    }
}
