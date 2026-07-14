import XCTest
@testable import MusicPlayer

final class ImmersivePlaybackPolicyTests: XCTestCase {
    private let bounds = PlaybackBounds(
        audibleStart: 1.25,
        audibleEnd: 98.5,
        physicalDuration: 100
    )

    func testDisabledModePreservesPhysicalTimeline() {
        XCTAssertEqual(
            ImmersivePlaybackPolicy.initialPosition(requested: nil, bounds: bounds, isEnabled: false),
            0
        )
        XCTAssertEqual(
            ImmersivePlaybackPolicy.seekPosition(requested: 0.5, bounds: bounds, isEnabled: false),
            0.5
        )
        XCTAssertEqual(
            ImmersivePlaybackPolicy.endAction(
                isEnabled: false,
                isPlaying: true,
                isLooping: false,
                isPersistentPlayback: true,
                currentTime: 99,
                bounds: bounds
            ),
            .none
        )
    }

    func testFreshLoadAndInvalidRestoreStartAtAudibleBoundary() {
        XCTAssertEqual(
            ImmersivePlaybackPolicy.initialPosition(requested: nil, bounds: bounds, isEnabled: true),
            bounds.audibleStart
        )
        XCTAssertEqual(
            ImmersivePlaybackPolicy.initialPosition(requested: 0.5, bounds: bounds, isEnabled: true),
            bounds.audibleStart
        )
        XCTAssertEqual(
            ImmersivePlaybackPolicy.initialPosition(requested: 99, bounds: bounds, isEnabled: true),
            bounds.audibleStart
        )
        XCTAssertEqual(
            ImmersivePlaybackPolicy.initialPosition(requested: 42, bounds: bounds, isEnabled: true),
            42
        )
    }

    func testSeekIsClampedToAudibleRangeOnlyWhenEnabled() {
        XCTAssertEqual(
            ImmersivePlaybackPolicy.seekPosition(requested: 0, bounds: bounds, isEnabled: true),
            bounds.audibleStart
        )
        XCTAssertEqual(
            ImmersivePlaybackPolicy.seekPosition(requested: 100, bounds: bounds, isEnabled: true),
            bounds.audibleEnd - 0.05,
            accuracy: 0.000_1
        )
    }

    func testLogicalEndSelectsExistingPlaybackSemantics() {
        XCTAssertEqual(action(looping: false, persistent: true), .advance)
        XCTAssertEqual(action(looping: true, persistent: true), .loopToStart)
        XCTAssertEqual(action(looping: false, persistent: false), .stop)

        let early = ImmersivePlaybackPolicy.endAction(
            isEnabled: true,
            isPlaying: true,
            isLooping: false,
            isPersistentPlayback: true,
            currentTime: bounds.audibleEnd - 1,
            bounds: bounds
        )
        XCTAssertEqual(early, .none)
    }

    private func action(looping: Bool, persistent: Bool) -> ImmersivePlaybackEndAction {
        ImmersivePlaybackPolicy.endAction(
            isEnabled: true,
            isPlaying: true,
            isLooping: looping,
            isPersistentPlayback: persistent,
            currentTime: bounds.audibleEnd,
            bounds: bounds
        )
    }
}
