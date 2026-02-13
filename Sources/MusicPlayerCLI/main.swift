import Foundation
import MusicPlayerIPC

private enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case noReply = 69
    case failure = 1
}

private func eprint(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

private func printUsage() {
    print(
        """
        usage:
          musicplayerctl <command> [options]

        commands:
          debug <on|off|toggle|status|snapshot> [options]
          queue <ls|clear|search|locate|scan-subfolders|refresh> [options]
          playlist <ls|tracks|create|rename|delete|select|add|remove|play|scope|locate> [options]
          weight <get|set|clear|sync> [options]
          lyrics <show|hide|toggle|status>
          analysis <status|start|cancel|options> [options]
          cache clear <lyrics|artwork|all>
          ipc <commands|raw> [options]
          ping
          status [--json] [--timeout <seconds>]
          bench <folder> [--limit <n> | --all] [--timeout <seconds>]
          toggle
          pause
          resume
          next
          prev
          random
          play [--index <n>] <query...>
          seek <mm:ss | hh:mm:ss | seconds>
          volume <0..1 | 0..100[%]>
          rate <0.5..2.0 | 50..200[%]>
          normalization <on|off|toggle>
          shuffle
          loop
          sort [set|toggle|reset] [--target <queue|playlists|addFromQueue|volumeAnalysis>] [--field <original|weight|title|artist|duration|format>] [--direction <asc|desc>]
          add <path> [path...]
          remove [--index <n> | [--all] <query...>]
          screenshot [--out <path>] [--timeout <seconds>]

        notes:
          - This CLI talks to the running MusicPlayer via DistributedNotificationCenter.
          - If you see "no reply", make sure MusicPlayer is running.
        """
    )
}

private func defaultScreenshotPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let name = "MusicPlayer_\(formatter.string(from: Date())).png"
    return desktop.appendingPathComponent(name, isDirectory: false).path
}

private func sendRequest(_ request: IPCRequest, timeoutSeconds: TimeInterval) -> IPCReply? {
    let center = DistributedNotificationCenter.default()

    var reply: IPCReply?
    let observer = center.addObserver(forName: MusicPlayerIPC.replyNotification, object: nil, queue: OperationQueue.main) { notification in
        guard
            let userInfo = notification.userInfo,
            let data = userInfo[MusicPlayerIPC.payloadKey] as? Data,
            let decoded = try? MusicPlayerIPC.decodePayload(IPCReply.self, from: data),
            decoded.id == request.id
        else { return }
        reply = decoded
    }

    defer { center.removeObserver(observer) }

    do {
        let data = try MusicPlayerIPC.encodePayload(request)
        center.postNotificationName(
            MusicPlayerIPC.requestNotification,
            object: nil,
            userInfo: [MusicPlayerIPC.payloadKey: data],
            deliverImmediately: true
        )
    } catch {
        eprint("failed to encode request: \(error)")
        return IPCReply(id: request.id, ok: false, message: "encode request failed")
    }

    let deadline = Date().addingTimeInterval(max(0.05, timeoutSeconds))
    while Date() < deadline {
        if let reply { return reply }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return nil
}

private func makeRequest(command: IPCCommand, arguments: [String: String]? = nil, paths: [String]? = nil) -> IPCRequest {
    IPCRequest(id: UUID().uuidString, command: command, arguments: arguments, paths: paths)
}

private func parseTimeout(_ value: String) -> TimeInterval? {
    guard let t = Double(value), t.isFinite, t > 0 else { return nil }
    return t
}

private func parseVolumeValue(_ raw: String) -> Float? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let percentStr: String
    let isPercent = trimmed.hasSuffix("%")
    if isPercent {
        percentStr = String(trimmed.dropLast())
    } else {
        percentStr = trimmed
    }

    guard let value = Double(percentStr), value.isFinite else { return nil }
    let normalized: Double
    if isPercent {
        normalized = value / 100.0
    } else if value > 1.0 {
        normalized = value / 100.0
    } else {
        normalized = value
    }
    return Float(max(0, min(1, normalized)))
}

private func parseRateValue(_ raw: String) -> Float? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let percentStr: String
    let isPercent = trimmed.hasSuffix("%")
    if isPercent {
        percentStr = String(trimmed.dropLast())
    } else {
        percentStr = trimmed
    }

    guard let value = Double(percentStr), value.isFinite else { return nil }
    let normalized: Double
    if isPercent {
        normalized = value / 100.0
    } else if value > 2.0 {
        normalized = value / 100.0
    } else {
        normalized = value
    }
    guard normalized >= 0.5, normalized <= 2.0 else { return nil }
    return Float(normalized)
}

private func parseTimeValueSeconds(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(":") {
        let parts = trimmed.split(separator: ":").map { String($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        func parse(_ s: String) -> Double? {
            guard let v = Double(s), v.isFinite else { return nil }
            return v
        }

        if parts.count == 2 {
            guard let m = parse(parts[0]), let s = parse(parts[1]) else { return nil }
            return max(0, m * 60.0 + s)
        } else {
            guard let h = parse(parts[0]), let m = parse(parts[1]), let s = parse(parts[2]) else { return nil }
            return max(0, h * 3600.0 + m * 60.0 + s)
        }
    }

    guard let v = Double(trimmed), v.isFinite else { return nil }
    return max(0, v)
}

private func parseBoolWord(_ raw: String) -> Bool? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled":
        return true
    case "0", "false", "no", "off", "disabled":
        return false
    default:
        return nil
    }
}

