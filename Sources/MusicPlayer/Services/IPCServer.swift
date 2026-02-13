import Foundation
import AppKit
import MusicPlayerIPC

final class IPCServer {
    private let audioPlayer: AudioPlayer
    private let playlistManager: PlaylistManager
    private let playlistsStore: PlaylistsStore
    private let center = DistributedNotificationCenter.default()
    private var observer: NSObjectProtocol?

    init(audioPlayer: AudioPlayer, playlistManager: PlaylistManager, playlistsStore: PlaylistsStore) {
        self.audioPlayer = audioPlayer
        self.playlistManager = playlistManager
        self.playlistsStore = playlistsStore
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
        guard isRequestAllowed(request) else {
            return IPCReply(
                id: request.id,
                ok: false,
                message: "CLI 调试模式未开启。请在菜单“设置 > 启用 CLI 调试模式”后重试。"
            )
        }

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

        case .setIPCDebugEnabled:
            return handleSetIPCDebugEnabled(request)

        case .debugSnapshot:
            return await handleDebugSnapshot(request)

        case .queueSnapshot:
            return handleQueueSnapshot(request)

        case .clearQueue:
            return handleClearQueue(request)

        case .searchQueue:
            return handleSearchQueue(request)

        case .playlistsSnapshot:
            return await handlePlaylistsSnapshot(request)

        case .playlistTracksSnapshot:
            return await handlePlaylistTracksSnapshot(request)

        case .createPlaylist:
            return await handleCreatePlaylist(request)

        case .renamePlaylist:
            return await handleRenamePlaylist(request)

        case .deletePlaylist:
            return await handleDeletePlaylist(request)

        case .selectPlaylist:
            return await handleSelectPlaylist(request)

        case .addTracksToPlaylist:
            return await handleAddTracksToPlaylist(request)

        case .removeTracksFromPlaylist:
            return await handleRemoveTracksFromPlaylist(request)

        case .playPlaylistTrack:
            return await handlePlayPlaylistTrack(request)

        case .setPlaybackScope:
            return await handleSetPlaybackScope(request)

        case .locateNowPlaying:
            return handleLocateNowPlaying(request)

        case .setWeight:
            return handleSetWeight(request)

        case .getWeight:
            return handleGetWeight(request)

        case .clearWeights:
            return handleClearWeights(request)

        case .syncPlaylistWeightsToQueue:
            return await handleSyncPlaylistWeightsToQueue(request)

        case .setLyricsVisible:
            return handleSetLyricsVisible(request)

        case .toggleLyricsVisible:
            return handleToggleLyricsVisible(request)

        case .volumePreanalysis:
            return await handleVolumePreanalysis(request)

        case .setAnalysisOptions:
            return handleSetAnalysisOptions(request)

        case .setScanSubfolders:
            return handleSetScanSubfolders(request)

        case .refreshMetadata:
            return await handleRefreshMetadata(request)

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

    private struct QueueSnapshotItem: Codable {
        let index: Int
        let id: String
        let path: String
        let title: String
        let artist: String
        let album: String
        let duration: Double?
        let isCurrent: Bool
        let isInFiltered: Bool
        let queueWeight: Int
    }

    private struct QueueSnapshotPayload: Codable {
        let total: Int
        let offset: Int
        let returned: Int
        let searchText: String
        let items: [QueueSnapshotItem]
    }

    private struct PlaylistSummaryItem: Codable {
        let id: String
        let name: String
        let trackCount: Int
        let isSelected: Bool
        let isActivePlaybackScope: Bool
    }

    private struct PlaylistSummaryPayload: Codable {
        let selectedPlaylistID: String?
        let items: [PlaylistSummaryItem]
    }

    private struct PlaylistTrackItem: Codable {
        let index: Int
        let path: String
        let fileName: String
        let exists: Bool
        let isCurrent: Bool
        let queueWeight: Int
        let playlistWeight: Int
    }

    private struct PlaylistTracksPayload: Codable {
        let playlistID: String
        let playlistName: String
        let total: Int
        let returned: Int
        let offset: Int
        let items: [PlaylistTrackItem]
    }

    private struct PreanalysisSnapshot: Codable {
        let running: Bool
        let total: Int
        let completed: Int
        let currentFile: String
        let cacheCount: Int
    }

    private struct DebugSnapshotPayload: Codable {
        let debugModeEnabled: Bool
        let status: [String: String]
        let queue: QueueSnapshotPayload
        let playlists: PlaylistSummaryPayload
        let preanalysis: PreanalysisSnapshot
    }

    @MainActor
    private func handleSetIPCDebugEnabled(_ request: IPCRequest) -> IPCReply {
        let mode = request.arguments?["enabled"] ?? request.arguments?["mode"]
        let normalized = mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let newValue: Bool
        switch normalized {
        case nil, "", "toggle":
            newValue = !IPCDebugSettings.isEnabled()
        default:
            guard let value = parseBool(normalized) else {
                return IPCReply(id: request.id, ok: false, message: "invalid enabled value")
            }
            newValue = value
        }

        IPCDebugSettings.setEnabled(newValue)
        return IPCReply(
            id: request.id,
            ok: true,
            message: newValue ? "CLI 调试模式已开启" : "CLI 调试模式已关闭",
            data: ["enabled": boolString(newValue)]
        )
    }

    @MainActor
    private func handleDebugSnapshot(_ request: IPCRequest) async -> IPCReply {
        let limit: Int = {
            if let raw = request.arguments?["queueLimit"], let n = Int(raw) {
                return max(1, min(200, n))
            }
            return 40
        }()

        let queue = makeQueueSnapshot(offset: 0, limit: limit)
        let playlists = await makePlaylistsSnapshot()
        let payload = DebugSnapshotPayload(
            debugModeEnabled: IPCDebugSettings.isEnabled(),
            status: statusSnapshot(),
            queue: queue,
            playlists: playlists,
            preanalysis: preanalysisSnapshot()
        )

        guard let json = encodeJSON(payload) else {
            return IPCReply(id: request.id, ok: false, message: "failed to encode snapshot")
        }
        return IPCReply(
            id: request.id,
            ok: true,
            data: [
                "enabled": boolString(IPCDebugSettings.isEnabled()),
                "json": json,
                "queueReturned": "\(queue.returned)",
                "playlistCount": "\(playlists.items.count)"
            ]
        )
    }

    @MainActor
    private func handleQueueSnapshot(_ request: IPCRequest) -> IPCReply {
        let offset: Int = {
            if let raw = request.arguments?["offset"], let n = Int(raw) {
                return max(0, n)
            }
            return 0
        }()
        let limit: Int = {
            if let raw = request.arguments?["limit"], let n = Int(raw), n > 0 {
                return min(2000, n)
            }
            return 200
        }()

        let payload = makeQueueSnapshot(offset: offset, limit: limit)
        guard let json = encodeJSON(payload) else {
            return IPCReply(id: request.id, ok: false, message: "failed to encode queue snapshot")
        }

        return IPCReply(
            id: request.id,
            ok: true,
            message: "queue total=\(payload.total), returned=\(payload.returned)",
            data: [
                "total": "\(payload.total)",
                "returned": "\(payload.returned)",
                "offset": "\(payload.offset)",
                "json": json
            ]
        )
    }

    @MainActor
    private func handleClearQueue(_ request: IPCRequest) -> IPCReply {
        playlistManager.clearAllFiles()
        audioPlayer.stopAndClearCurrent()
        return IPCReply(id: request.id, ok: true, message: "queue cleared")
    }

    @MainActor
    private func handleSearchQueue(_ request: IPCRequest) -> IPCReply {
        let query = request.arguments?["query"] ?? ""
        playlistManager.searchFiles(query)
        return IPCReply(
            id: request.id,
            ok: true,
            message: "search updated",
            data: [
                "query": query,
                "filteredCount": "\(playlistManager.filteredFiles.count)",
                "totalCount": "\(playlistManager.audioFiles.count)"
            ]
        )
    }

    @MainActor
    private func handlePlaylistsSnapshot(_ request: IPCRequest) async -> IPCReply {
        let payload = await makePlaylistsSnapshot()
        guard let json = encodeJSON(payload) else {
            return IPCReply(id: request.id, ok: false, message: "failed to encode playlists snapshot")
        }
        return IPCReply(
            id: request.id,
            ok: true,
            data: [
                "count": "\(payload.items.count)",
                "selectedPlaylistID": payload.selectedPlaylistID ?? "",
                "json": json
            ]
        )
    }

    @MainActor
    private func handlePlaylistTracksSnapshot(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: true) else {
            return IPCReply(id: request.id, ok: false, message: "missing playlistID and no selected playlist")
        }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }

