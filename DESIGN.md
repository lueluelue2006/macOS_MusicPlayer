# MusicPlayer Design System

## Product Character

MusicPlayer is a calm, native macOS listening workspace. Album artwork and the
current song carry the emotion; application chrome stays neutral, precise, and
quiet. The interface must remain responsive on an 8 GB Mac with a large local
library.

## Reference Direction

- Apple Human Interface Guidelines define platform hierarchy, semantic color,
  system typography, keyboard behavior, and resizable-window expectations.
- IINA contributes one principle: media content leads and playback controls
  occupy one compact, coherent layer.
- The previous MusicPlayer UI contributes the existing functional density, but
  not its rainbow gradients, glow effects, stacked glass cards, or per-row
  shadows.

## Visual Language

- **Visual anchor:** the active album artwork.
- **Material:** a quiet record workspace with one structural player pane and a
  flat, highly scannable library pane.
- **Color:** neutral semantic surfaces plus the user's macOS accent color.
- **Depth:** spacing and separators first; one soft artwork shadow is allowed.
- **Icons:** SF Symbols only. Icons clarify actions and state; they are not
  decoration.
- **Avoid:** multicolor chrome, neon glow, decorative gradients, nested blur,
  equal-weight cards, and perpetual animation.

## Tokens

- Use `AppTheme` semantic roles instead of raw RGB values in feature views.
- System font is the only UI typeface. Use semibold sparingly for the current
  song, section titles, and primary actions.
- Base spacing rhythm: 4, 8, 12, 16, 20, 24 points.
- Control radius: 8–10 points. Grouped surface radius: 12 points. Artwork
  radius: 16 points.
- Borders are one pixel and low contrast. Shadows belong to artwork or a
  floating transient surface, never to every list row.

## Layout

- Wide windows use a 360–430 point player pane and a flexible queue pane.
- Narrow windows switch to a vertical layout only when two readable panes no
  longer fit.
- The first read is artwork and song, the second is transport, and the third is
  the queue. Import, playback options, lyrics, and analysis settings are
  supporting actions.
- Keep lazy row creation and stable audio-file identity for long libraries.

## Components

- The primary play/pause button is the only solid accent control in the player.
- Previous and next are quiet icon controls with immediate hover and press
  feedback.
- Search uses a compact semantic surface and a visible focus stroke.
- Queue rows are flat, two-line, and shadow-free. Active and hover states use
  low-opacity semantic fills.
- Destructive actions use the system destructive color and must never become a
  visually dominant default action.

## Motion and Interaction

- Feedback starts immediately and settles in about 180–280 ms.
- Springs are critically damped; momentum-free controls do not bounce.
- No decorative loops or continuously moving borders.
- Preserve native `Button`, `Toggle`, `Picker`, `TextField`, `Slider`, and
  scroll-container semantics for keyboard and accessibility behavior.
- Reduced Motion removes nonessential scale or movement while preserving state
  feedback.

## Performance Budget

- No more than one large material or translucent structural layer per pane.
- List rows must not use blur, large shadows, file I/O, path normalization, or
  sorting in `body`.
- Artwork decoding stays off the main thread and remains capped at the existing
  600-pixel thumbnail size.
- Large-list loading uses bounded concurrency. Derived search/sort/cache views
  are recomputed only when their source state changes.
- Do not add third-party UI, animation, image, or state-management dependencies.

## Review Checklist

- Light and dark appearance share the same product identity.
- The current song and play control are visible without scrolling at the normal
  desktop window size.
- A 1,000-track queue scrolls without per-row effects or unstable identity.
- Search, sort, locate-now-playing, temporary playback, lyrics seeking, metadata
  editing, and queue/playlist scope semantics remain intact.
