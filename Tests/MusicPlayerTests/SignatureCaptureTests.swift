import XCTest
@testable import MusicPlayer

@MainActor
final class SignatureCaptureTests: XCTestCase {
    var tempDir: URL!
    var counter: TestSignatureCaptureCounter!
    var captureService: SignatureCaptureService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        counter = TestSignatureCaptureCounter()
        captureService = SignatureCaptureService(counter: counter)
    }

    override func tearDown() async throws {
        await counter.reset()
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        counter = nil
        captureService = nil
    }

    func testQueueImportCapturesAndPersistsSignatures() async throws {
        let file1 = tempDir.appendingPathComponent("track1.wav")
        let file2 = tempDir.appendingPathComponent("track2.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: file2, frequency: 880, duration: 0.1)

        let playlistFile = tempDir.appendingPathComponent("playlist.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistFile,
            disablePersistence: false,
            persistenceDebounceInterval: 0.01,
            signatureCaptureService: captureService
        )

        manager.enqueueAddFiles([file1, file2])
        await manager.waitForAddFilesCompletionForTesting()

        let files = manager.audioFiles
        XCTAssertEqual(files.count, 2)

        let uniqueCaptures = await counter.uniqueCaptureCount()
        XCTAssertEqual(uniqueCaptures, 2, "Should capture signature for each unique file")

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]] else {
            XCTFail("Failed to load saved playlist")
            return
        }

        XCTAssertEqual(tracks.count, 2)
        let signaturesPresent = tracks.compactMap { $0["signature"] }.count
        XCTAssertEqual(signaturesPresent, 2, "All tracks should have persisted signatures")
    }

    func testUserPlaylistCreationCapturesSignatures() async throws {
        let file1 = tempDir.appendingPathComponent("playlist-track1.wav")
        let file2 = tempDir.appendingPathComponent("playlist-track2.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: file2, frequency: 880, duration: 0.1)

        let storeFile = tempDir.appendingPathComponent("playlists.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeFile,
            signatureCaptureService: captureService
        )
        await store.ensureLoaded()

        await counter.reset()

        let playlistID = await store.createPlaylist(name: "Test Playlist", trackURLs: [file1, file2])
        XCTAssertNotNil(playlistID)

        await counter.waitForCaptureCount(2)
        let uniqueCaptures = await counter.uniqueCaptureCount()
        XCTAssertEqual(uniqueCaptures, 2, "Should capture signatures during playlist creation")

        let enriched = await waitUntil {
            guard let playlistID,
                  let playlist = store.playlist(for: playlistID) else { return false }
            return playlist.tracks.allSatisfy { $0.signature != nil }
        }
        XCTAssertTrue(enriched)

        store.flushPersistence()

        guard let data = try? Data(contentsOf: storeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlists = json["playlists"] as? [[String: Any]],
              let playlist = playlists.first,
              let tracks = playlist["tracks"] as? [[String: Any]] else {
            XCTFail("Failed to load saved playlists")
            return
        }

        XCTAssertEqual(tracks.count, 2)
        let signaturesPresent = tracks.compactMap { $0["signature"] }.count
        XCTAssertEqual(signaturesPresent, 2, "All playlist tracks should have signatures")
    }

    func testAddTracksToExistingPlaylistCapturesSignatures() async throws {
        let file1 = tempDir.appendingPathComponent("add-track1.wav")
        let file2 = tempDir.appendingPathComponent("add-track2.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: file2, frequency: 880, duration: 0.1)

        let storeFile = tempDir.appendingPathComponent("playlists-add.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeFile,
            signatureCaptureService: captureService
        )
        await store.ensureLoaded()

        await counter.reset()

        let playlistID = await store.createPlaylist(name: "Add Test", trackURLs: [file1])
        XCTAssertNotNil(playlistID)

        await counter.waitForCaptureCount(1)
        let capturesAfterCreate = await counter.captureCount()
        XCTAssertEqual(capturesAfterCreate, 1)

        guard let id = playlistID else {
            XCTFail("No playlist ID")
            return
        }

        let added = await store.addTracks([file2], to: id)
        XCTAssertEqual(added, 1)

        await counter.waitForCaptureCount(2)
        let totalCaptures = await counter.captureCount()
        XCTAssertEqual(totalCaptures, 2, "Should capture signature for newly added track")

        let enriched = await waitUntil {
            store.playlist(for: id)?.tracks.allSatisfy { $0.signature != nil } == true
        }
        XCTAssertTrue(enriched)

        store.flushPersistence()

        guard let data = try? Data(contentsOf: storeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlists = json["playlists"] as? [[String: Any]],
              let playlist = playlists.first,
              let tracks = playlist["tracks"] as? [[String: Any]] else {
            XCTFail("Failed to load saved playlists")
            return
        }

        XCTAssertEqual(tracks.count, 2)
        let signaturesPresent = tracks.compactMap { $0["signature"] }.count
        XCTAssertEqual(signaturesPresent, 2)
    }

    func testRepeatedSaveDoesNotRecaptureSignatures() async throws {
        let file1 = tempDir.appendingPathComponent("stable-track.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)

        let playlistFile = tempDir.appendingPathComponent("playlist-stable.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistFile,
            disablePersistence: false,
            persistenceDebounceInterval: 0.01,
            signatureCaptureService: captureService
        )

        manager.enqueueAddFiles([file1])
        await manager.waitForAddFilesCompletionForTesting()

        let capturesAfterAdd = await counter.captureCount()
        XCTAssertEqual(capturesAfterAdd, 1)

        manager.flushPlaylistPersistence()
        manager.flushPlaylistPersistence()
        manager.flushPlaylistPersistence()

        let capturesAfterRepeatedFlush = await counter.captureCount()
        XCTAssertEqual(capturesAfterRepeatedFlush, 1, "Repeated flush should not recapture signatures")
    }

    func testBatchDeduplicationCapturesOnlyOncePerPath() async throws {
        let file1 = tempDir.appendingPathComponent("dedup-track.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)

        let playlistFile = tempDir.appendingPathComponent("playlist-dedup.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistFile,
            disablePersistence: false,
            persistenceDebounceInterval: 0.01,
            signatureCaptureService: captureService
        )

        manager.enqueueAddFiles([file1, file1, file1])
        await manager.waitForAddFilesCompletionForTesting()

        let files = manager.audioFiles
        XCTAssertEqual(files.count, 1, "Should deduplicate to one file")

        let totalCaptures = await counter.captureCount()
        XCTAssertEqual(totalCaptures, 1, "Should only attempt capture once for duplicate paths in batch")
    }

    func testPlaylistDeletionDuringCaptureDiscardsResults() async throws {
        let file1 = tempDir.appendingPathComponent("delete-track1.wav")
        let file2 = tempDir.appendingPathComponent("delete-track2.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: file2, frequency: 880, duration: 0.1)

        let storeFile = tempDir.appendingPathComponent("playlists-delete.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeFile,
            signatureCaptureService: captureService
        )
        await store.ensureLoaded()

        let emptyID = store.createEmptyPlaylist(name: "To Delete")
        XCTAssertNotNil(emptyID)
        guard let playlistID = emptyID else { return }

        await counter.pause()

        let addTask = Task {
            await store.addTracks([file1, file2], to: playlistID)
        }

        await counter.waitForCaptureCount(1)

        let playlist = store.playlist(for: playlistID)
        XCTAssertNotNil(playlist)
        store.deletePlaylist(playlist!)

        await counter.resume()

        let added = await addTask.value
        XCTAssertEqual(added, 2, "Track insertion committed before the later playlist deletion")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let playlists = store.playlists
        XCTAssertTrue(playlists.isEmpty, "Playlist should be deleted")

        store.flushPersistence()

        guard let data = try? Data(contentsOf: storeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedPlaylists = json["playlists"] as? [[String: Any]] else {
            XCTFail("Failed to decode saved playlists after deletion")
            return
        }

        XCTAssertTrue(savedPlaylists.isEmpty, "No playlists should persist after deletion")
    }

    func testPersistenceRecoveryReschedulesOnlyCurrentMissingSignatureTargets() async throws {
        let deletedURL = tempDir.appendingPathComponent("retry-deleted.wav")
        let replacedURL = tempDir.appendingPathComponent("retry-replaced.wav")
        let currentURL = tempDir.appendingPathComponent("retry-current.wav")
        try TestAudioFixture.createSineWAV(at: deletedURL, frequency: 330, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: replacedURL, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: currentURL, frequency: 550, duration: 0.1)

        let storeFile = tempDir.appendingPathComponent("playlists-retry.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeFile,
            signatureCaptureService: captureService,
            automaticallyProcessesCleanup: false
        )
        await store.ensureLoaded()
        try FileManager.default.createDirectory(at: storeFile, withIntermediateDirectories: false)

        let deletedCreation = await store.createPlaylistResult(
            name: "Deleted",
            trackURLs: [deletedURL]
        )
        guard case .applied(let deletedPlaylistID, _) = deletedCreation else {
            return XCTFail("first playlist mutation must be accepted in memory")
        }
        let liveCreation = await store.createPlaylistResult(
            name: "Live",
            trackURLs: [replacedURL]
        )
        guard case .applied(let livePlaylistID, _) = liveCreation,
              let deletedPlaylist = store.playlist(for: deletedPlaylistID),
              let replacedTrack = store.playlist(for: livePlaylistID)?.tracks.first else {
            return XCTFail("test playlists must exist before recovery")
        }

        guard case .applied = store.deletePlaylistResult(deletedPlaylist),
              case .applied = store.removeTracksResult(
                  trackIDs: [replacedTrack.id],
                  from: livePlaylistID
              ) else {
            return XCTFail("stale targets must be removable while persistence is dirty")
        }
        let replacement = await store.addTracksResult([currentURL], to: livePlaylistID)
        guard case .applied(_, let latestReceipt) = replacement else {
            return XCTFail("replacement track mutation must be accepted")
        }

        guard case .failed = await store.awaitDurableCommit(latestReceipt) else {
            return XCTFail("directory at the snapshot path must exhaust the initial write retries")
        }
        let capturesBeforeRecovery = await counter.captureCount()
        XCTAssertEqual(capturesBeforeRecovery, 0)

        try FileManager.default.removeItem(at: storeFile)
        let retryReceipt = try XCTUnwrap(store.retryPersistence())
        guard case .committed = await store.awaitDurableCommit(retryReceipt) else {
            return XCTFail("manual persistence retry must recover after storage is writable")
        }

        let enriched = await waitUntil(timeout: 2) {
            guard let playlist = store.playlist(for: livePlaylistID),
                  playlist.tracks.count == 1 else { return false }
            return playlist.tracks[0].path == currentURL.path
                && playlist.tracks[0].signature != nil
        }
        XCTAssertTrue(enriched)
        XCTAssertNil(store.playlist(for: deletedPlaylistID))
        let captureCount = await counter.captureCount()
        let uniqueCaptureCount = await counter.uniqueCaptureCount()
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(uniqueCaptureCount, 1)
        XCTAssertTrue(store.flushPersistence())

        let data = try Data(contentsOf: storeFile)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let savedPlaylists = try XCTUnwrap(payload["playlists"] as? [[String: Any]])
        let savedTracks = savedPlaylists.flatMap {
            ($0["tracks"] as? [[String: Any]]) ?? []
        }
        XCTAssertEqual(savedTracks.compactMap { $0["path"] as? String }, [currentURL.path])
    }

    func testPlaylistsStoreDrainWaitsForSignatureBatches() async throws {
        let file1 = tempDir.appendingPathComponent("store-drain-track.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)

        let storeFile = tempDir.appendingPathComponent("playlists-store-drain.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeFile,
            signatureCaptureService: captureService
        )
        await store.ensureLoaded()

        let emptyID = store.createEmptyPlaylist(name: "Drain Test")
        guard let playlistID = emptyID else {
            XCTFail("Failed to create playlist")
            return
        }

        await counter.pause()

        let addTask = Task {
            await store.addTracks([file1], to: playlistID)
        }

        await counter.waitForCaptureCount(1)

        let drainTask = Task {
            await store.drainAndFlushForTermination()
        }

        await store.waitUntilTerminationStartedForTesting()

        await counter.resume()

        let added = await addTask.value
        await drainTask.value

        XCTAssertEqual(added, 1, "Track path mutation should commit before termination")

        let capturesCompleted = await counter.captureCount()
        XCTAssertEqual(capturesCompleted, 1, "The started capture should remain observable")

        guard let data = try? Data(contentsOf: storeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlists = json["playlists"] as? [[String: Any]],
              let playlist = playlists.first,
              let tracks = playlist["tracks"] as? [[String: Any]] else {
            XCTFail("Failed to load flushed store")
            return
        }

        let signaturesPresent = tracks.compactMap { $0["signature"] }.count
        XCTAssertEqual(
            signaturesPresent,
            0,
            "Termination cancels reconstructable signature enrichment instead of blocking quit"
        )
    }

    func testPlaylistManagerDrainCancelsInProgressAndFlushes() async throws {
        let file1 = tempDir.appendingPathComponent("manager-drain-track1.wav")
        let file2 = tempDir.appendingPathComponent("manager-drain-track2.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: file2, frequency: 880, duration: 0.1)

        let playlistFile = tempDir.appendingPathComponent("playlist-manager-drain.json")
        let manager = PlaylistManager(
            playlistFileURLOverride: playlistFile,
            disablePersistence: false,
            persistenceDebounceInterval: 0.01,
            signatureCaptureService: captureService
        )

        await counter.pause()

        manager.enqueueAddFiles([file1, file2])

        await counter.waitForCaptureCount(1)

        let drainTask = Task {
            await manager.drainAndFlushForTermination()
        }

        await manager.waitUntilTerminationStartedForTesting()

        await counter.resume()

        await drainTask.value

        let files = manager.audioFiles
        XCTAssertEqual(files.count, 0, "Cancelled batch should not merge into queue")

        manager.flushPlaylistPersistence()

        guard let data = try? Data(contentsOf: playlistFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]] else {
            XCTFail("Flush should write playlist file")
            return
        }

        XCTAssertEqual(tracks.count, 0, "Cancelled batch should not persist")
    }

    func testM3U8ImportResultsPersistSignatures() async throws {
        let file1 = tempDir.appendingPathComponent("m3u-track1.wav")
        let file2 = tempDir.appendingPathComponent("m3u-track2.wav")
        try TestAudioFixture.createSineWAV(at: file1, frequency: 440, duration: 0.1)
        try TestAudioFixture.createSineWAV(at: file2, frequency: 880, duration: 0.1)

        let m3u8Content = """
        #EXTM3U
        #EXTINF:0,Track 1
        \(file1.path)
        #EXTINF:0,Track 2
        \(file2.path)
        """
        let m3u8File = tempDir.appendingPathComponent("test.m3u8")
        try m3u8Content.write(to: m3u8File, atomically: true, encoding: .utf8)

        let result = try M3U8ImportService.importPlaylist(from: m3u8File)

        let storeFile = tempDir.appendingPathComponent("playlists-m3u.json")
        let store = PlaylistsStore(
            playlistsFileURLOverride: storeFile,
            signatureCaptureService: captureService
        )
        await store.ensureLoaded()

        await counter.reset()

        let playlistID = await store.createPlaylist(name: result.playlistName, tracks: result.tracks)
        XCTAssertNotNil(playlistID)

        await counter.waitForCaptureCount(2)
        let uniqueCaptures = await counter.uniqueCaptureCount()
        XCTAssertEqual(uniqueCaptures, 2, "M3U8 tracks should trigger signature capture")

        let enriched = await waitUntil {
            guard let playlistID,
                  let playlist = store.playlist(for: playlistID) else { return false }
            return playlist.tracks.allSatisfy { $0.signature != nil }
        }
        XCTAssertTrue(enriched)

        store.flushPersistence()

        guard let data = try? Data(contentsOf: storeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlists = json["playlists"] as? [[String: Any]],
              let playlist = playlists.first,
              let savedTracks = playlist["tracks"] as? [[String: Any]] else {
            XCTFail("Failed to load saved playlists")
            return
        }

        let signaturesPresent = savedTracks.compactMap { $0["signature"] }.count
        XCTAssertEqual(signaturesPresent, 2, "M3U8 tracks should have persisted signatures")
    }

    func testCoordinatorGloballyBoundsMultipleBatchesAndChunks() async throws {
        await counter.pause()
        let service = SignatureCaptureService(counter: counter)
        let coordinator = SignatureCaptureCoordinator(
            service: service,
            maximumChunkSize: 2,
            maximumAdmittedBatches: 4
        )
        let batches = (0..<3).map { batchIndex in
            makeCaptureBatch(prefix: "bounded-\(batchIndex)", count: 6)
        }

        var tasks: [Task<SignatureCaptureResult, Never>] = []
        for batch in batches {
            let submitted = await coordinator.submitBatch(batch)
            tasks.append(try XCTUnwrap(submitted))
        }

        await counter.waitForCaptureCount(2)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let capturesWhilePaused = await counter.captureCount()
        let running = await coordinator.diagnostics()
        XCTAssertEqual(capturesWhilePaused, 2)
        XCTAssertEqual(running.activeCaptureCount, 2)
        XCTAssertEqual(running.peakActiveCaptureCount, 2)
        XCTAssertEqual(running.activeChunkCount, 2)
        XCTAssertGreaterThan(running.pendingChunkCount, 0)
        XCTAssertLessThanOrEqual(running.largestScheduledChunkSize, 2)

        await counter.resume()
        for (batch, task) in zip(batches, tasks) {
            let result = await task.value
            XCTAssertEqual(result.batchID, batch.id)
            XCTAssertEqual(result.entries.count, batch.targets.count)
            await coordinator.finishBatch(batch.id)
        }

        let completed = await coordinator.diagnostics()
        XCTAssertEqual(completed.activeCaptureCount, 0)
        XCTAssertEqual(completed.activeChunkCount, 0)
        XCTAssertEqual(completed.pendingCaptureCount, 0)
        XCTAssertEqual(completed.pendingChunkCount, 0)
        XCTAssertEqual(completed.admittedBatchCount, 0)
        XCTAssertEqual(completed.peakActiveCaptureCount, 2)
    }

    func testCoordinatorFairnessLetsSmallBatchJoinLargeBatchPromptly() async throws {
        await counter.pause()
        let service = SignatureCaptureService(counter: counter)
        let coordinator = SignatureCaptureCoordinator(
            service: service,
            maximumChunkSize: 1,
            maximumAdmittedBatches: 4
        )
        let largeBatch = makeCaptureBatch(prefix: "fair-large", count: 8)
        let smallBatch = makeCaptureBatch(prefix: "fair-small", count: 2)

        let largeSubmission = await coordinator.submitBatch(largeBatch)
        let largeTask = try XCTUnwrap(largeSubmission)
        await counter.waitForCaptureCount(2)
        let smallSubmission = await coordinator.submitBatch(smallBatch)
        let smallTask = try XCTUnwrap(smallSubmission)

        await counter.resume()
        let largeResult = await largeTask.value
        let smallResult = await smallTask.value
        await coordinator.finishBatch(largeBatch.id)
        await coordinator.finishBatch(smallBatch.id)

        XCTAssertEqual(largeResult.entries.count, 8)
        XCTAssertEqual(smallResult.entries.count, 2)
        let captureOrder = await counter.capturedPaths
        let firstSmallIndex = captureOrder.firstIndex { $0.contains("fair-small") }
        XCTAssertNotNil(firstSmallIndex)
        let unwrappedFirstSmallIndex = try XCTUnwrap(firstSmallIndex)
        XCTAssertLessThanOrEqual(
            unwrappedFirstSmallIndex,
            3,
            "A small later batch should receive one of the next released global slots"
        )
    }

    func testCoordinatorRetainsCrossBatchPathInFlightDeduplication() async throws {
        await counter.pause()
        let service = SignatureCaptureService(counter: counter)
        let coordinator = SignatureCaptureCoordinator(
            service: service,
            maximumChunkSize: 1
        )
        let sharedPath = tempDir.appendingPathComponent("shared-missing.wav").path
        let firstBatch = makeCaptureBatch(paths: [sharedPath])
        let secondBatch = makeCaptureBatch(paths: [sharedPath])

        let firstSubmission = await coordinator.submitBatch(firstBatch)
        let firstTask = try XCTUnwrap(firstSubmission)
        let secondSubmission = await coordinator.submitBatch(secondBatch)
        let secondTask = try XCTUnwrap(secondSubmission)
        await counter.waitForCaptureCount(1)
        try? await Task.sleep(nanoseconds: 30_000_000)

        let capturesWhilePaused = await counter.captureCount()
        let diagnostics = await coordinator.diagnostics()
        XCTAssertEqual(capturesWhilePaused, 1)
        XCTAssertEqual(diagnostics.activeCaptureCount, 1)
        XCTAssertEqual(diagnostics.activeChunkCount, 2)

        await counter.resume()
        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        XCTAssertEqual(firstResult.entries.count, 1)
        XCTAssertEqual(secondResult.entries.count, 1)
        await coordinator.finishBatch(firstBatch.id)
        await coordinator.finishBatch(secondBatch.id)
    }

    func testCoordinatorTerminationPromptlyCancelsActiveAndWaitingBatches() async throws {
        await counter.pause()
        let service = SignatureCaptureService(counter: counter)
        let coordinator = SignatureCaptureCoordinator(
            service: service,
            maximumChunkSize: 1,
            maximumAdmittedBatches: 1
        )
        let activeBatch = makeCaptureBatch(prefix: "terminate-active", count: 4)
        let waitingBatch = makeCaptureBatch(prefix: "terminate-waiting", count: 2)

        let activeSubmission = await coordinator.submitBatch(activeBatch)
        let activeTask = try XCTUnwrap(activeSubmission)
        await counter.waitForCaptureCount(2)
        let waitingSubmission = Task {
            await coordinator.submitBatch(waitingBatch)
        }
        let didQueueWaitingSubmission = await waitUntilAsync {
            (await coordinator.diagnostics()).waitingSubmissionCount == 1
        }
        XCTAssertTrue(didQueueWaitingSubmission)

        let startedAt = Date()
        await coordinator.cancelForTermination()
        let cancellationDuration = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(cancellationDuration, 0.2)

        let activeResult = await activeTask.value
        let rejectedWaitingTask = await waitingSubmission.value
        XCTAssertTrue(activeResult.entries.isEmpty)
        XCTAssertNil(rejectedWaitingTask)
        let terminated = await coordinator.diagnostics()
        XCTAssertEqual(terminated.activeCaptureCount, 0)
        XCTAssertEqual(terminated.pendingCaptureCount, 0)
        XCTAssertEqual(terminated.activeChunkCount, 0)
        XCTAssertEqual(terminated.pendingChunkCount, 0)
        XCTAssertEqual(terminated.admittedBatchCount, 0)
        XCTAssertEqual(terminated.waitingSubmissionCount, 0)
        let hasActiveBatches = await coordinator.hasActiveBatches()
        XCTAssertFalse(hasActiveBatches)

        // Release the deliberately paused test hook; late filesystem results are
        // detached and cannot repopulate the terminated coordinator.
        await counter.resume()
        await coordinator.finishBatch(activeBatch.id)
    }

    private func makeCaptureBatch(prefix: String, count: Int) -> SignatureCaptureBatch {
        let paths = (0..<count).map { index in
            tempDir.appendingPathComponent("\(prefix)-\(index).wav").path
        }
        return makeCaptureBatch(paths: paths)
    }

    private func makeCaptureBatch(paths: [String]) -> SignatureCaptureBatch {
        let playlistID = UUID()
        return SignatureCaptureBatch(targets: paths.enumerated().map { index, path in
            SignatureCaptureTarget(
                playlistID: playlistID,
                trackID: UUID(),
                expectedPath: path,
                generation: UInt64(index + 1)
            )
        })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
