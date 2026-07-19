import XCTest
@testable import MusicPlayer

final class RecursiveImportScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecursiveImportScannerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Basic Scanning Tests

    func testScanEmptyDirectory() throws {
        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [])
        XCTAssertEqual(result.totalScanned, 0)
        XCTAssertFalse(result.wasCancelled)
    }

    func testScanSingleAudioFile() throws {
        let audioFile = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: audioFile)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [audioFile])
        XCTAssertEqual(result.totalScanned, 1)
        XCTAssertEqual(result.skipped.count, 0)
    }

    func testScanMultipleAudioFiles() throws {
        let file1 = tempDir.appendingPathComponent("a.mp3")
        let file2 = tempDir.appendingPathComponent("b.m4a")
        let file3 = tempDir.appendingPathComponent("c.flac")
        try Data().write(to: file1)
        try Data().write(to: file2)
        try Data().write(to: file3)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [file1, file2, file3], "files should be in dictionary order")
        XCTAssertEqual(result.totalScanned, 3)
    }

    func testScanNestedDirectories() throws {
        let sub1 = tempDir.appendingPathComponent("sub1")
        let sub2 = sub1.appendingPathComponent("sub2")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

        let root = tempDir.appendingPathComponent("root.mp3")
        let level1 = sub1.appendingPathComponent("level1.mp3")
        let level2 = sub2.appendingPathComponent("level2.mp3")
        try Data().write(to: root)
        try Data().write(to: level1)
        try Data().write(to: level2)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files.count, 3)
        XCTAssertTrue(result.files.contains(root))
        XCTAssertTrue(result.files.contains(level1))
        XCTAssertTrue(result.files.contains(level2))
    }

    func testScanAllSupportedFormats() throws {
        let formats = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"]
        for (idx, ext) in formats.enumerated() {
            let file = tempDir.appendingPathComponent("file\(idx).\(ext)")
            try Data().write(to: file)
        }

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files.count, formats.count)
        XCTAssertEqual(result.totalScanned, formats.count)
    }

    func testScanCaseInsensitiveExtensions() throws {
        let lower = tempDir.appendingPathComponent("lower.mp3")
        let upper = tempDir.appendingPathComponent("upper.MP3")
        let mixed = tempDir.appendingPathComponent("mixed.Mp3")
        try Data().write(to: lower)
        try Data().write(to: upper)
        try Data().write(to: mixed)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files.count, 3)
    }

    // MARK: - Skipped Items Tests

    func testSkipsHiddenFiles() throws {
        let visible = tempDir.appendingPathComponent("visible.mp3")
        let hidden = tempDir.appendingPathComponent(".hidden.mp3")
        try Data().write(to: visible)
        try Data().write(to: hidden)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [visible])
        XCTAssertEqual(result.totalScanned, 1, "hidden files should not be scanned")
    }

    func testSkipsSymbolicLinks() throws {
        let realFile = tempDir.appendingPathComponent("real.mp3")
        try Data().write(to: realFile)

        let linkFile = tempDir.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: realFile)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [realFile], "should only include real file, not symlink")
        let skippedPaths = result.skipped.map(\.path)
        XCTAssertTrue(skippedPaths.contains(linkFile.path), "symlink should be in skipped")
        let symlinkSkip = try XCTUnwrap(result.skipped.first { $0.path == linkFile.path })
        XCTAssertEqual(symlinkSkip.reason, .symbolicLink)
    }

    func testSkipsSymbolicLinkDirectories() throws {
        let realDir = tempDir.appendingPathComponent("realDir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = realDir.appendingPathComponent("song.mp3")
        try Data().write(to: realFile)

        let linkDir = tempDir.appendingPathComponent("linkDir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [realFile], "should not follow symlink directory")
        XCTAssertTrue(result.skipped.contains { $0.reason == .symbolicLink })
    }

    func testSkipsPackageContents() throws {
        let package = tempDir.appendingPathComponent("app.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let insidePackage = package.appendingPathComponent("inside.mp3")
        try Data().write(to: insidePackage)

        let outside = tempDir.appendingPathComponent("outside.mp3")
        try Data().write(to: outside)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [outside], "should skip package contents")
    }

    func testSkipsUnsupportedFormatsSummary() throws {
        let mp3File = tempDir.appendingPathComponent("valid.mp3")
        try Data().write(to: mp3File)

        let txtFile = tempDir.appendingPathComponent("readme.txt")
        try Data().write(to: txtFile)

        let jpgFile = tempDir.appendingPathComponent("cover.jpg")
        try Data().write(to: jpgFile)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [mp3File])
        XCTAssertEqual(result.totalScanned, 3)
        XCTAssertEqual(result.unsupportedFormatCount, 2, "should count unsupported formats without storing each")
    }

    func testSkipsObviousNonAudioFiles() throws {
        let realAudio = tempDir.appendingPathComponent("real.mp3")
        try Data().write(to: realAudio)

        let fakeHTML = tempDir.appendingPathComponent("fake.mp3")
        try "<!DOCTYPE html><html></html>".write(to: fakeHTML, atomically: true, encoding: .utf8)

        let fakeJSON = tempDir.appendingPathComponent("disguised.m4a")
        try "{\"type\":\"json\"}".write(to: fakeJSON, atomically: true, encoding: .utf8)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [realAudio])
        let obviousNonAudio = result.skipped.filter { $0.reason == .obviousNonAudio }
        XCTAssertEqual(obviousNonAudio.count, 2)
        XCTAssertTrue(obviousNonAudio.map(\.path).contains(fakeHTML.path))
        XCTAssertTrue(obviousNonAudio.map(\.path).contains(fakeJSON.path))
    }

    func testSkipsUnreadableFiles() throws {
        let readable = tempDir.appendingPathComponent("readable.mp3")
        try Data().write(to: readable)

        let unreadable = tempDir.appendingPathComponent("unreadable.mp3")
        try Data().write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        // Cleanup before assertions to avoid tearDown failure
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)

        XCTAssertEqual(result.files, [readable])
        let unreadableSkip = result.skipped.first { $0.path == unreadable.path }
        XCTAssertNotNil(unreadableSkip)
        XCTAssertEqual(unreadableSkip?.reason, .unreadable)
    }

    // MARK: - Ordering Tests

    func testFilesInStableDictionaryOrder() throws {
        let fileZ = tempDir.appendingPathComponent("z.mp3")
        let fileA = tempDir.appendingPathComponent("a.mp3")
        let fileM = tempDir.appendingPathComponent("m.mp3")
        try Data().write(to: fileZ)
        try Data().write(to: fileA)
        try Data().write(to: fileM)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [fileA, fileM, fileZ], "files must be in dictionary order")
    }

    func testNestedFilesInCanonicalOrder() throws {
        let sub = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let file1 = tempDir.appendingPathComponent("b.mp3")
        let file2 = sub.appendingPathComponent("a.mp3")
        try Data().write(to: file1)
        try Data().write(to: file2)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        // Dictionary order: "b.mp3" < "sub/a.mp3"
        XCTAssertEqual(result.files.first, file1)
        XCTAssertEqual(result.files.last, file2)
    }

    // MARK: - Cancellation Tests

    func testCancellationStopsImmediately() throws {
        for i in 0..<100 {
            let file = tempDir.appendingPathComponent("file\(i).mp3")
            try Data().write(to: file)
        }

        var callCount = 0
        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: {
            callCount += 1
            return callCount > 5
        })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(result.files.count, 100, "should stop before scanning all files")
        XCTAssertGreaterThan(result.files.count, 0, "should have scanned some files before cancellation")
    }

    func testCancellationDistinguishedFromCompletion() throws {
        let file = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: file)

        let completed = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })
        XCTAssertFalse(completed.wasCancelled)

        let cancelled = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { true })
        XCTAssertTrue(cancelled.wasCancelled)
    }

    // MARK: - Mixed Content Tests

    func testMixedAudioAndNonAudio() throws {
        let mp3 = tempDir.appendingPathComponent("song.mp3")
        let txt = tempDir.appendingPathComponent("readme.txt")
        let jpg = tempDir.appendingPathComponent("cover.jpg")
        let m4a = tempDir.appendingPathComponent("track.m4a")
        try Data().write(to: mp3)
        try Data().write(to: txt)
        try Data().write(to: jpg)
        try Data().write(to: m4a)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files.count, 2)
        XCTAssertTrue(result.files.contains(mp3))
        XCTAssertTrue(result.files.contains(m4a))
        XCTAssertEqual(result.unsupportedFormatCount, 2)
    }

    func testLargeMixedDirectoryDoesNotExplodeMemory() throws {
        // Create many non-audio files
        for i in 0..<1000 {
            let file = tempDir.appendingPathComponent("file\(i).txt")
            try Data().write(to: file)
        }

        let mp3 = tempDir.appendingPathComponent("song.mp3")
        try Data().write(to: mp3)

        let result = RecursiveImportScanner.scan(urls: [tempDir], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [mp3])
        XCTAssertEqual(result.unsupportedFormatCount, 1000, "should summarize count, not store 1000 items")
        XCTAssertEqual(result.skipped.count, 0, "non-audio files should not be individually tracked")
    }

    // MARK: - Direct File Root Tests

    func testScanDirectSingleFileRoot() throws {
        let audioFile = tempDir.appendingPathComponent("direct.mp3")
        try Data().write(to: audioFile)

        let result = RecursiveImportScanner.scan(urls: [audioFile], recursive: true, isCancelled: { false })

        XCTAssertEqual(result.files, [audioFile])
        XCTAssertEqual(result.totalScanned, 1)
        XCTAssertFalse(result.wasCancelled)
    }

    // MARK: - Multiple Mixed Roots Tests

    func testScanMultipleMixedRoots() throws {
        let subDir = tempDir.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let fileInDir = subDir.appendingPathComponent("album.mp3")
        let directFile = tempDir.appendingPathComponent("single.m4a")

        try Data().write(to: fileInDir)
        try Data().write(to: directFile)

        let result = RecursiveImportScanner.scan(
            urls: [subDir, directFile],
            recursive: true,
            isCancelled: { false }
        )

        XCTAssertEqual(result.files.count, 2)
        XCTAssertTrue(result.files.contains(fileInDir))
        XCTAssertTrue(result.files.contains(directFile))
        XCTAssertEqual(result.files, result.files.sorted { $0.path < $1.path }, "should be in canonical/dictionary path order")
    }

    // MARK: - Non-Recursive Tests

    func testNonRecursiveScanOnlyIncludesDirectChildren() throws {
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let rootFile = tempDir.appendingPathComponent("root.mp3")
        let nestedFile = subDir.appendingPathComponent("nested.mp3")

        try Data().write(to: rootFile)
        try Data().write(to: nestedFile)

        let result = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: false,
            isCancelled: { false }
        )

        XCTAssertEqual(result.files, [rootFile], "should only include direct children when recursive is false")
        XCTAssertFalse(result.files.contains(nestedFile))
    }

    // MARK: - Duplicate Detection Tests

    func testDuplicateAndOverlappingRootsAreDeduplicated() throws {
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let rootFile = tempDir.appendingPathComponent("root.mp3")
        let nestedFile = subDir.appendingPathComponent("nested.mp3")

        try Data().write(to: rootFile)
        try Data().write(to: nestedFile)

        let result = RecursiveImportScanner.scan(
            urls: [tempDir, tempDir, subDir],
            recursive: true,
            isCancelled: { false }
        )

        XCTAssertEqual(result.files.count, 2, "should return exactly two files without duplication")
        XCTAssertTrue(result.files.contains(rootFile))
        XCTAssertTrue(result.files.contains(nestedFile))

        let duplicateSkips = result.skipped.filter { $0.reason == .duplicate }
        XCTAssertTrue(duplicateSkips.contains { $0.path == tempDir.path }, "should detect duplicate tempDir root")
        XCTAssertTrue(duplicateSkips.contains { $0.path == subDir.path }, "should detect overlapping subDir root")
    }

    // MARK: - Bounded Resource Tests

    func testOversizedDirectoryStopsAtHardEntryLimitWithoutKeepingPartialResults() throws {
        for index in 0..<33 {
            try Data().write(to: tempDir.appendingPathComponent("track-\(index).mp3"))
        }

        let limits = RecursiveImportScanner.Limits(
            maximumDirectoryEntries: 32,
            maximumDiscoveredItems: 100,
            maximumScannedFiles: 100,
            maximumAcceptedFiles: 100,
            maximumTrackedFileIdentities: 100,
            maximumVisitedDirectories: 10,
            maximumPendingDirectories: 10,
            maximumSkippedItems: 10
        )
        let result = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: true,
            isCancelled: { false },
            limits: limits
        )

        XCTAssertEqual(
            result.stopReason,
            .directoryEntryLimitReached(path: tempDir.path, limit: 32)
        )
        XCTAssertTrue(result.wasTruncated)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.files.count, 0)
        XCTAssertEqual(result.skipped.count, 0)
        XCTAssertEqual(result.totalDiscoveredItemCount, 0)
        XCTAssertLessThanOrEqual(result.visitedDirectoryCount, limits.maximumVisitedDirectories)
    }

    func testAcceptedFilesAndTrackedIdentitiesRespectIndependentHardLimits() throws {
        for index in 0..<10 {
            try Data().write(to: tempDir.appendingPathComponent("audio-\(index).mp3"))
        }

        let acceptedLimits = RecursiveImportScanner.Limits(
            maximumDirectoryEntries: 20,
            maximumDiscoveredItems: 20,
            maximumScannedFiles: 20,
            maximumAcceptedFiles: 3,
            maximumTrackedFileIdentities: 20,
            maximumVisitedDirectories: 10,
            maximumPendingDirectories: 10,
            maximumSkippedItems: 10
        )
        let acceptedResult = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: true,
            isCancelled: { false },
            limits: acceptedLimits
        )

        XCTAssertEqual(acceptedResult.stopReason, .acceptedFileLimitReached(limit: 3))
        XCTAssertEqual(acceptedResult.files.count, 3)
        XCTAssertLessThanOrEqual(acceptedResult.trackedFileIdentityCount, acceptedLimits.maximumTrackedFileIdentities)

        let identityDirectory = tempDir.appendingPathComponent("unsupported")
        try FileManager.default.createDirectory(at: identityDirectory, withIntermediateDirectories: true)
        for index in 0..<10 {
            try Data().write(to: identityDirectory.appendingPathComponent("item-\(index).txt"))
        }
        let identityLimits = RecursiveImportScanner.Limits(
            maximumDirectoryEntries: 20,
            maximumDiscoveredItems: 20,
            maximumScannedFiles: 20,
            maximumAcceptedFiles: 20,
            maximumTrackedFileIdentities: 3,
            maximumVisitedDirectories: 10,
            maximumPendingDirectories: 10,
            maximumSkippedItems: 10
        )
        let identityResult = RecursiveImportScanner.scan(
            urls: [identityDirectory],
            recursive: true,
            isCancelled: { false },
            limits: identityLimits
        )

        XCTAssertEqual(identityResult.stopReason, .trackedFileIdentityLimitReached(limit: 3))
        XCTAssertEqual(identityResult.trackedFileIdentityCount, 3)
        XCTAssertEqual(identityResult.unsupportedFormatCount, 3)
    }

    func testSkippedItemsAreSummarizedAfterStorageLimit() throws {
        let target = tempDir.appendingPathComponent("target.mp3")
        try Data().write(to: target)
        for index in 0..<8 {
            try FileManager.default.createSymbolicLink(
                at: tempDir.appendingPathComponent("link-\(index).mp3"),
                withDestinationURL: target
            )
        }

        let limits = RecursiveImportScanner.Limits(
            maximumDirectoryEntries: 20,
            maximumDiscoveredItems: 20,
            maximumScannedFiles: 20,
            maximumAcceptedFiles: 20,
            maximumTrackedFileIdentities: 20,
            maximumVisitedDirectories: 10,
            maximumPendingDirectories: 10,
            maximumSkippedItems: 2
        )
        let result = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: true,
            isCancelled: { false },
            limits: limits
        )

        XCTAssertNil(result.stopReason)
        XCTAssertEqual(result.files, [target])
        XCTAssertEqual(result.totalSkippedItemCount, 8)
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(result.omittedSkippedItemCount, 6)
    }

    func testVisitedAndPendingDirectoryCollectionsRespectHardLimits() throws {
        for name in ["a", "b", "c"] {
            try FileManager.default.createDirectory(
                at: tempDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let pendingLimits = RecursiveImportScanner.Limits(
            maximumDirectoryEntries: 20,
            maximumDiscoveredItems: 20,
            maximumScannedFiles: 20,
            maximumAcceptedFiles: 20,
            maximumTrackedFileIdentities: 20,
            maximumVisitedDirectories: 10,
            maximumPendingDirectories: 2,
            maximumSkippedItems: 10
        )
        let pendingResult = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: true,
            isCancelled: { false },
            limits: pendingLimits
        )

        XCTAssertEqual(pendingResult.stopReason, .pendingDirectoryLimitReached(limit: 2))
        XCTAssertEqual(pendingResult.peakPendingDirectoryCount, 2)
        XCTAssertEqual(pendingResult.visitedDirectoryCount, 1)

        let visitedLimits = RecursiveImportScanner.Limits(
            maximumDirectoryEntries: 20,
            maximumDiscoveredItems: 20,
            maximumScannedFiles: 20,
            maximumAcceptedFiles: 20,
            maximumTrackedFileIdentities: 20,
            maximumVisitedDirectories: 2,
            maximumPendingDirectories: 10,
            maximumSkippedItems: 10
        )
        let visitedResult = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: true,
            isCancelled: { false },
            limits: visitedLimits
        )

        XCTAssertEqual(visitedResult.stopReason, .visitedDirectoryLimitReached(limit: 2))
        XCTAssertEqual(visitedResult.visitedDirectoryCount, 2)
        XCTAssertLessThanOrEqual(visitedResult.peakPendingDirectoryCount, visitedLimits.maximumPendingDirectories)
    }

    func testCancellationDuringStreamingEnumerationStopsBeforeFileProcessing() throws {
        for index in 0..<200 {
            try Data().write(to: tempDir.appendingPathComponent("track-\(index).mp3"))
        }

        var cancellationChecks = 0
        let result = RecursiveImportScanner.scan(
            urls: [tempDir],
            recursive: true,
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 4
            }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertNil(result.stopReason)
        XCTAssertEqual(result.totalScanned, 0)
        XCTAssertEqual(result.files.count, 0)
        XCTAssertLessThanOrEqual(cancellationChecks, 4)
    }
}
