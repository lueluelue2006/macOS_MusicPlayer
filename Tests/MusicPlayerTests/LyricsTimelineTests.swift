import XCTest
@testable import MusicPlayer

final class LyricsTimelineTests: XCTestCase {
    func testUnsyncedLyricsReturnsNilForCurrentIndex() {
        let lines = [
            LyricsLine(id: 0, timestamp: nil, text: "First line"),
            LyricsLine(id: 1, timestamp: nil, text: "Second line"),
            LyricsLine(id: 2, timestamp: nil, text: "Third line")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: false, source: .embeddedUnsynced)

        XCTAssertNil(timeline.currentIndex(at: 0))
        XCTAssertNil(timeline.currentIndex(at: 10))
        XCTAssertNil(timeline.currentIndex(at: 100))
    }

    func testSyncedLyricsReturnsCorrectIndexBeforeFirstTimestamp() {
        let lines = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First line"),
            LyricsLine(id: 1, timestamp: 10.0, text: "Second line"),
            LyricsLine(id: 2, timestamp: 15.0, text: "Third line")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertNil(timeline.currentIndex(at: 0), "Before first timestamp should return nil")
        XCTAssertNil(timeline.currentIndex(at: 4.9), "Just before first timestamp should return nil")
    }

    func testSyncedLyricsReturnsCorrectIndexAtExactTimestamp() {
        let lines = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First line"),
            LyricsLine(id: 1, timestamp: 10.0, text: "Second line"),
            LyricsLine(id: 2, timestamp: 15.0, text: "Third line")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertEqual(timeline.currentIndex(at: 5.0), 0, "At first timestamp")
        XCTAssertEqual(timeline.currentIndex(at: 10.0), 1, "At second timestamp")
        XCTAssertEqual(timeline.currentIndex(at: 15.0), 2, "At third timestamp")
    }

    func testSyncedLyricsReturnsCorrectIndexBetweenTimestamps() {
        let lines = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First line"),
            LyricsLine(id: 1, timestamp: 10.0, text: "Second line"),
            LyricsLine(id: 2, timestamp: 15.0, text: "Third line")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertEqual(timeline.currentIndex(at: 7.5), 0, "Between first and second")
        XCTAssertEqual(timeline.currentIndex(at: 12.0), 1, "Between second and third")
    }

    func testSyncedLyricsReturnsLastIndexAfterLastTimestamp() {
        let lines = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First line"),
            LyricsLine(id: 1, timestamp: 10.0, text: "Second line"),
            LyricsLine(id: 2, timestamp: 15.0, text: "Third line")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertEqual(timeline.currentIndex(at: 20.0), 2, "After last timestamp")
        XCTAssertEqual(timeline.currentIndex(at: 100.0), 2, "Far after last timestamp")
    }

