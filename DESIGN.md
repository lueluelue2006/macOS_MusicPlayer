# MusicPlayer 4.2 Design System

## Mode

Greenfield. The 4.1 visual direction is retired rather than incrementally
polished.

## Design Direction

**Concept — Listening Room:** a tactile, album-first listening stage beside a
quiet, highly scannable music library. The current record supplies the emotion;
the queue supplies precision.

**Keywords:** album-first, editorial, tactile, native, calm, dense, high-contrast.

**Avoid:** blank placeholder art, giant import banners, pill-shaped control
clusters, visible weight controls on every row, stacked cards, rainbow status
colors, decorative glass, border-heavy regions, and perpetual animation.

## Composition

- Wide windows use one strong asymmetric composition: a 410–500 point dark
  listening stage and a flexible appearance-aware library.
- The listening stage remains graphite in both system appearances. This gives
  light mode a visual anchor instead of turning the whole window into a pale
  form, while dark mode remains continuous and quiet.
- Album artwork is the dominant object. When metadata has no artwork, render a
  designed record sleeve using the track title rather than an empty gray box.
- Import, refresh, clear, scan, normalization, playback rate, and random weight
  are supporting tools. They must not compete with artwork, title, transport,
  search, or the queue.
- In low-height windows, the listening stage scrolls, but artwork, track title,
  progress, and transport appear before every advanced control and lyrics.

## System Decisions

### Color

- Brand accent: a single restrained coral red used for play state, selection,
  focus, and primary actions.
- Listening stage: one solid deep graphite plane with no decorative gradient.
- Library light appearance: warm near-white with charcoal labels.
- Library dark appearance: neutral graphite with cool-white labels.
- Warning and destructive colors remain semantic system colors.
- Random-weight colors are visible only while editing a weight or when a track
  has a non-default override.

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
- **Transport:** shuffle, previous, play/pause, next, repeat. Only play/pause is
  solid; active modes use the single accent without text pills.
- **Queue toolbar:** title/count and text tabs on the left; one import action and
  quiet icon tools on the right. Destructive and infrequent actions live in an
  overflow menu.
- **Search:** one native-looking search surface with a visible focus state.
- **Track row:** glyph/equalizer, two lines of metadata, optional analyzed state,
  duration, and hover/context actions. Default random weight is visually silent.
- **Lyrics:** absent when no lyrics exist; otherwise a flat continuation of the
  listening stage, not another card.

## SwiftUI and Performance Rules

- Keep SwiftUI, AppKit, AVFoundation, CoreAudio, and SF Symbols; add no UI or
  animation dependency.
- Preserve lazy row creation and stable path-based identity.
- No blur, file I/O, sorting, path normalization, large shadow, or artwork
  decoding inside queue rows.
- Keep current-artwork ImageIO downsampling and the bounded playlist workers.
- Use native `Button`, `Menu`, `Slider`, `Toggle`, `TextField`, and scroll
  semantics so keyboard and accessibility behavior survive the redesign.
- The root owns lifecycle, notifications, alerts, sheets, drops, and updates;
  visual containers do not duplicate service ownership.

## Self-Critique

1. A permanently dark listening stage can feel detached in light mode. Connect
   the two panes through shared typography, the coral state color, and one clean
   divider—not extra glass or gradients.
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
