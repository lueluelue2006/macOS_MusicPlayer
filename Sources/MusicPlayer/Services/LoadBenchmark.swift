import Foundation
import AVFoundation
import AppKit

enum LoadBenchmark {
    struct FileResult: Codable {
        let path: String
        let fileName: String

        let hasSidecarLRC: Bool
        let lyricsFound: Bool
        let lyricsColdMs: Double?
        let lyricsWarmMs: Double?
        let lyricsSource: String?

        let artworkFound: Bool
        let artworkFetchMs: Double?
        let artworkDecodeColdMs: Double?
        let artworkDecodeWarmMs: Double?
        let artworkBytes: Int?
    }

    struct Summary: Codable {
        let totalFiles: Int
        let testedLyricsFiles: Int
        let testedArtworkFiles: Int

        let lyricsColdAvgMs: Double?
        let lyricsWarmAvgMs: Double?
        let artworkDecodeColdAvgMs: Double?
        let artworkDecodeWarmAvgMs: Double?
        let artworkFetchAvgMs: Double?
    }

    struct Report: Codable {
        let version: Int
        let startedAt: Date
        let folder: String
        let limit: Int
        let results: [FileResult]
        let summary: Summary
    }

    static func run(folderURL: URL, limit: Int) async -> Report {
        let files = collectAudioFiles(in: folderURL, limit: limit)

        var results: [FileResult] = []
        results.reserveCapacity(files.count)

        var lyricsColdSamples: [Double] = []
        var lyricsWarmSamples: [Double] = []
        var artworkDecodeColdSamples: [Double] = []
        var artworkDecodeWarmSamples: [Double] = []
        var artworkFetchSamples: [Double] = []

        for url in files {
            let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
            let hasSidecarLRC = FileManager.default.fileExists(atPath: lrcURL.path)

            var lyricsFound = false
            var lyricsSource: String? = nil
            var lyricsColdMs: Double? = nil
            var lyricsWarmMs: Double? = nil

            await LyricsService.shared.invalidate(for: url)

            let (first, coldMs) = await measureMs {
                await LyricsService.shared.loadLyrics(for: url)
            }
            lyricsColdMs = coldMs

            if case .success(let timeline) = first {
                lyricsFound = true
                lyricsSource = sourceLabel(for: timeline.source)

                let (_, warmMs) = await measureMs {
                    await LyricsService.shared.loadLyrics(for: url)
                }
                lyricsWarmMs = warmMs

                lyricsColdSamples.append(coldMs)
                lyricsWarmSamples.append(warmMs)
            }

            // Clean up to keep memory usage low after the benchmark.
            await LyricsService.shared.invalidate(for: url)

            // Artwork: measure fetch + decode/resize. Decode must run on main thread (AppKit).
            let (artworkData, fetchMs) = await measureMs {
                await fetchArtworkData(for: url)
            }

            var artworkFound = false
            var artworkFetchMs: Double? = nil
            var artworkDecodeColdMs: Double? = nil
            var artworkDecodeWarmMs: Double? = nil
            var artworkBytes: Int? = nil

            if let artworkData {
                artworkFound = true
                artworkFetchMs = fetchMs
                artworkBytes = artworkData.count
                artworkFetchSamples.append(fetchMs)

                let key = url.path
                let targetSize = CGSize(width: 220, height: 220)

                // Ensure cold decode by clearing the image cache first.
                await MainActor.run {
                    ArtworkCache.shared.clear()
                }

                let coldMs = await MainActor.run {
                    measureMsSync {
                        _ = ArtworkCache.shared.image(for: key, data: artworkData, targetSize: targetSize)
                    }
                }
                artworkDecodeColdMs = coldMs

                let warmMs = await MainActor.run {
                    measureMsSync {
                        _ = ArtworkCache.shared.image(for: key, data: artworkData, targetSize: targetSize)
                    }
                }
                artworkDecodeWarmMs = warmMs

                // Clean up: leave caches empty after bench.
                await MainActor.run {
                    ArtworkCache.shared.clear()
                }

                artworkDecodeColdSamples.append(coldMs)
                artworkDecodeWarmSamples.append(warmMs)
            }

            results.append(
                FileResult(
                    path: url.path,
                    fileName: url.lastPathComponent,
                    hasSidecarLRC: hasSidecarLRC,
                    lyricsFound: lyricsFound,
                    lyricsColdMs: lyricsColdMs,
                    lyricsWarmMs: lyricsWarmMs,
                    lyricsSource: lyricsSource,
                    artworkFound: artworkFound,
                    artworkFetchMs: artworkFetchMs,
                    artworkDecodeColdMs: artworkDecodeColdMs,
                    artworkDecodeWarmMs: artworkDecodeWarmMs,
                    artworkBytes: artworkBytes
                )
            )
        }

        func avg(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            return xs.reduce(0, +) / Double(xs.count)
        }

        let summary = Summary(
            totalFiles: results.count,
            testedLyricsFiles: lyricsColdSamples.count,
            testedArtworkFiles: artworkDecodeColdSamples.count,
            lyricsColdAvgMs: avg(lyricsColdSamples),
            lyricsWarmAvgMs: avg(lyricsWarmSamples),
            artworkDecodeColdAvgMs: avg(artworkDecodeColdSamples),
            artworkDecodeWarmAvgMs: avg(artworkDecodeWarmSamples),
            artworkFetchAvgMs: avg(artworkFetchSamples)
        )

        return Report(
            version: 1,
            startedAt: Date(),
            folder: folderURL.path,
            limit: limit,
            results: results,
            summary: summary
        )
    }

    static func writeReport(_ report: Report, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    static func defaultReportURL() -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "musicplayer_bench_\(formatter.string(from: Date())).json"
        return tmp.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - Internals

    private static func collectAudioFiles(in folder: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        let allowed = Set([
            "mp3", "m4a", "aac",
            "wav", "aif", "aiff", "aifc", "caf",
            "flac", "ogg", "opus"
        ])

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if limit > 0, results.count >= limit { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isDirectory == true { continue }
            let ext = url.pathExtension.lowercased()
            if allowed.contains(ext) {
                results.append(url)
            }
        }
        return results
    }

    private static func sourceLabel(for source: LyricsSource) -> String {
        switch source {
        case .embeddedUnsynced: return "embedded_unsynced"
        case .embeddedSynced: return "embedded_synced"
        case .sidecarLRC: return "sidecar_lrc"
        case .manual: return "manual"
        }
    }

    private static func measureMs<T>(_ work: () async -> T) async -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await work()
        let end = DispatchTime.now().uptimeNanoseconds
        let ms = Double(end - start) / 1_000_000.0
        return (value, ms)
    }

    private static func measureMsSync(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }

    private static func fetchArtworkData(for url: URL) async -> Data? {
        do {
            return try await AsyncTimeout.withTimeout(10) {
                let asset = AVURLAsset(url: url)
                let items = try await asset.load(.commonMetadata)
                for item in items {
                    if item.commonKey?.rawValue.lowercased() == "artwork" {
                        if #available(macOS 13.0, *) {
                            if let data = try? await item.load(.dataValue) { return data }
                        } else {
                            if let data = item.dataValue { return data }
                        }
                    }
                }
                return nil
            }
        } catch {
            return nil
        }
    }
}
