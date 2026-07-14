import Foundation

enum ImmersivePlaybackEndAction: Equatable {
    case none
    case advance
    case loopToStart
    case stop
}

struct ImmersivePlaybackPolicy {
    private static let endSafetyMargin: TimeInterval = 0.05

    static func initialPosition(
        requested: TimeInterval?,
        bounds: PlaybackBounds,
        isEnabled: Bool
    ) -> TimeInterval {
        guard isEnabled else {
            return clampPhysical(requested ?? 0, duration: bounds.physicalDuration)
        }

        guard let requested, requested.isFinite else {
            return bounds.audibleStart
        }
        if requested < bounds.audibleStart || requested >= bounds.audibleEnd - endSafetyMargin {
            return bounds.audibleStart
        }
        return requested
    }

    static func seekPosition(
        requested: TimeInterval,
        bounds: PlaybackBounds,
        isEnabled: Bool
    ) -> TimeInterval {
        guard isEnabled else {
            return clampPhysical(requested, duration: bounds.physicalDuration)
        }
        guard requested.isFinite else { return bounds.audibleStart }
        let safeEnd = max(bounds.audibleStart, bounds.audibleEnd - endSafetyMargin)
        return min(max(requested, bounds.audibleStart), safeEnd)
    }

    static func endAction(
        isEnabled: Bool,
        isPlaying: Bool,
        isLooping: Bool,
        isPersistentPlayback: Bool,
        currentTime: TimeInterval,
        bounds: PlaybackBounds,
        tolerance: TimeInterval = 0.02
    ) -> ImmersivePlaybackEndAction {
        guard isEnabled, isPlaying, currentTime.isFinite else { return .none }
        guard currentTime >= bounds.audibleEnd - max(0, tolerance) else { return .none }
        if isLooping { return .loopToStart }
        return isPersistentPlayback ? .advance : .stop
    }

    private static func clampPhysical(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard value.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(value, 0), max(0, duration - endSafetyMargin))
    }
}
