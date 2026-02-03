import AppKit

enum TextInputPrompt {
    /// Returns trimmed string if user confirms, otherwise `nil`.
    @MainActor
    static func prompt(
        title: String,
        message: String,
        defaultValue: String = "",
        okTitle: String = "确定",
        cancelTitle: String = "取消"
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational

        let input = NSTextField(string: defaultValue)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input

        let cancelButton = alert.addButton(withTitle: cancelTitle)
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.keyEquivalentModifierMask = []

        let okButton = alert.addButton(withTitle: okTitle)
        okButton.keyEquivalent = "\r" // Return
        okButton.keyEquivalentModifierMask = []

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

