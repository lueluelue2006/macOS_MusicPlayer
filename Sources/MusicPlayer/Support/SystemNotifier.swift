import Foundation
import UserNotifications

final class SystemNotifier {
    static let shared = SystemNotifier()
    private init() {}

    private var didRequest = false

    private var notificationsAvailable: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private func ensureAuthorization() {
        guard notificationsAvailable else { return }
        guard !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyDeviceChanged(to name: String, silent: Bool = true) {
        guard notificationsAvailable else { return }
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "输出设备已切换"
        content.body = "已切换到：\(name)"
        if !silent {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: "deviceChanged.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