private func printReplyAsJSON(_ reply: IPCReply) {
    if let raw = reply.data?["json"], !raw.isEmpty {
        print(raw)
        return
    }

    let payload: [String: Any] = [
        "ok": reply.ok,
        "message": reply.message as Any,
        "data": reply.data as Any
    ]

    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print(payload)
    }
}

private func printReplyAsPlain(_ reply: IPCReply) {
    if let msg = reply.message, !msg.isEmpty {
        print(msg)
    }

    guard let data = reply.data, !data.isEmpty else { return }

    let sortedKeys = data.keys.filter { $0 != "json" }.sorted()
    if sortedKeys.isEmpty {
        if let raw = data["json"], !raw.isEmpty {
            print(raw)
        }
        return
    }

    for key in sortedKeys {
        print("\(key): \(data[key] ?? "")")
    }
}

private func finalizeReply(_ reply: IPCReply, json: Bool = false, silentOnSuccess: Bool = false) -> ExitCode {
    if reply.ok {
        if !silentOnSuccess {
            if json {
                printReplyAsJSON(reply)
            } else {
                printReplyAsPlain(reply)
            }
        }
        return .ok
    }

    if json {
        printReplyAsJSON(reply)
    } else {
        eprint(reply.message ?? "failed")
    }
    return .failure
}

private func sendAndFinalize(
    command: IPCCommand,
    arguments: [String: String]? = nil,
    paths: [String]? = nil,
    timeout: TimeInterval = 1.5,
    json: Bool = false,
    silentOnSuccess: Bool = false
) -> ExitCode {
    let request = makeRequest(command: command, arguments: arguments, paths: paths)
    guard let reply = sendRequest(request, timeoutSeconds: timeout) else {
        eprint("no reply")
        return .noReply
    }
    return finalizeReply(reply, json: json, silentOnSuccess: silentOnSuccess)
}

private func parseKeyValue(_ raw: String) -> (String, String)? {
    guard let index = raw.firstIndex(of: "=") else { return nil }
    let key = String(raw[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    let value = String(raw[raw.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    return (key, value)
}

private let allIPCCommandNames: [String] = [
    "ping", "status", "benchmarkLoad", "clearLyricsCache", "clearArtworkCache",
    "setIPCDebugEnabled", "debugSnapshot", "queueSnapshot", "clearQueue", "searchQueue",
    "setSearchSortOption", "resetSearchSortOption", "toggleSearchSortOption",
    "playlistsSnapshot", "playlistTracksSnapshot", "createPlaylist", "renamePlaylist", "deletePlaylist",
    "selectPlaylist", "addTracksToPlaylist", "removeTracksFromPlaylist", "playPlaylistTrack",
    "setPlaybackScope", "locateNowPlaying", "setWeight", "getWeight", "clearWeights",
    "syncPlaylistWeightsToQueue", "setLyricsVisible", "toggleLyricsVisible", "volumePreanalysis",
    "setAnalysisOptions", "setScanSubfolders", "refreshMetadata",
    "togglePlayPause", "pause", "resume", "next", "previous", "random",
    "playIndex", "playQuery", "seek", "setVolume", "setRate", "toggleNormalization",
    "setNormalizationEnabled", "toggleShuffle", "toggleLoop", "add", "remove", "screenshot"
]

private func handleDebugCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("debug: missing subcommand")
        return .usage
    }

    switch sub {
    case "on":
        return sendAndFinalize(command: .setIPCDebugEnabled, arguments: ["enabled": "true"])
    case "off":
        return sendAndFinalize(command: .setIPCDebugEnabled, arguments: ["enabled": "false"])
    case "toggle":
        return sendAndFinalize(command: .setIPCDebugEnabled, arguments: ["enabled": "toggle"])
    case "status":
        var json = false
        var timeoutSeconds: TimeInterval = 1.5
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("debug status: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("debug status: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("debug status: unknown option \(a)")
                return .usage
            }
        }

        let req = makeRequest(command: .status)
        guard let reply = sendRequest(req, timeoutSeconds: timeoutSeconds) else {
            eprint("no reply")
            return .noReply
        }
        if json {
            return finalizeReply(reply, json: true)
        }
        if !reply.ok {
            eprint(reply.message ?? "failed")
            return .failure
        }
        print("enabled: \(reply.data?["ipcDebugEnabled"] ?? "unknown")")
        return .ok

    case "snapshot":
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var queueLimit = "40"

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--queue-limit":
                guard i + 1 < args.count else { eprint("debug snapshot: --queue-limit needs a value"); return .usage }
                queueLimit = args[i + 1]
                i += 2
            case "--timeout":
                guard i + 1 < args.count else { eprint("debug snapshot: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("debug snapshot: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("debug snapshot: unknown option \(a)")
                return .usage
            }
        }

        return sendAndFinalize(command: .debugSnapshot, arguments: ["queueLimit": queueLimit], timeout: timeoutSeconds, json: json)
    default:
        eprint("debug: unknown subcommand \(sub)")
        return .usage
    }
}

private func handleQueueCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("queue: missing subcommand")
        return .usage
    }

    switch sub {
    case "ls", "list":
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var limit = "200"
        var offset = "0"

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--limit":
                guard i + 1 < args.count else { eprint("queue ls: --limit needs a value"); return .usage }
                limit = args[i + 1]
                i += 2
            case "--offset":
                guard i + 1 < args.count else { eprint("queue ls: --offset needs a value"); return .usage }
                offset = args[i + 1]
                i += 2
            case "--timeout":
                guard i + 1 < args.count else { eprint("queue ls: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("queue ls: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("queue ls: unknown option \(a)")
                return .usage
            }
        }

        return sendAndFinalize(
            command: .queueSnapshot,
            arguments: ["limit": limit, "offset": offset],
            timeout: timeoutSeconds,
            json: json
        )
    case "clear":
        return sendAndFinalize(command: .clearQueue)
    case "search":
        let query = Array(args.dropFirst()).joined(separator: " ")
        return sendAndFinalize(command: .searchQueue, arguments: ["query": query])
    case "locate":
        return sendAndFinalize(command: .locateNowPlaying, arguments: ["target": "queue"])
    case "scan-subfolders":
        guard args.count >= 2 else { eprint("queue scan-subfolders: missing on/off"); return .usage }
        guard let enabled = parseBoolWord(args[1]) else { eprint("queue scan-subfolders: invalid value"); return .usage }
        return sendAndFinalize(command: .setScanSubfolders, arguments: ["enabled": enabled ? "true" : "false"])
    case "refresh":
        let mode = (args.count >= 2) ? args[1] : "all"
        return sendAndFinalize(command: .refreshMetadata, arguments: ["mode": mode], timeout: 30.0)
    default:
        eprint("queue: unknown subcommand \(sub)")
        return .usage
    }
}

