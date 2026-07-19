import AppKit
import Foundation

enum AppTerminator {
    private static var hasRequestedQuit = false

    /// Request app termination in a way that still works when SwiftUI sheets are presented.
    static func requestQuit() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                requestQuit()
            }
            return
        }

        guard !hasRequestedQuit else { return }
        hasRequestedQuit = true

        NotificationCenter.default.post(name: .requestDismissAllSheets, object: nil)

        // End synchronous NSAlert/NSOpenPanel modal sessions before terminating.
        // SwiftUI sheets consume the notification above during this run-loop turn.
        if NSApplication.shared.modalWindow != nil {
            NSApplication.shared.abortModal()
        }

        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}
