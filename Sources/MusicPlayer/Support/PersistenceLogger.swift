import Foundation

enum PersistenceLogger {
    static func log(_ message: String) {
#if DEBUG
        print("[Persistence] \(message)")
#else
        NSLog("[Persistence] %@", message)
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
