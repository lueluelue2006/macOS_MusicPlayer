import Foundation

/// Defines what collection the playback controls operate on.
///
/// - `queue`: the main playback queue (`PlaylistManager.audioFiles`)
/// - `playlist`: a user playlist (tracks order defined by the playlist)
enum PlaybackScope: Equatable {
    case queue
    case playlist(UserPlaylist.ID)
}