private func handlePlaylistCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("playlist: missing subcommand")
        return .usage
    }

    switch sub {
    case "ls", "list":
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("playlist ls: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("playlist ls: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("playlist ls: unknown option \(a)")
                return .usage
            }
        }
        return sendAndFinalize(command: .playlistsSnapshot, timeout: timeoutSeconds, json: json)

    case "tracks":
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var limit = "200"
        var offset = "0"
        var playlistID: String?

        var i = 1
        if i < args.count, !args[i].hasPrefix("--") {
            if args[i].lowercased() != "selected" {
                playlistID = args[i]
            }
            i += 1
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--limit":
                guard i + 1 < args.count else { eprint("playlist tracks: --limit needs a value"); return .usage }
                limit = args[i + 1]
                i += 2
            case "--offset":
                guard i + 1 < args.count else { eprint("playlist tracks: --offset needs a value"); return .usage }
                offset = args[i + 1]
                i += 2
            case "--timeout":
                guard i + 1 < args.count else { eprint("playlist tracks: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("playlist tracks: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("playlist tracks: unknown option \(a)")
                return .usage
            }
        }

        var reqArgs: [String: String] = ["limit": limit, "offset": offset]
        if let playlistID { reqArgs["playlistID"] = playlistID }
        return sendAndFinalize(command: .playlistTracksSnapshot, arguments: reqArgs, timeout: timeoutSeconds, json: json)

    case "create":
        let name = Array(args.dropFirst()).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { eprint("playlist create: missing name"); return .usage }
        return sendAndFinalize(command: .createPlaylist, arguments: ["name": name])

    case "rename":
        guard args.count >= 3 else { eprint("playlist rename: usage playlist rename <playlistID> <name>"); return .usage }
        let playlistID = args[1]
        let name = Array(args.dropFirst(2)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { eprint("playlist rename: missing name"); return .usage }
        return sendAndFinalize(command: .renamePlaylist, arguments: ["playlistID": playlistID, "name": name])

    case "delete":
        guard args.count >= 2 else { eprint("playlist delete: missing playlistID"); return .usage }
        return sendAndFinalize(command: .deletePlaylist, arguments: ["playlistID": args[1]])

    case "select":
        guard args.count >= 2 else { eprint("playlist select: missing playlistID"); return .usage }
        return sendAndFinalize(command: .selectPlaylist, arguments: ["playlistID": args[1]])

    case "add":
        guard args.count >= 3 else { eprint("playlist add: usage playlist add <playlistID> <path...>"); return .usage }
        let playlistID = args[1]
        let paths = Array(args.dropFirst(2))
        return sendAndFinalize(command: .addTracksToPlaylist, arguments: ["playlistID": playlistID], paths: paths, timeout: 3.0)

    case "remove":
        guard args.count >= 3 else {
            eprint("playlist remove: usage playlist remove <playlistID> [--index n | --path path | [--all] query]")
            return .usage
        }

        let playlistID = args[1]
        var reqArgs: [String: String] = ["playlistID": playlistID]
        var queryParts: [String] = []
        var i = 2
        while i < args.count {
            let a = args[i]
            switch a {
            case "--index":
                guard i + 1 < args.count else { eprint("playlist remove: --index needs a value"); return .usage }
                reqArgs["index"] = args[i + 1]
                i += 2
            case "--path":
                guard i + 1 < args.count else { eprint("playlist remove: --path needs a value"); return .usage }
                reqArgs["path"] = args[i + 1]
                i += 2
            case "--all":
                reqArgs["mode"] = "all"
                i += 1
            default:
                queryParts.append(a)
                i += 1
            }
        }

        if reqArgs["index"] == nil, reqArgs["path"] == nil {
            let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                eprint("playlist remove: missing index/path/query")
                return .usage
            }
            reqArgs["query"] = query
        }

        return sendAndFinalize(command: .removeTracksFromPlaylist, arguments: reqArgs, timeout: 3.0)

    case "play":
        guard args.count >= 2 else {
            eprint("playlist play: usage playlist play <playlistID> [--index n | query]")
            return .usage
        }

        let playlistID = args[1]
        var reqArgs: [String: String] = ["playlistID": playlistID]
        var queryParts: [String] = []
        var i = 2
        while i < args.count {
            let a = args[i]
            switch a {
            case "--index":
                guard i + 1 < args.count else { eprint("playlist play: --index needs a value"); return .usage }
                reqArgs["index"] = args[i + 1]
                i += 2
            default:
                queryParts.append(a)
                i += 1
            }
        }
        if reqArgs["index"] == nil {
            let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                reqArgs["query"] = query
            }
        }
        return sendAndFinalize(command: .playPlaylistTrack, arguments: reqArgs, timeout: 3.0)

    case "scope":
        guard args.count >= 2 else { eprint("playlist scope: missing playlistID"); return .usage }
        return sendAndFinalize(command: .setPlaybackScope, arguments: ["scope": "playlist", "playlistID": args[1]])

    case "locate":
        return sendAndFinalize(command: .locateNowPlaying, arguments: ["target": "playlist"])

    default:
        eprint("playlist: unknown subcommand \(sub)")
        return .usage
    }
}