        let offset: Int = {
            if let raw = request.arguments?["offset"], let n = Int(raw) {
                return max(0, n)
            }
            return 0
        }()
        let limit: Int = {
            if let raw = request.arguments?["limit"], let n = Int(raw), n > 0 {
                return min(2000, n)
            }
            return 200
        }()

        let currentLookup = currentTrackLookupSet()
        let allItems: [PlaylistTrackItem] = playlist.tracks.enumerated().map { entry in
            let path = entry.element.path
            let url = URL(fileURLWithPath: path)
            let exists = FileManager.default.fileExists(atPath: path)
            let lookup = Set(PathKey.lookupKeys(for: url))
            return PlaylistTrackItem(
                index: entry.offset,
                path: path,
                fileName: url.lastPathComponent,
                exists: exists,
                isCurrent: !currentLookup.isDisjoint(with: lookup),
                queueWeight: PlaybackWeights.shared.level(for: url, scope: .queue).rawValue,
                playlistWeight: PlaybackWeights.shared.level(for: url, scope: .playlist(playlistID)).rawValue
            )
        }

        let page = Array(allItems.dropFirst(offset).prefix(limit))
        let payload = PlaylistTracksPayload(
            playlistID: playlistID.uuidString,
            playlistName: playlist.name,
            total: allItems.count,
            returned: page.count,
            offset: offset,
            items: page
        )

