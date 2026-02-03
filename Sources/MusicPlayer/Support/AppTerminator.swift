import AppKit
import Foundation

enum AppTerminator {
    /// Request app termination in a way that still works when SwiftUI sheets are presented.
    ///
    /// In some modal contexts, calling `NSApp.terminate(nil)` directly can be cancelled because the sheet
    /// remains open. We first broadcast a "dismiss all sheets" notification, then terminate shortly after.
    static func requestQuit() {
        NotificationCenter.default.post(name: .requestDismissAllSheets, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApplication.shared.terminate(nil)
        }
    }
}