private func handleWeightCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("weight: missing subcommand")
        return .usage
    }

    var reqArgs: [String: String] = [:]
    var json = false
    var timeoutSeconds: TimeInterval = 2.0

    func parseOptions(startIndex: Int, allowLevel: Bool) -> Bool {
        var i = startIndex
        while i < args.count {
            let a = args[i]
            switch a {
            case "--scope":
                guard i + 1 < args.count else { eprint("weight: --scope needs a value"); return false }
                reqArgs["scope"] = args[i + 1]
                i += 2
            case "--playlist":
                guard i + 1 < args.count else { eprint("weight: --playlist needs a value"); return false }
                reqArgs["playlistID"] = args[i + 1]
                i += 2
            case "--path":
                guard i + 1 < args.count else { eprint("weight: --path needs a value"); return false }
                reqArgs["path"] = args[i + 1]
                i += 2
            case "--index":
                guard i + 1 < args.count else { eprint("weight: --index needs a value"); return false }
                reqArgs["index"] = args[i + 1]
                i += 2
            case "--query":
                guard i + 1 < args.count else { eprint("weight: --query needs a value"); return false }
                reqArgs["query"] = args[i + 1]
                i += 2
            case "--current":
                reqArgs["current"] = "true"
                i += 1
            case "--level":
                guard allowLevel else { eprint("weight: --level not allowed here"); return false }
                guard i + 1 < args.count else { eprint("weight: --level needs a value"); return false }
                reqArgs["level"] = args[i + 1]
                i += 2
            case "--all":
                reqArgs["all"] = "true"
                i += 1
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("weight: --timeout needs a value"); return false }
                guard let t = parseTimeout(args[i + 1]) else { eprint("weight: invalid timeout"); return false }
                timeoutSeconds = t
                i += 2
            default:
                eprint("weight: unknown option \(a)")
                return false
            }
        }
        return true
    }

    switch sub {
    case "set":
        guard parseOptions(startIndex: 1, allowLevel: true) else { return .usage }
        guard reqArgs["level"] != nil else {
            eprint("weight set: missing --level")
            return .usage
        }
        if reqArgs["scope"]?.lowercased() == "playlist", reqArgs["playlistID"] == nil {
            eprint("weight set: --scope playlist requires --playlist <id>")
            return .usage
        }
        if reqArgs["path"] == nil, reqArgs["index"] == nil, reqArgs["query"] == nil, reqArgs["current"] == nil {
            reqArgs["current"] = "true"
        }
        return sendAndFinalize(command: .setWeight, arguments: reqArgs, timeout: timeoutSeconds, json: json)

    case "get":
        guard parseOptions(startIndex: 1, allowLevel: false) else { return .usage }
        if reqArgs["scope"]?.lowercased() == "playlist", reqArgs["playlistID"] == nil {
            eprint("weight get: --scope playlist requires --playlist <id>")
            return .usage
        }
        if reqArgs["path"] == nil, reqArgs["index"] == nil, reqArgs["query"] == nil, reqArgs["current"] == nil {
            reqArgs["current"] = "true"
        }
        return sendAndFinalize(command: .getWeight, arguments: reqArgs, timeout: timeoutSeconds, json: json)

    case "clear":
        guard parseOptions(startIndex: 1, allowLevel: false) else { return .usage }
        if reqArgs["scope"]?.lowercased() == "playlist", reqArgs["playlistID"] == nil {
            eprint("weight clear: --scope playlist requires --playlist <id>")
            return .usage
        }
        return sendAndFinalize(command: .clearWeights, arguments: reqArgs, timeout: timeoutSeconds, json: json)

    case "sync":
        var i = 1
        var playlistID: String? = nil
        while i < args.count {
            let a = args[i]
            switch a {
            case "--playlist":
                guard i + 1 < args.count else { eprint("weight sync: --playlist needs a value"); return .usage }
                playlistID = args[i + 1]
                i += 2
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("weight sync: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("weight sync: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                if !a.hasPrefix("--") && playlistID == nil {
                    playlistID = a
                    i += 1
                } else {
                    eprint("weight sync: unknown option \(a)")
                    return .usage
                }
            }
        }
        guard let playlistID, !playlistID.isEmpty else {
            eprint("weight sync: missing playlistID")
            return .usage
        }
        return sendAndFinalize(command: .syncPlaylistWeightsToQueue, arguments: ["playlistID": playlistID], timeout: timeoutSeconds, json: json)

    default:
        eprint("weight: unknown subcommand \(sub)")
        return .usage
    }
}

