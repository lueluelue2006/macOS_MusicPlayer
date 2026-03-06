import Foundation

public enum IPCCommand: String, Codable {
    case ping
    case status
    case benchmarkLoad
    case clearLyricsCache
    case clearArtworkCache
    case setIPCDebugEnabled
    case debugSnapshot
    case queueSnapshot
    case clearQueue
    case searchQueue
    case setSearchSortOption
    case resetSearchSortOption
    case toggleSearchSortOption
    case playlistsSnapshot
    case playlistTracksSnapshot
    case createPlaylist
    case renamePlaylist
    case deletePlaylist
    case selectPlaylist
    case addTracksToPlaylist
    case removeTracksFromPlaylist
    case playPlaylistTrack
    case setPlaybackScope
    case locateNowPlaying
    case setWeight
    case getWeight
    case clearWeights
    case syncPlaylistWeightsToQueue
    case setLyricsVisible
    case toggleLyricsVisible
    case volumePreanalysis
    case setAnalysisOptions
    case setScanSubfolders
    case refreshMetadata
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
    public let authToken: String?

    public init(
        id: String,
        command: IPCCommand,
        arguments: [String: String]? = nil,
        paths: [String]? = nil,
        authToken: String? = nil
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.paths = paths
        self.authToken = authToken
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

public struct IPCInstanceRegistration: Codable {
    public let instanceID: String
    public let pid: Int32
    public let startedAt: TimeInterval
    public let bundlePath: String
    public let requestNotificationName: String
    public let replyNotificationName: String

    public init(
        instanceID: String,
        pid: Int32,
        startedAt: TimeInterval,
        bundlePath: String,
        requestNotificationName: String,
        replyNotificationName: String
    ) {
        self.instanceID = instanceID
        self.pid = pid
        self.startedAt = startedAt
        self.bundlePath = bundlePath
        self.requestNotificationName = requestNotificationName
        self.replyNotificationName = replyNotificationName
    }
}

public enum MusicPlayerIPC {
    public static let legacyRequestNotification = Notification.Name("musicplayer.ipc.request")
    public static let legacyReplyNotification = Notification.Name("musicplayer.ipc.reply")
    public static let payloadKey = "payload"
    public static let requestNotificationPrefix = "musicplayer.ipc.request."
    public static let replyNotificationPrefix = "musicplayer.ipc.reply."
    public static let registryDirectoryName = "ipc-instances"
    public static let authTokenFileName = "ipc-auth-token"

    public static func requestNotification(for instanceID: String) -> Notification.Name {
        Notification.Name(requestNotificationPrefix + instanceID)
    }

    public static func replyNotification(for instanceID: String) -> Notification.Name {
        Notification.Name(replyNotificationPrefix + instanceID)
    }

    public static func encodePayload<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
