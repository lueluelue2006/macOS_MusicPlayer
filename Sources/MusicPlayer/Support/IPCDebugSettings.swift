import Foundation

enum IPCDebugSettings {
    static let userDefaultsKey = "ipcDebugEnabled"

    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
        NotificationCenter.default.post(
            name: .ipcDebugModeDidChange,
            object: nil,
            userInfo: ["enabled": enabled]
        )
    }
}