private func handleLyricsCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("lyrics: missing subcommand")
        return .usage
    }

    switch sub {
    case "show":
        return sendAndFinalize(command: .setLyricsVisible, arguments: ["enabled": "true"])
    case "hide":
        return sendAndFinalize(command: .setLyricsVisible, arguments: ["enabled": "false"])
    case "toggle":
        return sendAndFinalize(command: .toggleLyricsVisible)
    case "status":
        return sendAndFinalize(command: .status)
    default:
        eprint("lyrics: unknown subcommand \(sub)")
        return .usage
    }
}

private func handleAnalysisCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("analysis: missing subcommand")
        return .usage
    }

    switch sub {
    case "status":
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("analysis status: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("analysis status: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("analysis status: unknown option \(a)")
                return .usage
            }
        }
        return sendAndFinalize(command: .volumePreanalysis, arguments: ["action": "status"], timeout: timeoutSeconds, json: json)

    case "start":
        var reqArgs: [String: String] = ["action": "start"]
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--scope":
                guard i + 1 < args.count else { eprint("analysis start: --scope needs a value"); return .usage }
                reqArgs["scope"] = args[i + 1]
                i += 2
            case "--playlist":
                guard i + 1 < args.count else { eprint("analysis start: --playlist needs a value"); return .usage }
                reqArgs["playlistID"] = args[i + 1]
                i += 2
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("analysis start: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("analysis start: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("analysis start: unknown option \(a)")
                return .usage
            }
        }
        if reqArgs["scope"]?.lowercased() == "playlist", reqArgs["playlistID"] == nil {
            eprint("analysis start: --scope playlist requires --playlist <id>")
            return .usage
        }
        return sendAndFinalize(command: .volumePreanalysis, arguments: reqArgs, timeout: timeoutSeconds, json: json)

    case "cancel", "stop":
        return sendAndFinalize(command: .volumePreanalysis, arguments: ["action": "cancel"])

    case "options":
        var reqArgs: [String: String] = [:]
        var json = false
        var timeoutSeconds: TimeInterval = 2.0
        var i = 1

        while i < args.count {
            let a = args[i]
            switch a {
            case "--analyze-during-playback":
                guard i + 1 < args.count else { eprint("analysis options: --analyze-during-playback needs a value"); return .usage }
                guard let value = parseBoolWord(args[i + 1]) else { eprint("analysis options: invalid analyze-during-playback"); return .usage }
                reqArgs["analyzeDuringPlayback"] = value ? "true" : "false"
                i += 2
            case "--auto-preanalyze-when-idle":
                guard i + 1 < args.count else { eprint("analysis options: --auto-preanalyze-when-idle needs a value"); return .usage }
                guard let value = parseBoolWord(args[i + 1]) else { eprint("analysis options: invalid auto-preanalyze-when-idle"); return .usage }
                reqArgs["autoPreanalyzeWhenIdle"] = value ? "true" : "false"
                i += 2
            case "--require-before-playback":
                guard i + 1 < args.count else { eprint("analysis options: --require-before-playback needs a value"); return .usage }
                guard let value = parseBoolWord(args[i + 1]) else { eprint("analysis options: invalid require-before-playback"); return .usage }
                reqArgs["requireAnalysisBeforePlayback"] = value ? "true" : "false"
                i += 2
            case "--target-level-db":
                guard i + 1 < args.count else { eprint("analysis options: --target-level-db needs a value"); return .usage }
                reqArgs["targetLevelDb"] = args[i + 1]
                i += 2
            case "--fade-duration":
                guard i + 1 < args.count else { eprint("analysis options: --fade-duration needs a value"); return .usage }
                reqArgs["fadeDuration"] = args[i + 1]
                i += 2
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("analysis options: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("analysis options: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("analysis options: unknown option \(a)")
                return .usage
            }
        }

        return sendAndFinalize(command: .setAnalysisOptions, arguments: reqArgs, timeout: timeoutSeconds, json: json)

    default:
        eprint("analysis: unknown subcommand \(sub)")
        return .usage
    }
}

