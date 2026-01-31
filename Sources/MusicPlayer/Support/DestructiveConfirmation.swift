import AppKit

enum DestructiveConfirmation {
    /// Returns `true` only when user explicitly confirms.
    /// Note: The default (Return) action is the first button, so put cancel first to prevent mis-clicks.
    @MainActor
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String = "清除",
        cancelTitle: String = "不清除"
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning

        let cancelButton = alert.addButton(withTitle: cancelTitle)
        // Ensure Return triggers "do not clear".
        cancelButton.keyEquivalent = "\r"
        cancelButton.keyEquivalentModifierMask = []

        let confirmButton = alert.addButton(withTitle: confirmTitle)
        // Prevent Escape mapping to the destructive action.
        confirmButton.keyEquivalent = ""
        confirmButton.keyEquivalentModifierMask = []

        return alert.runModal() == .alertSecondButtonReturn
    }
}