    func testSyncedLyricsWithSingleLine() {
        let lines = [
            LyricsLine(id: 0, timestamp: 10.0, text: "Only line")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertNil(timeline.currentIndex(at: 5.0), "Before single timestamp")
        XCTAssertEqual(timeline.currentIndex(at: 10.0), 0, "At single timestamp")
        XCTAssertEqual(timeline.currentIndex(at: 15.0), 0, "After single timestamp")
    }

    func testSyncedLyricsWithEmptyLines() {
        let timeline = LyricsTimeline(lines: [], isSynced: true, source: .embeddedSynced)

        XCTAssertNil(timeline.currentIndex(at: 0))
        XCTAssertNil(timeline.currentIndex(at: 10))
    }

    func testSyncedLyricsWithNonSequentialTimestamps() {
        // Lines with timestamps in expected order
        let lines = [
            LyricsLine(id: 0, timestamp: 2.5, text: "First"),
            LyricsLine(id: 1, timestamp: 7.3, text: "Second"),
            LyricsLine(id: 2, timestamp: 12.1, text: "Third"),
            LyricsLine(id: 3, timestamp: 20.8, text: "Fourth")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertNil(timeline.currentIndex(at: 2.4))
        XCTAssertEqual(timeline.currentIndex(at: 2.5), 0)
        XCTAssertEqual(timeline.currentIndex(at: 5.0), 0)
        XCTAssertEqual(timeline.currentIndex(at: 7.3), 1)
        XCTAssertEqual(timeline.currentIndex(at: 10.0), 1)
        XCTAssertEqual(timeline.currentIndex(at: 12.1), 2)
        XCTAssertEqual(timeline.currentIndex(at: 15.0), 2)
        XCTAssertEqual(timeline.currentIndex(at: 20.8), 3)
        XCTAssertEqual(timeline.currentIndex(at: 30.0), 3)
    }

    func testSyncedLyricsWithZeroTimestamp() {
        let lines = [
            LyricsLine(id: 0, timestamp: 0.0, text: "Start"),
            LyricsLine(id: 1, timestamp: 5.0, text: "Second"),
            LyricsLine(id: 2, timestamp: 10.0, text: "Third")
        ]
        let timeline = LyricsTimeline(lines: lines, isSynced: true, source: .embeddedSynced)

        XCTAssertEqual(timeline.currentIndex(at: 0.0), 0, "At zero timestamp")
        XCTAssertEqual(timeline.currentIndex(at: 2.0), 0, "After zero, before next")
        XCTAssertEqual(timeline.currentIndex(at: 5.0), 1)
    }

    func testLyricsTimelineEquality() {
        let lines1 = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First"),
            LyricsLine(id: 1, timestamp: 10.0, text: "Second")
        ]
        let lines2 = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First"),
            LyricsLine(id: 1, timestamp: 10.0, text: "Second")
        ]
        let lines3 = [
            LyricsLine(id: 0, timestamp: 5.0, text: "First"),
            LyricsLine(id: 1, timestamp: 15.0, text: "Different")
        ]

        let timeline1 = LyricsTimeline(lines: lines1, isSynced: true, source: .embeddedSynced)
        let timeline2 = LyricsTimeline(lines: lines2, isSynced: true, source: .embeddedSynced)
        let timeline3 = LyricsTimeline(lines: lines3, isSynced: true, source: .embeddedSynced)
        let timeline4 = LyricsTimeline(lines: lines1, isSynced: false, source: .embeddedUnsynced)

        XCTAssertEqual(timeline1, timeline2, "Identical timelines should be equal")
        XCTAssertNotEqual(timeline1, timeline3, "Different lines should not be equal")
        XCTAssertNotEqual(timeline1, timeline4, "Different sync status should not be equal")
    }

    func testLyricsLineEquality() {
        let line1 = LyricsLine(id: 0, timestamp: 5.0, text: "Hello")
        let line2 = LyricsLine(id: 0, timestamp: 5.0, text: "Hello")
        let line3 = LyricsLine(id: 1, timestamp: 5.0, text: "Hello")
        let line4 = LyricsLine(id: 0, timestamp: 10.0, text: "Hello")
        let line5 = LyricsLine(id: 0, timestamp: 5.0, text: "World")
        let line6 = LyricsLine(id: 0, timestamp: nil, text: "Hello")

        XCTAssertEqual(line1, line2, "Identical lines should be equal")
        XCTAssertNotEqual(line1, line3, "Different id should not be equal")
        XCTAssertNotEqual(line1, line4, "Different timestamp should not be equal")
        XCTAssertNotEqual(line1, line5, "Different text should not be equal")
        XCTAssertNotEqual(line1, line6, "Different timestamp (nil vs non-nil) should not be equal")
    }

    func testLyricsSourceEquality() {
        let source1 = LyricsSource.embeddedUnsynced
        let source2 = LyricsSource.embeddedUnsynced
        let source3 = LyricsSource.embeddedSynced
        let url1 = URL(fileURLWithPath: "/path/to/lyrics.lrc")
        let url2 = URL(fileURLWithPath: "/path/to/lyrics.lrc")
        let url3 = URL(fileURLWithPath: "/path/to/other.lrc")
        let source4 = LyricsSource.sidecarLRC(url1)
        let source5 = LyricsSource.sidecarLRC(url2)
        let source6 = LyricsSource.sidecarLRC(url3)

        XCTAssertEqual(source1, source2)
        XCTAssertNotEqual(source1, source3)
        XCTAssertEqual(source4, source5, "Same URL path should be equal")
        XCTAssertNotEqual(source4, source6, "Different URL path should not be equal")
    }
}

