# MusicPlayer 4.4 Design System

## Direction

**Concept — Record Sleeve Editorial:** the window reads like an opened record
sleeve. The left side is a tactile listening stage; the right side is a precise
liner-note index for queues and playlists.

**Keywords:** album-led, editorial, tactile, native, warm, precise, scannable.

**Avoid:** live blur, transparent glass, colored gradients, animated artwork,
per-row covers, equal-weight cards, large red backgrounds, rainbow UI chrome,
and perpetual motion.

## Reference Translation

- The approved restrained light mockup supplies the production layout: warm
  paper surfaces, a large sleeve, playlist identity, numbered tracks, and calm
  management controls.
- The approved listening-studio mockup supplies dark appearance: wine-black and
  graphite planes, bone text, coral active states, and tonal depth without glow.
- The approved record-sleeve mockup supplies editorial details: system-serif
  music titles, monograms, index numbers, fine rules, and the physical sleeve
  framing around the current cover.
- The shipped 4.3.8 UI supplies the behavior contract. Playback modes, immersion,
  lyrics, six weight levels, queue and playlist persistence, and hit regions do
  not change with the visual redesign.

## Composition

- At 980 points and wider, use one asymmetric split: a 430–540 point listening
  stage and a flexible library. Narrower windows stack the two regions.
- The current cover is the dominant object. It receives the only large shadow
  and a subtle sleeve/backing layer made from static vector shapes.
- The left-side reading order is orientation, sleeve, song identity, progress,
  playback utilities, transport, volume, next-up preview, lyrics, and output.
- The right-side reading order is collection title, panel tabs/actions, search,
  selected-playlist identity, column labels, and track index.
- A playlist has one generated vector monogram in its header. Track rows never
  decode or display artwork.
- Track rows use 01/02/03 numbering for the current visible order, a narrow
  coral active rail, visible six-level weights, a fixed duration column, and
  hover-only management actions.

## Color and Material

- Light appearance uses opaque parchment, stone, and warm paper surfaces with
  dark charcoal text. It avoids pure white and large coral fields so reflective
  screens remain readable.
- Dark appearance uses wine-black for the listening stage, graphite for the
  library, warm bone text, and the same coral state language.
- Coral indicates primary action, active playback, focus, enabled state, or
  selection. Structural dividers and inactive controls remain neutral.
- Warning, destructive, success, and information colors remain semantic and do
  not become decorative accents.
- Surfaces are matte and opaque. Depth comes from tonal steps, fine rules, and
  one artwork shadow rather than blur or translucent materials.

## Typography

- Use Apple system fonts only. Music identity and collection display titles use
  the system serif design; controls, metadata, dense rows, and numbers use SF.
- Current song title: 28 point semibold serif. Collection title: 30 point bold
  serif. Selected playlist title: 24 point bold serif.
- Row title: 13 point semibold SF; metadata: 10–11 point SF; column and section
  labels: 9–10 point semibold SF.
- Durations and index numbers use rounded monospaced digits.
- Do not use tracking on Chinese display titles. Tracking is reserved for short
  Latin-style orientation labels.

## Spacing and Shape

- Primary spacing scale: 4, 8, 12, 16, 24, and 32 points.
- Artwork radius: 14 points. Search radius: 10 points. Rows and compact controls:
  8 points. Large sheets: 16 points.
- Lists are composed regions, not stacks of cards. Use spacing, alignment, tonal
  selection fills, and one-pixel dividers.

## Component Contracts

- **Playback mode:** one 76-point two-state Toggle switches between shuffle and
  single-track repeat. One mode is always active; the entire control flips it.
  Red is active and gray is inactive.
- **Immersive playback:** a separate infinity Toggle remains compact and uses
  the same enabled/disabled color semantics.
- **Transport:** previous, play/pause, and next stay centered. Only play/pause is
  a solid primary circle.
- **Random weight:** every current-track and track-row picker permanently shows
  six independent squares for 0.5×, 1.0×, 1.6×, 3.2×, 4.8×, and 6.4×. The
  second level is the default. Picker padding and gaps never trigger playback.
- **Playlist header:** one static monogram, track count, known duration, primary
  play action, neutral add action, and an overflow menu.
- **Lyrics:** lyrics continue the listening stage instead of becoming a card.
  The active line uses serif display type and coral; auto-follow is coral only
  while enabled, while “当前句” remains a neutral one-shot action.
- **Next up:** one compact, informational preview may show the predicted next
  track. It does not decode artwork or trigger playback.

## SwiftUI and Performance Rules

- Keep SwiftUI, AppKit, AVFoundation, CoreAudio, SF Symbols, and native control
  semantics. Add no UI, animation, image, or typography dependency.
- Keep lazy row creation and stable path-based identity. Never wrap an entire
  track row around its weight or management controls.
- Use only the current 600-pixel downsampled artwork. Do no artwork decoding,
  sorting, file I/O, path normalization, blur, shadow, mask, or color extraction
  inside track rows.
- No continuous animation. Short hover, press, Toggle, and state transitions may
  use the existing 160–240 ms motion tokens and must respect Reduce Motion.
- Immersive-boundary and normalization work stays bounded and cached. The UI
  redesign must not start whole-library analysis or retain decoded PCM.
- Queue, loudness, immersive-boundary, and weight persistence behavior remains
  owned by the existing services; visual containers do not duplicate it.

## Visual QA

Verify light and dark appearance, wide and stacked layouts, long Chinese titles,
real and fallback artwork, empty and large collections, row hover/focus, six
weight hit regions, shuffle/repeat switching, immersion state, lyrics follow,
and Reduce Motion. Capture the real app through its built-in screenshot command
and compare it against the three approved mockups before release.