private func handleCacheCommand(_ args: [String]) -> ExitCode {
    guard args.count >= 2 else {
        eprint("cache: usage cache clear <lyrics|artwork|all>")
        return .usage
    }

    let sub = args[0].lowercased()
    guard sub == "clear" else {
        eprint("cache: unknown subcommand \(sub)")
        return .usage
    }

    let target = args[1].lowercased()
    switch target {
    case "lyrics":
        return sendAndFinalize(command: .clearLyricsCache)
    case "artwork":
        return sendAndFinalize(command: .clearArtworkCache)
    case "all":
        let first = sendAndFinalize(command: .clearLyricsCache, silentOnSuccess: true)
        if first != .ok { return first }
        return sendAndFinalize(command: .clearArtworkCache)
    default:
        eprint("cache clear: invalid target \(target)")
        return .usage
    }
}

private func handleIPCCommand(_ args: [String]) -> ExitCode {
    guard let sub = args.first?.lowercased() else {
        eprint("ipc: missing subcommand")
        return .usage
    }

    switch sub {
    case "commands":
        for name in allIPCCommandNames.sorted() {
            print(name)
        }
        return .ok

    case "raw":
        guard args.count >= 2 else {
            eprint("ipc raw: missing command")
            return .usage
        }

        let rawCommand = args[1]
        guard let command = IPCCommand(rawValue: rawCommand) else {
            eprint("ipc raw: unknown IPC command \(rawCommand)")
            return .usage
        }

        var reqArgs: [String: String] = [:]
        var reqPaths: [String] = []
        var json = false
        var timeoutSeconds: TimeInterval = 2.0

        var i = 2
        while i < args.count {
            let a = args[i]
            switch a {
            case "--arg":
                guard i + 1 < args.count else { eprint("ipc raw: --arg needs key=value"); return .usage }
                guard let (key, value) = parseKeyValue(args[i + 1]) else { eprint("ipc raw: invalid --arg format (expected key=value)"); return .usage }
                reqArgs[key] = value
                i += 2
            case "--path":
                guard i + 1 < args.count else { eprint("ipc raw: --path needs a value"); return .usage }
                reqPaths.append(args[i + 1])
                i += 2
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("ipc raw: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("ipc raw: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("ipc raw: unknown option \(a)")
                return .usage
            }
        }

        let request = makeRequest(command: command, arguments: reqArgs.isEmpty ? nil : reqArgs, paths: reqPaths.isEmpty ? nil : reqPaths)
        guard let reply = sendRequest(request, timeoutSeconds: timeoutSeconds) else {
            eprint("no reply")
            return .noReply
        }
        return finalizeReply(reply, json: json)

    default:
        eprint("ipc: unknown subcommand \(sub)")
        return .usage
    }
}

private func run() -> ExitCode {
    var args = CommandLine.arguments
    _ = args.removeFirst()

    guard let command = args.first else {
        printUsage()
        return .usage
    }
    _ = args.removeFirst()

    switch command {
    case "help", "-h", "--help":
        printUsage()
        return .ok
    case "debug":
        return handleDebugCommand(args)
    case "queue":
        return handleQueueCommand(args)
    case "playlist":
        return handlePlaylistCommand(args)
    case "weight":
        return handleWeightCommand(args)
    case "lyrics":
        return handleLyricsCommand(args)
    case "analysis":
        return handleAnalysisCommand(args)
    case "cache":
        return handleCacheCommand(args)
    case "ipc":
        return handleIPCCommand(args)
    case "ping":
        let req = makeRequest(command: .ping)
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            print(reply.message ?? "pong")
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "toggle":
        let req = makeRequest(command: .togglePlayPause)
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "pause":
        let req = makeRequest(command: .pause)
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "resume":
        let req = makeRequest(command: .resume)
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "next":
        let req = makeRequest(command: .next)
        let reply = sendRequest(req, timeoutSeconds: 2.0)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "prev":
        let req = makeRequest(command: .previous)
        let reply = sendRequest(req, timeoutSeconds: 2.0)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "random":
        let req = makeRequest(command: .random)
        let reply = sendRequest(req, timeoutSeconds: 2.0)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "play":
        var index: Int? = nil
        var query: String? = nil

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--index":
                guard i + 1 < args.count else { eprint("play: --index needs a value"); return .usage }
                guard let n = Int(args[i + 1]), n >= 0 else { eprint("play: invalid index"); return .usage }
                index = n
                i += 2
            default:
                query = args[i...].joined(separator: " ")
                i = args.count
            }
        }

        if let index {
            let req = makeRequest(command: .playIndex, arguments: ["index": "\(index)"])
            let reply = sendRequest(req, timeoutSeconds: 2.0)
            guard let reply else { eprint("no reply"); return .noReply }
            if !reply.ok { eprint(reply.message ?? "failed") }
            if reply.ok, let msg = reply.message, !msg.isEmpty { print(msg) }
            return reply.ok ? .ok : .failure
        }

        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            eprint("play: missing query or --index")
            return .usage
        }
        let req = makeRequest(command: .playQuery, arguments: ["query": query])
        let reply = sendRequest(req, timeoutSeconds: 2.0)
        guard let reply else { eprint("no reply"); return .noReply }
        if !reply.ok { eprint(reply.message ?? "failed") }
        if reply.ok, let msg = reply.message, !msg.isEmpty { print(msg) }
        return reply.ok ? .ok : .failure
    case "volume":
        guard let raw = args.first else { eprint("volume: missing value"); return .usage }
        guard let v = parseVolumeValue(raw) else { eprint("volume: invalid value"); return .usage }
        let req = makeRequest(command: .setVolume, arguments: ["value": "\(v)"])
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        if !reply.ok { eprint(reply.message ?? "failed") }
        return reply.ok ? .ok : .failure
    case "rate":
        guard let raw = args.first else { eprint("rate: missing value"); return .usage }
        guard let v = parseRateValue(raw) else { eprint("rate: invalid value"); return .usage }
        let req = makeRequest(command: .setRate, arguments: ["value": "\(v)"])
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            if let actual = reply.data?["rate"] {
                print(actual)
            }
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "normalization":
        guard let mode = args.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !mode.isEmpty else {
            eprint("normalization: missing mode (on|off|toggle)")
            return .usage
        }
        switch mode {
        case "toggle":
            let req = makeRequest(command: .toggleNormalization)
            let reply = sendRequest(req, timeoutSeconds: 1.5)
            guard let reply else { eprint("no reply"); return .noReply }
            if !reply.ok { eprint(reply.message ?? "failed") }
            return reply.ok ? .ok : .failure
        case "on", "off":
            let enabled = (mode == "on")
            let req = makeRequest(command: .setNormalizationEnabled, arguments: ["enabled": enabled ? "true" : "false"])
            let reply = sendRequest(req, timeoutSeconds: 1.5)
            guard let reply else { eprint("no reply"); return .noReply }
            if !reply.ok { eprint(reply.message ?? "failed") }
            return reply.ok ? .ok : .failure
        default:
            eprint("normalization: invalid mode (on|off|toggle)")
            return .usage
        }
    case "seek":
        guard let raw = args.first else { eprint("seek: missing time"); return .usage }
        guard let seconds = parseTimeValueSeconds(raw) else { eprint("seek: invalid time"); return .usage }
        let req = makeRequest(command: .seek, arguments: ["time": "\(seconds)"])
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            if let actual = reply.data?["time"] {
                print(actual)
            }
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "shuffle":
        let req = makeRequest(command: .toggleShuffle)
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "loop":
        let req = makeRequest(command: .toggleLoop)
        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        return reply.ok ? .ok : .failure
    case "sort":
        var mode = "set"
        var i = 0

        if i < args.count, !args[i].hasPrefix("--") {
            let s = args[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == "toggle" || s == "reset" || s == "set" {
                mode = s
                i += 1
            }
        }

        var target = "queue"
        var field: String? = nil
        var direction: String? = nil

        while i < args.count {
            let a = args[i]
            switch a {
            case "--target":
                guard i + 1 < args.count else { eprint("sort: --target needs a value"); return .usage }
                target = args[i + 1]
                i += 2
            case "--field":
                guard i + 1 < args.count else { eprint("sort: --field needs a value"); return .usage }
                field = args[i + 1]
                i += 2
            case "--direction":
                guard i + 1 < args.count else { eprint("sort: --direction needs a value"); return .usage }
                direction = args[i + 1]
                i += 2
            default:
                if mode == "set", field == nil, !a.hasPrefix("--") {
                    field = a
                    i += 1
                } else {
                    eprint("sort: unknown option \(a)")
                    return .usage
                }
            }
        }

        let targetTrimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetTrimmed.isEmpty else { eprint("sort: invalid --target"); return .usage }

        let req: IPCRequest
        switch mode {
        case "toggle":
            req = makeRequest(command: .toggleSearchSortOption, arguments: ["target": targetTrimmed])
        case "reset":
            req = makeRequest(command: .resetSearchSortOption, arguments: ["target": targetTrimmed])
        default:
            guard let field else { eprint("sort: missing --field"); return .usage }
            var args: [String: String] = ["target": targetTrimmed, "field": field]
            if let direction { args["direction"] = direction }
            req = makeRequest(command: .setSearchSortOption, arguments: args)
        }

        let reply = sendRequest(req, timeoutSeconds: 1.5)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            if let msg = reply.message, !msg.isEmpty { print(msg) }
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "add":
        guard !args.isEmpty else {
            eprint("add: missing path(s)")
            return .usage
        }
        let req = makeRequest(command: .add, paths: args)
        let reply = sendRequest(req, timeoutSeconds: 3.0)
        guard let reply else { eprint("no reply"); return .noReply }
        if !reply.ok { eprint(reply.message ?? "failed") }
        return reply.ok ? .ok : .failure
    case "remove":
        var removeAll = false
        var index: Int? = nil
        var queryParts: [String] = []

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--all":
                removeAll = true
                i += 1
            case "--index":
                guard i + 1 < args.count else { eprint("remove: --index needs a value"); return .usage }
                guard let n = Int(args[i + 1]), n >= 0 else { eprint("remove: invalid index"); return .usage }
                index = n
                i += 2
            default:
                queryParts.append(a)
                i += 1
            }
        }

        if let index {
            let req = makeRequest(command: .remove, arguments: ["index": "\(index)"])
            let reply = sendRequest(req, timeoutSeconds: 2.5)
            guard let reply else { eprint("no reply"); return .noReply }
            if reply.ok {
                if let msg = reply.message, !msg.isEmpty { print(msg) }
                return .ok
            }
            eprint(reply.message ?? "failed")
            return .failure
        }

        let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { eprint("remove: missing query or --index"); return .usage }
        let args: [String: String] = removeAll
            ? ["query": query, "mode": "all"]
            : ["query": query]
        let req = makeRequest(command: .remove, arguments: args)
        let reply = sendRequest(req, timeoutSeconds: 3.0)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            if let msg = reply.message, !msg.isEmpty { print(msg) }
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "bench":
        var folderPath: String? = nil
        var limit: Int = 50
        var timeoutSeconds: TimeInterval = 180.0

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--limit":
                guard i + 1 < args.count else { eprint("bench: --limit needs a value"); return .usage }
                guard let n = Int(args[i + 1]), n >= 0 else { eprint("bench: invalid limit"); return .usage }
                limit = n
                i += 2
            case "--all":
                limit = 0
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("bench: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("bench: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                if folderPath == nil {
                    folderPath = a
                    i += 1
                } else {
                    eprint("bench: unexpected argument \(a)")
                    return .usage
                }
            }
        }

        guard let folderPath else {
            eprint("bench: missing folder")
            return .usage
        }

        let req = makeRequest(command: .benchmarkLoad, arguments: ["path": folderPath, "limit": "\(limit)"])
        let reply = sendRequest(req, timeoutSeconds: timeoutSeconds)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            if let msg = reply.message, !msg.isEmpty { print(msg) }
            if let report = reply.data?["reportPath"] { print(report) }
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "screenshot":
        var outPath: String? = nil
        var timeoutSeconds: TimeInterval = 3.0

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--out":
                guard i + 1 < args.count else { eprint("screenshot: --out needs a value"); return .usage }
                outPath = args[i + 1]
                i += 2
            case "--timeout":
                guard i + 1 < args.count else { eprint("screenshot: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("screenshot: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("screenshot: unknown option \(a)")
                return .usage
            }
        }

        let resolvedOut = (outPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? outPath! : defaultScreenshotPath()
        let req = makeRequest(command: .screenshot, arguments: ["outPath": resolvedOut])
        let reply = sendRequest(req, timeoutSeconds: timeoutSeconds)
        guard let reply else { eprint("no reply"); return .noReply }
        if reply.ok {
            print(reply.data?["outPath"] ?? resolvedOut)
            return .ok
        }
        eprint(reply.message ?? "failed")
        return .failure
    case "status":
        var json = false
        var timeoutSeconds: TimeInterval = 1.5

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                json = true
                i += 1
            case "--timeout":
                guard i + 1 < args.count else { eprint("status: --timeout needs a value"); return .usage }
                guard let t = parseTimeout(args[i + 1]) else { eprint("status: invalid timeout"); return .usage }
                timeoutSeconds = t
                i += 2
            default:
                eprint("status: unknown option \(a)")
                return .usage
            }
        }

        let req = makeRequest(command: .status)
        let reply = sendRequest(req, timeoutSeconds: timeoutSeconds)
        guard let reply else { eprint("no reply"); return .noReply }
        guard reply.ok else { eprint(reply.message ?? "failed"); return .failure }

        if json {
            let payload: [String: Any] = [
                "ok": reply.ok,
                "message": reply.message as Any,
                "data": reply.data as Any
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            } else {
                print(reply.data ?? [:])
            }
        } else {
            if let msg = reply.message, !msg.isEmpty {
                print(msg)
            }
            if let data = reply.data, !data.isEmpty {
                for key in data.keys.sorted() {
                    print("\(key): \(data[key] ?? "")")
                }
            }
        }
        return .ok
    default:
        eprint("unknown command: \(command)")
        printUsage()
        return .usage
    }
}

exit(run().rawValue)
