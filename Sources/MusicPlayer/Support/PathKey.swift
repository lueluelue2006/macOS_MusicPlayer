import Foundation

enum PathKey {
    static func canonical(for url: URL) -> String {
        canonical(path: url.standardizedFileURL.path)
    }

    static func canonical(path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
    }

    static func legacy(for url: URL) -> String {
        canonical(for: url).lowercased()
    }

    static func legacy(path: String) -> String {
        canonical(path: path).lowercased()
    }

    static func lookupKeys(for url: URL) -> [String] {
        dedup(primary: canonical(for: url), secondary: legacy(for: url))
    }

    static func lookupKeys(forPath path: String) -> [String] {
        dedup(primary: canonical(path: path), secondary: legacy(path: path))
    }

    private static func dedup(primary: String, secondary: String) -> [String] {
        if primary == secondary {
            return [primary]
        }
        return [primary, secondary]
    }
}
