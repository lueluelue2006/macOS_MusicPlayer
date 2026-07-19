import Foundation
import OSLog

enum PersistenceLogger {
    private static let logger = Logger(
        subsystem: "io.github.lueluelue2006.macosmusicplayer",
        category: "Persistence"
    )

    static func log(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[Persistence] \(message())")
#else
        let privateMessage = message()
        logger.error(
            "Persistence event: \(privateMessage, privacy: .private(mask: .hash))"
        )
#endif
    }

    static func notifyUser(title: String, subtitle: String) {
        NotificationCenter.default.post(
            name: .showAppToast,
            object: nil,
            userInfo: [
                "title": title,
                "subtitle": subtitle,
                "kind": "warning",
                "duration": 3.5
            ]
        )
    }
}
