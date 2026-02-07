import Foundation
import AppKit

actor SelfUpdater {
    static let shared = SelfUpdater()
    private init() {}

    enum UpdateError: LocalizedError {
        case alreadyRunning
        case missingAsset
        case downloadFailed
        case checksumFileMissing
        case checksumParseFailed
        case checksumMismatch
        case cannotWriteTemp
        case cannotLaunchInstaller

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "更新任务已在进行中"
            case .missingAsset: return "未找到可下载的安装包"
            case .downloadFailed: return "下载更新失败"
            case .checksumFileMissing: return "未找到 SHA256 校验文件"
            case .checksumParseFailed: return "SHA256 校验文件格式无效"
            case .checksumMismatch: return "安装包 SHA256 校验失败"
            case .cannotWriteTemp: return "无法写入临时目录"
            case .cannotLaunchInstaller: return "无法启动安装器"
            }
        }
    }

    private var isUpdating: Bool = false

    func startUpdateIfPossible(info: UpdateChecker.UpdateInfo) async throws {
        guard !isUpdating else { throw UpdateError.alreadyRunning }
        guard let assetURL = info.assetURL, let assetName = info.assetName else { throw UpdateError.missingAsset }
        guard let checksumURL = info.checksumAssetURL else { throw UpdateError.checksumFileMissing }

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

        let checksumText: String
        do {
            let (data, _) = try await URLSession.shared.data(from: checksumURL)
            guard let parsed = String(data: data, encoding: .utf8), !parsed.isEmpty else {
                throw UpdateError.checksumParseFailed
            }
            checksumText = parsed
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.downloadFailed
        }

        let expectedHash = parseExpectedSHA256(for: assetName, from: checksumText)
        guard let expectedHash else {
            throw UpdateError.checksumParseFailed
        }

        let actualHash = sha256Hex(of: dmgURL)
        guard let actualHash, actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw UpdateError.checksumMismatch
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
        // - Keep a temporary backup during installation and rollback on failure.
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
        NEW_APP="/Applications/${APP_NAME}.new-$TS"
        BACKUP_APP="/Applications/${APP_NAME}.backup-$TS"
        INSTALL_OK="0"

        cleanup() {
          /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
          rm -rf "$MOUNT_DIR" >/dev/null 2>&1 || true
          if [[ "$INSTALL_OK" != "1" && -d "$BACKUP_APP" ]]; then
            rm -rf "$TARGET_APP" >/dev/null 2>&1 || true
            mv "$BACKUP_APP" "$TARGET_APP" >/dev/null 2>&1 || true
          fi
          rm -rf "$NEW_APP" >/dev/null 2>&1 || true
          if [[ "$INSTALL_OK" == "1" ]]; then
            rm -rf "$BACKUP_APP" >/dev/null 2>&1 || true
          fi
        }
        trap cleanup EXIT

        /usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet

        SRC_APP="$(/usr/bin/find "$MOUNT_DIR" -maxdepth 2 -name "$APP_NAME" -print -quit || true)"
        if [[ -z "$SRC_APP" || ! -d "$SRC_APP" ]]; then
          exit 3
        fi

        # Stage new bundle in /Applications for an atomic rename swap.
        rm -rf "$NEW_APP" >/dev/null 2>&1 || true
        /usr/bin/ditto "$SRC_APP" "$NEW_APP"
        /usr/bin/xattr -dr com.apple.quarantine "$NEW_APP" >/dev/null 2>&1 || true
        /usr/bin/codesign --force --deep --sign - "$NEW_APP" >/dev/null 2>&1 || true

        rm -rf "$BACKUP_APP" >/dev/null 2>&1 || true
        if [[ -d "$TARGET_APP" ]]; then
          mv "$TARGET_APP" "$BACKUP_APP"
        fi
        mv "$NEW_APP" "$TARGET_APP"
        INSTALL_OK="1"

        /usr/bin/open -a "$TARGET_APP"
        """
    }

    private func parseExpectedSHA256(for assetName: String, from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let fields = trimmed
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard fields.count >= 2 else { continue }

            let hash = fields[0]
            let file = fields.last?.trimmingCharacters(in: CharacterSet(charactersIn: "*")) ?? ""
            if file == assetName {
                return hash
            }
        }
        return nil
    }

    private func sha256Hex(of url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else {
            return nil
        }
        return output.split(separator: " ").first.map(String.init)
    }
}