// MARK: - LRC Parsing Tests

@MainActor
final class LRCParsingTests: XCTestCase {
    private var service: LyricsService!

    override func setUp() async throws {
        service = LyricsService.shared
    }

    func testParseLRCWithThreeDigitMilliseconds() async throws {
        let lrc = """
        [00:12.345]First line with 345ms
        [00:23.678]Second line with 678ms
        [01:05.123]Third line with 123ms
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertTrue(timeline.isSynced)
        XCTAssertEqual(timeline.lines.count, 3)

        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 12.345, accuracy: 0.0001)
        XCTAssertEqual(timeline.lines[0].text, "First line with 345ms")

        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 23.678, accuracy: 0.0001)
        XCTAssertEqual(timeline.lines[1].text, "Second line with 678ms")

        XCTAssertEqual(try XCTUnwrap(timeline.lines[2].timestamp), 65.123, accuracy: 0.0001)
        XCTAssertEqual(timeline.lines[2].text, "Third line with 123ms")
    }

    func testParseLRCWithFourDigitMilliseconds() async throws {
        let lrc = """
        [00:12.3456]First line with 3456 ten-thousandths
        [00:23.6789]Second line with 6789 ten-thousandths
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertTrue(timeline.isSynced)
        XCTAssertEqual(timeline.lines.count, 2)

        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 12.3456, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 23.6789, accuracy: 0.00001)
    }

    func testParseLRCWithPositiveOffsetExplicitPlus() async throws {
        let lrc = """
        [offset:+500]
        [00:10.00]First line
        [00:20.00]Second line
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 2)

        // offset:+500 means +500ms = +0.5s
        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 10.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 20.5, accuracy: 0.001)
    }

    func testParseLRCWithPositiveOffsetImplicit() async throws {
        let lrc = """
        [offset:500]
        [00:10.00]First line
        [00:20.00]Second line
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 2)

        // offset:500 means +500ms = +0.5s
        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 10.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 20.5, accuracy: 0.001)
    }

    func testParseLRCWithNegativeOffset() async throws {
        let lrc = """
        [offset:-300]
        [00:10.00]First line
        [00:20.00]Second line
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 2)

        // offset:-300 means -300ms = -0.3s
        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 9.7, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 19.7, accuracy: 0.001)
    }

    func testParseLRCWithOffsetAndHighPrecision() async throws {
        let lrc = """
        [offset:250]
        [00:10.123]First line
        [00:20.456]Second line
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 2)

        // offset:250 = +0.25s
        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 10.373, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 20.706, accuracy: 0.0001)
    }

    func testParseLRCWithoutOffset() async throws {
        let lrc = """
        [00:10.50]First line
        [00:20.75]Second line
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 2)

        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 10.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 20.75, accuracy: 0.001)
    }

    func testParseLRCWithMixedPrecision() async throws {
        let lrc = """
        [00:10]No fractional seconds
        [00:20.5]One digit
        [00:30.50]Two digits
        [00:40.500]Three digits
        [00:50.5000]Four digits
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 5)

        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), 10.0, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 20.5, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[2].timestamp), 30.50, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[3].timestamp), 40.500, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[4].timestamp), 50.5000, accuracy: 0.00001)
    }

    func testParseLRCWithOffsetAndNegativeResultTimestamp() async throws {
        let lrc = """
        [offset:-15000]
        [00:10.00]First line at -5s (clamped or allowed)
        [00:20.00]Second line at 5s
        """

        let parsed = await service.parseLRC(text: lrc, source: .embeddedSynced)
        let timeline = try XCTUnwrap(parsed)
        XCTAssertEqual(timeline.lines.count, 2)

        // offset:-15000 = -15s
        XCTAssertEqual(try XCTUnwrap(timeline.lines[0].timestamp), -5.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.lines[1].timestamp), 5.0, accuracy: 0.001)
    }
}
