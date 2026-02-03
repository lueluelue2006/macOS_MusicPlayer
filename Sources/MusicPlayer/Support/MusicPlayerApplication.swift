import AppKit

/// Intercepts global key equivalents at the very top of the event pipeline.
///
/// Rationale:
/// - In some modal contexts (e.g. SwiftUI `.sheet` on macOS), `Cmd+Q` can be swallowed by the key window
///   before it reaches the app menu/commands system.
/// - Users expect `Cmd+Q` to *always* quit the app, regardless of focus or modal sheets.
@objc(MusicPlayerApplication)
final class MusicPlayerApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command),
               !flags.contains(.control),
               !flags.contains(.option),
               !flags.contains(.shift),
               (event.charactersIgnoringModifiers?.lowercased() == "q" || event.keyCode == 12) {
                AppTerminator.requestQuit()
                return
            }
        }
        super.sendEvent(event)
    }
}
