import Foundation
import CoreServices
import UniformTypeIdentifiers

enum DefaultAudioFileAssociations {
    struct Target: Hashable {
        let contentTypeIdentifier: String
        let label: String
    }

    struct Result: Hashable {
        let total: Int
        let changed: Int
        let alreadyDefault: Int
        let failed: [Target]
    }

    /// Content types we can actually open via `AVAudioPlayer` on macOS 13+.
    /// Note: OGG/Opus are intentionally excluded (not supported by `AVAudioPlayer`).
    static let supportedTargets: [Target] = [
        Target(contentTypeIdentifier: "public.mp3", label: "MP3 (.mp3)"),
        Target(contentTypeIdentifier: UTType(filenameExtension: "m4a")?.identifier ?? "com.apple.m4a-audio", label: "M4A (.m4a)"),
        Target(contentTypeIdentifier: "public.mpeg-4-audio", label: "MPEG-4 Audio (.m4a/.mp4)"),
        Target(contentTypeIdentifier: "public.aac-audio", label: "AAC (.aac)"),
        Target(contentTypeIdentifier: "com.microsoft.waveform-audio", label: "WAV (.wav)"),
        Target(contentTypeIdentifier: "public.aiff-audio", label: "AIFF (.aif/.aiff)"),
        Target(contentTypeIdentifier: "public.aifc-audio", label: "AIFC (.aifc)"),
        Target(contentTypeIdentifier: "com.apple.coreaudio-format", label: "CAF (.caf)"),
        Target(contentTypeIdentifier: UTType(filenameExtension: "flac")?.identifier ?? "org.xiph.flac", label: "FLAC (.flac)"),
    ]

    static func setAsDefaultViewerForSupportedAudio(
        bundleID: String? = Bundle.main.bundleIdentifier,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Result {
        guard let bundleID, !bundleID.isEmpty else {
            return Result(total: supportedTargets.count, changed: 0, alreadyDefault: 0, failed: supportedTargets)
        }

        // Best-effort: ensure LaunchServices knows about this app.
        LSRegisterURL(bundleURL as CFURL, true)

        var changed = 0
        var already = 0
        var failed: [Target] = []

        // Use `.all` so double-click ("open") uses this app, not only "viewer" role.
        let role: LSRolesMask = .all

        for target in supportedTargets {
            let current = LSCopyDefaultRoleHandlerForContentType(
                target.contentTypeIdentifier as CFString,
                role
            )?.takeRetainedValue() as String?

            if current == bundleID {
                already += 1
                continue
            }

            let status = LSSetDefaultRoleHandlerForContentType(
                target.contentTypeIdentifier as CFString,
                role,
                bundleID as CFString
            )

            if status == noErr {
                changed += 1
            } else {
                failed.append(target)
            }
        }

        return Result(
            total: supportedTargets.count,
            changed: changed,
            alreadyDefault: already,
            failed: failed
        )
    }
}
