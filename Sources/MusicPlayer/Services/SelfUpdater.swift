import Foundation
import AppKit

actor SelfUpdater {
    static let shared = SelfUpdater()
    private init() {}

    enum UpdateError: LocalizedError {
        case alreadyRunning
        case missingAsset
        case downloadFailed
        case cannotWriteTemp
        case cannotLaunchInstaller

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "更新任务已在进行中"
            case .missingAsset: return "未找到可下载的安装包"
            case .downloadFailed: return "下载更新失败"
            case .cannotWriteTemp: return "无法写入临时目录"
            case .cannotLaunchInstaller: return "无法启动安装器"
            }
        }
    }

    private var isUpdating: Bool = false

    func startUpdateIfPossible(info: UpdateChecker.UpdateInfo) async throws {
        guard !isUpdating else { throw UpdateError.alreadyRunning }
        guard let assetURL = info.assetURL, let assetName = info.assetName else { throw UpdateError.missingAsset }

        isUpdating = true
        defer { isUpdating = false }

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("macOS_MusicPlayer_Update", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.cannotWriteTemp
        }

        // 1) Download DMG
        let dmgURL = base.appendingPathComponent(assetName)
        do {
            if fm.fileExists(atPath: dmgURL.path) {
                try fm.removeItem(at: dmgURL)
            }
        } catch {
            // ignore
        }

        do {
            let (tmp, _) = try await URLSession.shared.download(from: assetURL)
            try fm.moveItem(at: tmp, to: dmgURL)
        } catch {
            throw UpdateError.downloadFailed
        }

        // 2) Write installer script
        let scriptURL = base.appendingPathComponent("install_and_relaunch.sh")
        let script = Self.makeInstallerScript()
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw UpdateError.cannotWriteTemp
        }

        // 3) Spawn detached installer then quit app
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path, dmgURL.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            throw UpdateError.cannotLaunchInstaller
        }

        await MainActor.run {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func makeInstallerScript() -> String {
        // Notes:
        // - Wait for current app to exit to avoid copying over a running bundle.
        // - Move the old app to Trash for safety (avoid cluttering /Applications).
        // - Remove quarantine + adhoc sign to reduce first-run friction.
        return """
        #!/bin/bash
        set -euo pipefail

        DMG_PATH="${1:-}"
        if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
          exit 2
        fi

        APP_NAME="MusicPlayer.app"
        TARGET_APP="/Applications/$APP_NAME"

        # Wait for app to quit (max 60s)
        for i in $(seq 1 120); do
          if pgrep -x "MusicPlayer" >/dev/null 2>&1; then
            sleep 0.5
          else
            break
          fi
        done

        TS=$(date +%Y%m%d_%H%M%S)
        MOUNT_DIR="$(mktemp -d "/tmp/macos_musicplayer_update_mount.XXXXXX")"
        TRASH_DIR="${HOME}/.Trash"

        cleanup() {
          /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
          rm -rf "$MOUNT_DIR" >/dev/null 2>&1 || true
        }
        trap cleanup EXIT

        /usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet

        SRC_APP="$(/usr/bin/find "$MOUNT_DIR" -maxdepth 2 -name "$APP_NAME" -print -quit || true)"
        if [[ -z "$SRC_APP" || ! -d "$SRC_APP" ]]; then
          exit 3
        fi

        if [[ -d "$TARGET_APP" ]]; then
          mkdir -p "$TRASH_DIR" >/dev/null 2>&1 || true
          DEST_IN_TRASH="$TRASH_DIR/MusicPlayer-old-$TS.app"
          if [[ -e "$DEST_IN_TRASH" ]]; then
            n=2
            while [[ -e "$TRASH_DIR/MusicPlayer-old-$TS ($n).app" ]]; do
              n=$((n+1))
            done
            DEST_IN_TRASH="$TRASH_DIR/MusicPlayer-old-$TS ($n).app"
          fi

          if ! mv "$TARGET_APP" "$DEST_IN_TRASH" >/dev/null 2>&1; then
            # As a last resort, move to /tmp to avoid corrupting the install by copying into an existing bundle.
            if ! mv "$TARGET_APP" "/tmp/MusicPlayer-old-$TS.app" >/dev/null 2>&1; then
              exit 4
            fi
          fi
        fi

        /usr/bin/ditto "$SRC_APP" "$TARGET_APP"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
        /usr/bin/codesign --force --deep --sign - "$TARGET_APP" >/dev/null 2>&1 || true

        /usr/bin/open -a "$TARGET_APP"
        """
    }
}
