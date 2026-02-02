---
audience: LLM / coding agents
purpose: Help an AI agent make safe, correct changes with minimal context.
---

# LLM README (macOS_MusicPlayer)

This file is intended for AI coding assistants (Codex/Cursor/Claude/etc.). It is not end‑user documentation.

## Goals / constraints

- Keep memory usage low (especially artwork/lyrics).
- App is offline-first (no network access in-app).
- Avoid breaking user data/caches.
- Prefer small, reviewable changes; avoid UI regressions.

## Build & run

- Build app: `./build.sh` (outputs `MusicPlayer.app` in the repo root)
- Run app: `open MusicPlayer.app`
- Build CLI: `swift build -c release` (outputs `.build/release/musicplayerctl`)
- Package DMG: `./create_dmg.sh` (outputs `MusicPlayer-v<version>.dmg`)

## CLI (debug / automation)

`musicplayerctl` talks to the running app via `DistributedNotificationCenter`. If you see “no reply”, start the app first.

Common commands:

- `musicplayerctl ping`
- `musicplayerctl status --json`
- `musicplayerctl play <keyword...>` / `musicplayerctl play --index <n>`
- `musicplayerctl seek 2:50`
- `musicplayerctl volume 80%`
- `musicplayerctl rate 1.25` (does not persist across restarts)
- `musicplayerctl normalization on|off|toggle`
- `musicplayerctl add <path> [path...]`
- `musicplayerctl remove --index <n>` / `musicplayerctl remove <keyword...>` (does not delete files)
- `musicplayerctl screenshot --out /tmp/musicplayer.png`
- `musicplayerctl bench <folder> --all` (load benchmark; see CLI help)

## Bundle ID / UserDefaults domain

- Current Bundle ID: `io.github.lueluelue2006.macosmusicplayer`

## Caches / data locations

- AppSupport: `~/Library/Application Support/MusicPlayer`
  - `metadata-cache.json`: disk cache for title/artist/album (invalidates by mtime+size)
  - volume normalization cache files (per track; see code)

## “Where is what” (code map)

- App entry: `Sources/MusicPlayer/MusicPlayerApp.swift`
- Playback:
  - `Sources/MusicPlayer/Services/PlaybackCoordinator.swift` (state machine + next-track preloading)
  - `Sources/MusicPlayer/Services/AudioPlayer.swift` (AVAudioPlayer wrapper; artwork thumbnail is lazy-loaded on play)
- Playlist / loading: `Sources/MusicPlayer/Services/PlaylistManager.swift`
- IPC:
  - Server: `Sources/MusicPlayer/Services/IPCServer.swift`
  - Protocol/types: `Sources/MusicPlayerIPC/IPC.swift`
  - CLI: `Sources/MusicPlayerCLI/main.swift`

## Performance pitfalls (do not regress)

- Do not retain full-resolution artwork `Data` across the playlist; only keep a small thumbnail for the currently playing track.
- Avoid unbounded caches (lyrics/artwork/analysis results) in memory.
- Avoid copying large Sets/Arrays on every render; prefer incremental checks.
