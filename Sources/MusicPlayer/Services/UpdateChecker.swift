import Foundation

actor UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    struct UpdateInfo: Sendable {
        let currentVersion: String
        let latestVersion: String
        let releaseURL: URL
    }

    enum CheckOutcome: Sendable {
        case upToDate(currentVersion: String, latestVersion: String, releaseURL: URL)
        case updateAvailable(UpdateInfo)
        case failed(message: String, releaseURL: URL)
    }

    private struct GitHubLatestRelease: Decodable {
        let tagName: String
        let htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    func check(currentVersion: String) async -> CheckOutcome {
        let releasesURL = URL(string: "https://github.com/lueluelue2006/macOS_MusicPlayer/releases")!
        guard let current = Version.parse(currentVersion) else {
            return .failed(message: "当前版本号无效", releaseURL: releasesURL)
        }

        do {
            let latestRelease = try await fetchLatestRelease()
            let latestVersionString = latestRelease.tagName.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("v")
            guard let latest = Version.parse(latestVersionString) else {
                return .failed(message: "版本信息解析失败", releaseURL: releasesURL)
            }

            if latest > current {
                return .updateAvailable(UpdateInfo(
                    currentVersion: currentVersion,
                    latestVersion: latestVersionString,
                    releaseURL: releasesURL
                ))
            }

            return .upToDate(
                currentVersion: currentVersion,
                latestVersion: latestVersionString,
                releaseURL: releasesURL
            )
        } catch {
            return .failed(message: "检查更新失败", releaseURL: releasesURL)
        }
    }

    private func fetchLatestRelease() async throws -> GitHubLatestRelease {
        let api = URL(string: "https://api.github.com/repos/lueluelue2006/macOS_MusicPlayer/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("macOS_MusicPlayer/UpdateChecker", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
    }
}

private struct Version: Comparable, Sendable {
    let components: [Int]

    static func parse(_ raw: String) -> Version? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Accept: "3.1", "v3.1", "3.1.0", "3.1-beta" (will parse leading numeric parts).
        let normalized = trimmed.trimmingPrefix("v")
        let parts = normalized
            .split(whereSeparator: { !($0.isNumber || $0 == ".") })
            .first?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []

        guard !parts.isEmpty else { return nil }
        return Version(components: parts)
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxCount {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