        guard let json = encodeJSON(payload) else {
            return IPCReply(id: request.id, ok: false, message: "failed to encode playlist tracks snapshot")
        }

        return IPCReply(
            id: request.id,
            ok: true,
            data: [
                "playlistID": playlistID.uuidString,
                "total": "\(payload.total)",
                "returned": "\(payload.returned)",
                "offset": "\(payload.offset)",
                "json": json
            ]
        )
    }

    @MainActor
    private func handleCreatePlaylist(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        let name = request.arguments?["name"] ?? ""
        let urls: [URL] = (request.paths ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        playlistsStore.createPlaylist(name: name, trackURLs: urls)
        let createdID = playlistsStore.selectedPlaylistID?.uuidString ?? ""
        return IPCReply(
            id: request.id,
            ok: true,
            message: "playlist created",
            data: ["playlistID": createdID]
        )
    }

    @MainActor
    private func handleRenamePlaylist(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: false) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard let name = request.arguments?["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return IPCReply(id: request.id, ok: false, message: "missing name")
        }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }
        playlistsStore.renamePlaylist(playlist, to: name)
        return IPCReply(id: request.id, ok: true, message: "playlist renamed")
    }

    @MainActor
    private func handleDeletePlaylist(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: false) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }
        if playlistManager.playbackScope == .playlist(playlistID) {
            playlistManager.setPlaybackScopeQueue()
        }
        playlistsStore.deletePlaylist(playlist)
        return IPCReply(id: request.id, ok: true, message: "playlist deleted")
    }

    @MainActor
    private func handleSelectPlaylist(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: false) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard playlistsStore.playlist(for: playlistID) != nil else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }
        playlistsStore.selectedPlaylistID = playlistID
        return IPCReply(id: request.id, ok: true, message: "playlist selected", data: ["playlistID": playlistID.uuidString])
    }

    @MainActor
    private func handleAddTracksToPlaylist(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: false) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }

        let pathList: [String] = {
            if let paths = request.paths, !paths.isEmpty { return paths }
            if let one = request.arguments?["path"], !one.isEmpty { return [one] }
            return []
        }()

        guard !pathList.isEmpty else {
            return IPCReply(id: request.id, ok: false, message: "missing path(s)")
        }

        let urls = pathList.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let before = playlist.tracks.count
        playlistsStore.addTracks(urls, to: playlistID)
        let after = playlistsStore.playlist(for: playlistID)?.tracks.count ?? before

        if playlistManager.playbackScope == .playlist(playlistID) {
            refreshPlaybackScopePlaylistTracks(playlistID)
        }

        return IPCReply(
            id: request.id,
            ok: true,
            message: "tracks added",
            data: [
                "playlistID": playlistID.uuidString,
                "addedCount": "\(max(0, after - before))",
                "trackCount": "\(after)"
            ]
        )
    }

    @MainActor
    private func handleRemoveTracksFromPlaylist(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: false) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }

        var pathsToRemove: [String] = []
        let mode = request.arguments?["mode"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let removeAllMatches = (mode == "all") || (parseBool(request.arguments?["all"]) ?? false)

        if let rawIndex = request.arguments?["index"], let index = Int(rawIndex) {
            guard index >= 0, index < playlist.tracks.count else {
                return IPCReply(id: request.id, ok: false, message: "index out of range")
            }
            pathsToRemove = [playlist.tracks[index].path]
        } else if let rawPath = request.arguments?["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            pathsToRemove = [(rawPath as NSString).expandingTildeInPath]
        } else if let rawQuery = request.arguments?["query"] {
            let tokens = tokenizeQuery(rawQuery)
            guard !tokens.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "empty query")
            }

            let matches = playlist.tracks.enumerated().filter { _, track in
                let url = URL(fileURLWithPath: track.path)
                let fields = [url.lastPathComponent, track.path]
                return tokens.allSatisfy { token in
                    fields.contains(where: { $0.localizedCaseInsensitiveContains(token) })
                }
            }

            guard !matches.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "no match for query")
            }

            if !removeAllMatches, matches.count > 1 {
                let preview = matches.prefix(8).map { "[\($0.offset)] \(URL(fileURLWithPath: $0.element.path).lastPathComponent)" }.joined(separator: "\n")
                let suffix = matches.count > 8 ? "\n…" : ""
                return IPCReply(
                    id: request.id,
                    ok: false,
                    message: "\(matches.count) matches. Use --index or mode=all.\n\(preview)\(suffix)"
                )
            }
            pathsToRemove = removeAllMatches ? matches.map { $0.element.path } : [matches[0].element.path]
        } else {
            return IPCReply(id: request.id, ok: false, message: "missing index/path/query")
        }

        guard !pathsToRemove.isEmpty else {
            return IPCReply(id: request.id, ok: false, message: "no tracks to remove")
        }

        let deduped = Array(Set(pathsToRemove))
        for path in deduped {
            playlistsStore.removeTrack(path: path, from: playlistID)
        }

        if playlistManager.playbackScope == .playlist(playlistID) {
            refreshPlaybackScopePlaylistTracks(playlistID)
        }

        let remaining = playlistsStore.playlist(for: playlistID)?.tracks.count ?? 0
        return IPCReply(
            id: request.id,
            ok: true,
            message: "removed \(deduped.count) item(s)",
            data: [
                "removedCount": "\(deduped.count)",
                "trackCount": "\(remaining)",
                "playlistID": playlistID.uuidString
            ]
        )
    }

    @MainActor
    private func handlePlayPlaylistTrack(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: false) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }

        let fm = FileManager.default
        let urlsInOrder = playlist.tracks
            .map { URL(fileURLWithPath: $0.path) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !urlsInOrder.isEmpty else {
            return IPCReply(id: request.id, ok: false, message: "playlist has no playable tracks")
        }

        let targetURL: URL = {
            if let raw = request.arguments?["index"], let index = Int(raw), index >= 0, index < urlsInOrder.count {
                return urlsInOrder[index]
            }
            if let raw = request.arguments?["query"] {
                let tokens = tokenizeQuery(raw)
                if let matched = urlsInOrder.first(where: { url in
                    let fields = [url.lastPathComponent, url.path]
                    return tokens.allSatisfy { token in
                        fields.contains(where: { $0.localizedCaseInsensitiveContains(token) })
                    }
                }) {
                    return matched
                }
            }
            return urlsInOrder[0]
        }()

        var queueMap: [String: AudioFile] = [:]
        queueMap.reserveCapacity(playlistManager.audioFiles.count * 2)
        for file in playlistManager.audioFiles {
            for key in PathKey.lookupKeys(for: file.url) {
                queueMap[key] = file
            }
        }

        let playableFiles: [AudioFile] = urlsInOrder.map { url in
            if let existing = PathKey.lookupKeys(for: url).compactMap({ queueMap[$0] }).first {
                return existing
            }
            let title = url.deletingPathExtension().lastPathComponent
            let metadata = AudioMetadata(
                title: title.isEmpty ? "未知标题" : title,
                artist: "未知艺术家",
                album: "未知专辑",
                year: nil,
                genre: nil,
                artwork: nil
            )
            return AudioFile(url: url, metadata: metadata, duration: nil)
        }

        guard let selectedIndex = playlistManager.ensureInQueue(playableFiles, focusURL: targetURL),
              let selected = playlistManager.selectFile(at: selectedIndex) else {
            return IPCReply(id: request.id, ok: false, message: "failed to queue playlist track")
        }

        playlistsStore.selectedPlaylistID = playlistID
        playlistManager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: urlsInOrder)

        if audioPlayer.currentFile?.url == selected.url {
            if !audioPlayer.isPlaying {
                audioPlayer.resume()
            }
        } else {
            audioPlayer.play(selected)
        }

        return IPCReply(
            id: request.id,
            ok: true,
            message: selected.url.lastPathComponent,
            data: [
                "playlistID": playlistID.uuidString,
                "queueIndex": "\(selectedIndex)",
                "path": selected.url.path
            ]
        )
    }

    @MainActor
    private func handleSetPlaybackScope(_ request: IPCRequest) async -> IPCReply {
        let mode = request.arguments?["scope"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "queue"
        switch mode {
        case "queue":
            playlistManager.setPlaybackScopeQueue()
            return IPCReply(id: request.id, ok: true, message: "scope=queue")
        case "playlist":
            await playlistsStore.ensureLoaded()
            guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: true) else {
                return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
            }
            guard let playlist = playlistsStore.playlist(for: playlistID) else {
                return IPCReply(id: request.id, ok: false, message: "playlist not found")
            }
            let urls = compactPlayableURLs(from: playlist)
            guard !urls.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "playlist has no playable tracks")
            }
            playlistsStore.selectedPlaylistID = playlistID
            playlistManager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: urls)
            return IPCReply(id: request.id, ok: true, message: "scope=playlist", data: ["playlistID": playlistID.uuidString])
        default:
            return IPCReply(id: request.id, ok: false, message: "invalid scope")
        }
    }

    @MainActor
    private func handleLocateNowPlaying(_ request: IPCRequest) -> IPCReply {
        let target = request.arguments?["target"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "queue"
        switch target {
        case "queue":
            NotificationCenter.default.post(name: .switchPlaylistPanelToQueue, object: nil)
            NotificationCenter.default.post(name: .requestLocateNowPlayingInQueue, object: nil)
            return IPCReply(id: request.id, ok: true, message: "locate queue now-playing requested")
        case "playlist", "playlists":
            NotificationCenter.default.post(name: .switchPlaylistPanelToPlaylists, object: nil)
            NotificationCenter.default.post(name: .requestLocateNowPlayingInPlaylist, object: nil)
            return IPCReply(id: request.id, ok: true, message: "locate playlist now-playing requested")
        default:
            return IPCReply(id: request.id, ok: false, message: "invalid target")
        }
    }

    @MainActor
    private func handleSetWeight(_ request: IPCRequest) -> IPCReply {
        guard let scope = parseWeightScope(arguments: request.arguments) else {
            return IPCReply(id: request.id, ok: false, message: "invalid scope/playlistID")
        }
        guard let rawLevel = request.arguments?["level"], let level = parseWeightLevel(rawLevel) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid level")
        }
        guard let url = resolveTrackURL(arguments: request.arguments) else {
            return IPCReply(id: request.id, ok: false, message: "missing target track (path/index/query/current)")
        }

        PlaybackWeights.shared.setLevel(level, for: url, scope: scope)
        return IPCReply(
            id: request.id,
            ok: true,
            data: [
                "path": url.path,
                "scope": weightScopeLabel(scope),
                "level": "\(level.rawValue)",
                "multiplier": String(format: "%.3f", level.multiplier)
            ]
        )
    }

    @MainActor
    private func handleGetWeight(_ request: IPCRequest) -> IPCReply {
        guard let scope = parseWeightScope(arguments: request.arguments) else {
            return IPCReply(id: request.id, ok: false, message: "invalid scope/playlistID")
        }
        guard let url = resolveTrackURL(arguments: request.arguments) else {
            return IPCReply(id: request.id, ok: false, message: "missing target track (path/index/query/current)")
        }
        let level = PlaybackWeights.shared.level(for: url, scope: scope)
        return IPCReply(
            id: request.id,
            ok: true,
            data: [
                "path": url.path,
                "scope": weightScopeLabel(scope),
                "level": "\(level.rawValue)",
                "multiplier": String(format: "%.3f", level.multiplier)
            ]
        )
    }

    @MainActor
    private func handleClearWeights(_ request: IPCRequest) -> IPCReply {
        let scopeRaw = request.arguments?["scope"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scopeRaw == "all" || (parseBool(request.arguments?["all"]) ?? false) {
            PlaybackWeights.shared.clearAll()
            return IPCReply(id: request.id, ok: true, message: "cleared all weight overrides")
        }
        guard let scope = parseWeightScope(arguments: request.arguments) else {
            return IPCReply(id: request.id, ok: false, message: "invalid scope/playlistID")
        }
        PlaybackWeights.shared.clear(scope: scope)
        return IPCReply(id: request.id, ok: true, message: "weights cleared", data: ["scope": weightScopeLabel(scope)])
    }

    @MainActor
    private func handleSyncPlaylistWeightsToQueue(_ request: IPCRequest) async -> IPCReply {
        await playlistsStore.ensureLoaded()
        guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: true) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid playlistID")
        }
        guard playlistsStore.playlist(for: playlistID) != nil else {
            return IPCReply(id: request.id, ok: false, message: "playlist not found")
        }

        let result = PlaybackWeights.shared.syncPlaylistOverridesToQueue(from: playlistID)
        return IPCReply(
            id: request.id,
            ok: true,
            data: [
                "playlistID": playlistID.uuidString,
                "total": "\(result.total)",
                "changed": "\(result.changed)"
            ]
        )
    }

    @MainActor
    private func handleSetLyricsVisible(_ request: IPCRequest) -> IPCReply {
        guard let enabled = parseBool(request.arguments?["enabled"]) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid enabled")
        }
        audioPlayer.showLyrics = enabled
        return IPCReply(id: request.id, ok: true, data: ["showLyrics": boolString(audioPlayer.showLyrics)])
    }

    @MainActor
    private func handleToggleLyricsVisible(_ request: IPCRequest) -> IPCReply {
        audioPlayer.showLyrics.toggle()
        return IPCReply(id: request.id, ok: true, data: ["showLyrics": boolString(audioPlayer.showLyrics)])
    }

    @MainActor
    private func handleVolumePreanalysis(_ request: IPCRequest) async -> IPCReply {
        let action = request.arguments?["action"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "status"
        switch action {
        case "status":
            return IPCReply(id: request.id, ok: true, data: preanalysisData())
        case "cancel", "stop":
            audioPlayer.cancelVolumeNormalizationPreanalysis()
            return IPCReply(id: request.id, ok: true, message: "preanalysis cancelled", data: preanalysisData())
        case "start", "run":
            let urls: [URL]
            let scope = request.arguments?["scope"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "queue"
            if scope == "playlist" {
                await playlistsStore.ensureLoaded()
                guard let playlistID = resolvePlaylistID(arguments: request.arguments, allowSelected: true),
                      let playlist = playlistsStore.playlist(for: playlistID) else {
                    return IPCReply(id: request.id, ok: false, message: "playlist not found")
                }
                urls = compactPlayableURLs(from: playlist)
            } else if scope == "current" {
                guard let current = audioPlayer.currentFile?.url else {
                    return IPCReply(id: request.id, ok: false, message: "no current track")
                }
                urls = [current]
            } else {
                urls = playlistManager.audioFiles.map(\.url)
            }

            guard !urls.isEmpty else {
                return IPCReply(id: request.id, ok: false, message: "no track available for preanalysis")
            }

            audioPlayer.startVolumeNormalizationPreanalysis(urls: urls, reason: .manual)
            return IPCReply(
                id: request.id,
                ok: true,
                message: "preanalysis started",
                data: preanalysisData().merging(["requestedTracks": "\(urls.count)"]) { current, _ in current }
            )
        default:
            return IPCReply(id: request.id, ok: false, message: "invalid action")
        }
    }

    @MainActor
    private func handleSetAnalysisOptions(_ request: IPCRequest) -> IPCReply {
        if let raw = request.arguments?["analyzeDuringPlayback"] {
            guard let value = parseBool(raw) else {
                return IPCReply(id: request.id, ok: false, message: "invalid analyzeDuringPlayback")
            }
            audioPlayer.analyzeVolumesDuringPlayback = value
            audioPlayer.saveAnalyzeVolumesDuringPlaybackPreference()
        }

        if let raw = request.arguments?["autoPreanalyzeWhenIdle"] {
            guard let value = parseBool(raw) else {
                return IPCReply(id: request.id, ok: false, message: "invalid autoPreanalyzeWhenIdle")
            }
            audioPlayer.autoPreanalyzeVolumesWhenIdle = value
            audioPlayer.saveAutoPreanalyzeVolumesWhenIdlePreference()
        }

        if let raw = request.arguments?["requireAnalysisBeforePlayback"] {
            guard let value = parseBool(raw) else {
                return IPCReply(id: request.id, ok: false, message: "invalid requireAnalysisBeforePlayback")
            }
            audioPlayer.requireVolumeAnalysisBeforePlayback = value
            audioPlayer.saveRequireVolumeAnalysisBeforePlaybackPreference()
        }

        if let raw = request.arguments?["targetLevelDb"] {
            guard let value = Float(raw), value.isFinite else {
                return IPCReply(id: request.id, ok: false, message: "invalid targetLevelDb")
            }
            audioPlayer.normalizationTargetLevelDb = value
            audioPlayer.saveNormalizationTargetLevelPreference()
        }

        if let raw = request.arguments?["fadeDuration"] {
            guard let value = Double(raw), value.isFinite else {
                return IPCReply(id: request.id, ok: false, message: "invalid fadeDuration")
            }
            audioPlayer.normalizationFadeDuration = value
            audioPlayer.saveNormalizationFadeDurationPreference()
        }

        return IPCReply(id: request.id, ok: true, data: analysisOptionsData())
    }

    @MainActor
    private func handleSetScanSubfolders(_ request: IPCRequest) -> IPCReply {
        guard let enabled = parseBool(request.arguments?["enabled"]) else {
            return IPCReply(id: request.id, ok: false, message: "missing/invalid enabled")
        }
        playlistManager.scanSubfolders = enabled
        return IPCReply(id: request.id, ok: true, data: ["scanSubfolders": boolString(enabled)])
    }

    @MainActor
    private func handleRefreshMetadata(_ request: IPCRequest) async -> IPCReply {
        let mode = request.arguments?["mode"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "all"
        switch mode {
        case "all", "queue":
            await playlistManager.refreshAllMetadata(audioPlayer: audioPlayer)
            return IPCReply(id: request.id, ok: true, message: "metadata refreshed")
        case "current":
            guard let current = audioPlayer.currentFile else {
                return IPCReply(id: request.id, ok: false, message: "no current track")
            }
            await playlistManager.refreshFileMetadata(current)
            return IPCReply(id: request.id, ok: true, message: "current track metadata refreshed")
        default:
            return IPCReply(id: request.id, ok: false, message: "invalid mode")
        }
    }

    @MainActor
    private func makeQueueSnapshot(offset: Int, limit: Int) -> QueueSnapshotPayload {
        let filteredIDSet = Set(playlistManager.filteredFiles.map(\.id))
        let currentLookup = currentTrackLookupSet()
        let start = max(0, min(offset, playlistManager.audioFiles.count))
        let page = Array(playlistManager.audioFiles.dropFirst(start).prefix(limit))
        let items = page.enumerated().map { entry -> QueueSnapshotItem in
            let queueIndex = start + entry.offset
            let file = entry.element
            let lookup = Set(PathKey.lookupKeys(for: file.url))
            return QueueSnapshotItem(
                index: queueIndex,
                id: file.id,
                path: file.url.path,
                title: file.metadata.title,
                artist: file.metadata.artist,
                album: file.metadata.album,
                duration: file.duration,
                isCurrent: !currentLookup.isDisjoint(with: lookup),
                isInFiltered: filteredIDSet.contains(file.id),
                queueWeight: PlaybackWeights.shared.level(for: file.url, scope: .queue).rawValue
            )
        }
        return QueueSnapshotPayload(
            total: playlistManager.audioFiles.count,
            offset: start,
            returned: items.count,
            searchText: playlistManager.searchText,
            items: items
        )
    }

    @MainActor
    private func makePlaylistsSnapshot() async -> PlaylistSummaryPayload {
        await playlistsStore.ensureLoaded()
        let selectedID = playlistsStore.selectedPlaylistID
        let items: [PlaylistSummaryItem] = playlistsStore.playlists.map { playlist in
            PlaylistSummaryItem(
                id: playlist.id.uuidString,
                name: playlist.name,
                trackCount: playlist.tracks.count,
                isSelected: selectedID == playlist.id,
                isActivePlaybackScope: playlistManager.playbackScope == .playlist(playlist.id)
            )
        }
        return PlaylistSummaryPayload(selectedPlaylistID: selectedID?.uuidString, items: items)
    }

    @MainActor
    private func refreshPlaybackScopePlaylistTracks(_ playlistID: UserPlaylist.ID) {
        guard playlistManager.playbackScope == .playlist(playlistID) else { return }
        guard let playlist = playlistsStore.playlist(for: playlistID) else {
            playlistManager.setPlaybackScopeQueue()
            return
        }
        let urls = compactPlayableURLs(from: playlist)
        if urls.isEmpty {
            playlistManager.setPlaybackScopeQueue()
        } else {
            playlistManager.setPlaybackScopePlaylist(playlistID, trackURLsInOrder: urls)
        }
    }

    private func compactPlayableURLs(from playlist: UserPlaylist) -> [URL] {
        let fm = FileManager.default
        return playlist.tracks
            .map { URL(fileURLWithPath: $0.path) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            return nil
        }
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    @MainActor
    private func resolvePlaylistID(arguments: [String: String]?, allowSelected: Bool) -> UserPlaylist.ID? {
        if let raw = arguments?["playlistID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let id = UUID(uuidString: raw) {
            return id
        }
        if allowSelected {
            return playlistsStore.selectedPlaylistID
        }
        return nil
    }

    private func tokenizeQuery(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func matchedQueueIndices(for query: String) -> [Int] {
        let tokens = tokenizeQuery(query)
        guard !tokens.isEmpty else { return [] }
        return playlistManager.audioFiles.enumerated().compactMap { entry in
            let file = entry.element
            let fields = [
                file.metadata.title,
                file.metadata.artist,
                file.metadata.album,
                file.url.lastPathComponent,
                file.url.path
            ]
            let matched = tokens.allSatisfy { token in
                fields.contains(where: { $0.localizedCaseInsensitiveContains(token) })
            }
            return matched ? entry.offset : nil
        }
    }

    @MainActor
    private func parseWeightScope(arguments: [String: String]?) -> PlaybackWeights.Scope? {
        let scope = arguments?["scope"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "queue"
        switch scope {
        case "queue":
            return .queue
        case "playlist":
            guard let raw = arguments?["playlistID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = UUID(uuidString: raw) else {
                return nil
            }
            return .playlist(id)
        default:
            return nil
        }
    }

    private func parseWeightLevel(_ raw: String) -> PlaybackWeights.Level? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let numeric = Int(normalized) {
            return PlaybackWeights.Level(rawValue: max(0, min(4, numeric)))
        }
        switch normalized {
        case "green", "g": return .green
        case "blue", "b": return .blue
        case "purple", "p": return .purple
        case "gold", "y", "yellow": return .gold
        case "red", "r": return .red
        default: return nil
        }
    }

    @MainActor
    private func resolveTrackURL(arguments: [String: String]?) -> URL? {
        if let rawPath = arguments?["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        }

        if let rawIndex = arguments?["index"], let index = Int(rawIndex), index >= 0, index < playlistManager.audioFiles.count {
            return playlistManager.audioFiles[index].url
        }

        if let query = arguments?["query"], let index = matchedQueueIndices(for: query).first {
            return playlistManager.audioFiles[index].url
        }

        if let rawCurrent = arguments?["current"], let flag = parseBool(rawCurrent), flag == false {
            return nil
        }

        return audioPlayer.currentFile?.url
    }

    private func weightScopeLabel(_ scope: PlaybackWeights.Scope) -> String {
        switch scope {
        case .queue:
            return "queue"
        case .playlist(let id):
            return "playlist:\(id.uuidString)"
        }
    }

    @MainActor
    private func currentTrackLookupSet() -> Set<String> {
        if audioPlayer.persistPlaybackState,
           playlistManager.currentIndex >= 0,
           playlistManager.currentIndex < playlistManager.audioFiles.count {
            return Set(PathKey.lookupKeys(for: playlistManager.audioFiles[playlistManager.currentIndex].url))
        }
        guard let current = audioPlayer.currentFile?.url else { return [] }
        return Set(PathKey.lookupKeys(for: current))
    }

    private func preanalysisSnapshot() -> PreanalysisSnapshot {
        PreanalysisSnapshot(
            running: audioPlayer.isVolumePreanalysisRunning,
            total: audioPlayer.volumePreanalysisTotal,
            completed: audioPlayer.volumePreanalysisCompleted,
            currentFile: audioPlayer.volumePreanalysisCurrentFileName,
            cacheCount: audioPlayer.volumeNormalizationCacheCount
        )
    }

    private func preanalysisData() -> [String: String] {
        [
            "running": boolString(audioPlayer.isVolumePreanalysisRunning),
            "total": "\(audioPlayer.volumePreanalysisTotal)",
            "completed": "\(audioPlayer.volumePreanalysisCompleted)",
            "currentFile": audioPlayer.volumePreanalysisCurrentFileName,
            "cacheCount": "\(audioPlayer.volumeNormalizationCacheCount)"
        ]
    }

    private func analysisOptionsData() -> [String: String] {
        [
            "analyzeDuringPlayback": boolString(audioPlayer.analyzeVolumesDuringPlayback),
            "autoPreanalyzeWhenIdle": boolString(audioPlayer.autoPreanalyzeVolumesWhenIdle),
            "requireAnalysisBeforePlayback": boolString(audioPlayer.requireVolumeAnalysisBeforePlayback),
            "targetLevelDb": String(format: "%.2f", audioPlayer.normalizationTargetLevelDb),
            "fadeDuration": String(format: "%.3f", audioPlayer.normalizationFadeDuration)
        ]
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func isRequestAllowed(_ request: IPCRequest) -> Bool {
        if request.command == .ping || request.command == .status || request.command == .setIPCDebugEnabled {
            return true
        }
        return IPCDebugSettings.isEnabled()
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
        data["showLyrics"] = audioPlayer.showLyrics ? "true" : "false"
        data["scanSubfolders"] = playlistManager.scanSubfolders ? "true" : "false"
        data["ipcDebugEnabled"] = IPCDebugSettings.isEnabled() ? "true" : "false"
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
