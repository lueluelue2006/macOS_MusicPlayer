import Foundation

public enum IPCCommand: String, Codable {
    case ping
    case status
    case benchmarkLoad
    case clearLyricsCache
    case clearArtworkCache
    case togglePlayPause
    case pause
    case resume
    case next
    case previous
    case random
    case playIndex
    case playQuery
    case seek
    case setVolume
    case setRate
    case toggleNormalization
    case setNormalizationEnabled
    case toggleShuffle
    case toggleLoop
    case add
    case remove
    case screenshot
}

public struct IPCRequest: Codable {
    public let id: String
    public let command: IPCCommand
    public let arguments: [String: String]?
    public let paths: [String]?

    public init(id: String, command: IPCCommand, arguments: [String: String]? = nil, paths: [String]? = nil) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.paths = paths
    }
}

public struct IPCReply: Codable {
    public let id: String
    public let ok: Bool
    public let message: String?
    public let data: [String: String]?

    public init(id: String, ok: Bool, message: String? = nil, data: [String: String]? = nil) {
        self.id = id
        self.ok = ok
        self.message = message
        self.data = data
    }
}

public enum MusicPlayerIPC {
    public static let requestNotification = Notification.Name("musicplayer.ipc.request")
    public static let replyNotification = Notification.Name("musicplayer.ipc.reply")
    public static let payloadKey = "payload"

    public static func encodePayload<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
