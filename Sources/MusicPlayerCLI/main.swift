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
