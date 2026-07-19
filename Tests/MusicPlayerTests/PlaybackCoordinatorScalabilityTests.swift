import XCTest
import Darwin
@testable import MusicPlayer

final class PlaybackCoordinatorScalabilityTests: XCTestCase {
    func testHundredThousandTrackSnapshotSchedulingStaysWithinMainThreadBudget() async {
        let metadata = AudioMetadata(
            title: "Track",
            artist: "Artist",
            album: "Album",
            year: nil,
            genre: nil,
            artwork: nil
        )
        let files = (0..<100_000).map { index in
            AudioFile(
                id: "track-\(index)",
                url: URL(fileURLWithPath: "/tmp/musicplayer-scale/track-\(index).mp3"),
                metadata: metadata
            )
        }
        let client = CandidatePageProbeClient(selectsCandidates: false)

        let (task, elapsed) = await MainActor.run {
            let snapshot = AutomaticVolumePreanalysisSnapshot(audioFiles: files)
            let startedAt = ContinuousClock.now
            let task = AutomaticVolumePreanalysisCandidateBuilder.start(
                snapshot: snapshot,
                client: client
            )
            return (task, startedAt.duration(to: .now))
        }

        XCTAssertLessThan(
            elapsed,
            .milliseconds(100),
            "The MainActor path must retain the COW array and schedule detached work only"
        )
        let candidates = await task.value
        XCTAssertTrue(candidates.isEmpty)
        let observation = client.observation
        XCTAssertEqual(observation.visitedURLCount, 100_000)
        XCTAssertLessThanOrEqual(
            observation.maximumPageSize,
            AutomaticVolumePreanalysisCandidateBuilder.maximumPageSize
        )
        XCTAssertFalse(observation.observedMainThreadWork)
    }

    func testCandidateBuilderUsesBoundedPagesAndReturnsAtMostTwoPerRound() async {
        let metadata = AudioMetadata(
            title: "Track",
            artist: "Artist",
            album: "Album",
            year: nil,
            genre: nil,
            artwork: nil
        )
        let files = (0..<1_000).map { index in
            AudioFile(
                id: "track-\(index)",
                url: URL(fileURLWithPath: "/tmp/musicplayer-pages/track-\(index).mp3"),
                metadata: metadata
            )
        }
        let client = CandidatePageProbeClient(selectsCandidates: true)
        let task = AutomaticVolumePreanalysisCandidateBuilder.start(
            snapshot: AutomaticVolumePreanalysisSnapshot(audioFiles: files),
            client: client,
            pageSize: 10_000,
            candidateLimit: 10_000
        )

        let candidates = await task.value
        XCTAssertEqual(candidates.count, 2)
        XCTAssertLessThanOrEqual(
            client.observation.maximumPageSize,
            AutomaticVolumePreanalysisCandidateBuilder.maximumPageSize
        )
        XCTAssertFalse(client.observation.observedMainThreadWork)
    }
}

private final class CandidatePageProbeClient:
    AutomaticVolumePreanalysisClient,
    @unchecked Sendable
{
    struct Observation {
        let maximumPageSize: Int
        let visitedURLCount: Int
        let observedMainThreadWork: Bool
    }

    private let lock = NSLock()
    private let selectsCandidates: Bool
    private var maximumPageSize = 0
    private var visitedURLCount = 0
    private var observedMainThreadWork = false

    init(selectsCandidates: Bool) {
        self.selectsCandidates = selectsCandidates
    }

    var observation: Observation {
        lock.lock()
        defer { lock.unlock() }
        return Observation(
            maximumPageSize: maximumPageSize,
            visitedURLCount: visitedURLCount,
            observedMainThreadWork: observedMainThreadWork
        )
    }

    func eligibleCandidates(in urls: [URL], limit: Int) async -> [URL] {
        recordPage(size: urls.count, wasMainThread: pthread_main_np() != 0)
        guard selectsCandidates else { return [] }
        return Array(urls.prefix(limit))
    }

    private func recordPage(size: Int, wasMainThread: Bool) {
        lock.lock()
        maximumPageSize = max(maximumPageSize, size)
        visitedURLCount += size
        observedMainThreadWork = observedMainThreadWork || wasMainThread
        lock.unlock()
    }

    func nextRetryDate() -> Date? { nil }

    func runAutomaticPreanalysis(for _: URL) async throws {}

    func cancelAutomaticPreanalysis() {}
}
