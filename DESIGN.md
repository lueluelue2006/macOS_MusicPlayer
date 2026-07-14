# MusicPlayer 4.3.8 Design System

## Mode

Greenfield. The 4.1 visual direction is retired rather than incrementally
polished.

## Design Direction

**Concept — Listening Room:** a tactile, album-first listening stage beside a
quiet, highly scannable music library. The current record supplies the emotion;
the queue supplies precision.

**Keywords:** album-first, editorial, tactile, native, calm, dense, high-contrast.

**Avoid:** blank placeholder art, giant import banners, pill-shaped control
clusters, stacked cards, rainbow status colors, decorative glass, border-heavy
regions, and perpetual animation.

## Composition

- Wide windows use one strong asymmetric composition: a 410–500 point dark
  listening stage and a flexible library in dark mode; light mode translates
  the same composition onto one continuous matte warm-gray plane.
- Dark mode uses a restrained wine-red cast on the library. Light mode uses dark
  labels and low-luminance warm grays so reflective displays remain readable.
- Album artwork is the dominant object. When metadata has no artwork, render a
  designed record sleeve using the track title rather than an empty gray box.
- Import, refresh, clear, scan, normalization, playback rate, and random weight
  are supporting tools. They must not compete with artwork, title, transport,
  search, or the queue.
- In low-height windows, the listening stage scrolls, but artwork, track title,
  progress, and transport appear before every advanced control and lyrics.

## System Decisions

### Color

- Brand accent: a single restrained coral-red family used for play state,
  selection, focus, and primary actions. Small active controls use a darker
  burgundy value in light appearance to preserve contrast on warm gray.
- Dark appearance: deep graphite player plus a low-saturation wine-to-graphite
  library, both with cool-white labels.
- Light appearance: muted rose-gray player and warm-gray library with dark
  labels; avoid pure white to limit glare.
- Warning and destructive colors remain semantic system colors.
- Random-weight controls use muted text for the default and the existing accent
  for an override; levels do not introduce additional semantic colors.

### Typography

- Use the macOS system font only.
- Now-playing title: 24–28 pt semibold with tight leading.
- Library title: 26 pt bold; track title: 13 pt semibold; secondary metadata:
  11–12 pt regular.
- Use uppercase micro-labels sparingly for orientation, with modest tracking.
- Durations use monospaced digits.

### Spacing and Shape

- Spacing scale: 4, 8, 12, 16, 24, 32 points.
- Artwork radius: 20 points. Search radius: 10 points. Row hover radius: 8
  points. Avoid capsules except for genuinely compact status.
- Queue rows are flat and separated through rhythm and a faint divider. The
  active row uses a narrow accent rail and a low-opacity fill, never a border.
- Only artwork receives a large shadow. Routine regions and rows do not.

### Motion

- Hover/color response: 140–180 ms.
- Layout or content transition: critically damped spring around 240–300 ms.
- Press feedback is immediate and small. No bounce without gesture momentum.
- Respect Reduce Motion and never run decorative animation continuously.

## Key Components

- **Now Playing:** orientation header, 280–320 point artwork/sleeve, left-aligned
  title metadata, progress, one coherent transport row, then quiet utilities.
- **Transport:** a single 76-point two-state `Toggle` switches between shuffle
  and single-track repeat, and one mode is always selected. Its full track is
  one hit target; every click flips the mode while a critically damped thumb
  slides to the other icon. Reduce Motion changes state without horizontal
  movement. Previous, play/pause, and next stay centered between the toggle and
  a matching 76-point immersive slot. Only play/pause is solid; the toggle uses
  the interactive accent in both appearances. Immersive playback remains a
  compact infinity `Toggle` with native help and accessibility state.
- **Queue toolbar:** title/count and text tabs on the left; one import action and
  quiet icon tools on the right. Destructive and infrequent actions live in an
  overflow menu.
- **Search:** one native-looking search surface with a visible focus state.
- **Track row:** glyph/equalizer, two lines of metadata, optional analyzed state,
  a permanently visible six-block random-weight picker, duration, and
  hover/context actions. The title/metadata region is the playback button; the
  weight buttons are independent controls, and the picker padding, inter-button
  gaps, and duration region never trigger playback.
- **Random weight:** the same six visible square buttons appear in the
  now-playing utility row and every track row, mapping to 0.5×, 1.0×, 1.6×,
  3.2×, 4.8×, and 6.4×. They never collapse into a text menu. The second level
  (1.0×) is the default. Context menus use human ordinals such as “第 2 档 ·
  1.0×”; the CLI/API retains raw levels 0–5.
- **Lyrics:** absent when no lyrics exist; otherwise a flat continuation of the
  listening stage, not another card. In synced lyrics, interactive accent red
  exclusively means auto-follow is enabled, muted gray means disabled, and
  “locate current line” remains a neutral action rather than pretending to be a
  selected state.

## SwiftUI and Performance Rules

- Keep SwiftUI, AppKit, AVFoundation, CoreAudio, and SF Symbols; add no UI or
  animation dependency.
- Preserve lazy row creation and stable path-based identity.
- Keep the six weight buttons lightweight and instantiate them only with their
  virtualized track row; selecting a level performs no file I/O on the UI path.
- No blur, file I/O, sorting, path normalization, large shadow, or artwork
  decoding inside queue rows.
- Keep current-artwork ImageIO downsampling and the bounded playlist workers.
- Immersive playback v3 analyzes only the current and preloaded-next tracks,
  using bounded head and tail windows, per-track adaptive relative tail
  loudness, sustained-window evidence, and fade-shape confidence. Isolated
  noise after established silence cannot extend the boundary, while sustained
  quiet outros fall back to the lower protection gate. Results are cached
  instead of triggering a default whole-library scan; music files are never
  rewritten, low-confidence analysis falls back to the full track, and
  playback does not promise sample-accurate gapless transitions.
- Full-track normalization analysis stays on one serial `.utility` lane. Auto
  analysis starts only after 60 seconds of system-wide idle time, handles at
  most two tracks per batch, and stops for playback, input, Low Power Mode, or
  any thermal state above nominal. Its signed cache is bounded to 5,000 entries
  and roughly 8 MiB; no decoded PCM is retained.
- Queue snapshots are captured only when a 400 ms latest-state debounce drains,
  then use atomic replacement; loudness-cache saves are coalesced, and queue,
  loudness, and immersive-boundary stores flush at application termination.
- Use native `Button`, `Menu`, `Slider`, `Toggle`, `TextField`, and scroll
  semantics so keyboard and accessibility behavior survive the redesign.
- The root owns lifecycle, notifications, alerts, sheets, drops, and updates;
  visual containers do not duplicate service ownership.

## Self-Critique

1. The two appearances must feel related without sharing the same luminance.
   Preserve the composition, coral state color, typography, and one clean
   divider while translating backgrounds and label contrast for each mode.
2. Artwork-free libraries are common, so the fallback sleeve must be a real
   composition. A gray note placeholder would collapse the entire direction.
3. Hiding advanced functions can damage discoverability. Keep them in stable
   menus with clear labels, help text, context menus, and existing shortcuts.
4. The compact player can become another stack of tiny controls. Preserve large
   artwork, one dominant play button, and generous separation between core and
   utility controls.
5. Screenshot quality is not enough: verify light/dark, narrow/wide, long title,
   no artwork, hover actions, keyboard focus, 279-track scrolling, and Reduced
   Motion before delivery.
