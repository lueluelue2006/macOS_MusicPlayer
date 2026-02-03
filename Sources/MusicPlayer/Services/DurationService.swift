import Foundation
import AVFoundation

enum DurationService {
    /// Fast-path duration loading for list display.
    /// - Note: Uses non-precise timing hint to keep it lightweight. For actual playback,
    ///         `AVAudioPlayer.duration` will be used after preparing the player.
    static func loadDurationSeconds(for url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: false,
            ]
        )

        do {
            let time = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }
}

