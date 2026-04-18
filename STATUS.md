# Status

## Current

Iteration 34.
45 tests pass. Build clean. Demo runs.

## Iteration Count

34

## Done This Iteration

- Added text input selection support
- Added `selection_anchor: ?u8` field to TextInput struct
- Added `hasSelection()`, `selectionRange()`, `selectedContent()`, `deleteSelection()`, `clearSelection()` helpers
- Shift+Left/Right/Home/End creates/extends selection
- Arrow keys without Shift collapse selection to start/end edge
- Backspace/Delete with active selection deletes selected text
- Typing with active selection replaces it
- Added `selection_bg` color to Theme (rgba 80,140,220,100)
- Draw selection highlight rect between anchor and cursor when focused
- Added 5 tests: shift+arrow selection, collapse on arrow, backspace deletes selection, typing replaces selection, draw highlight rect

## Next

1. Text input clipboard (copy/paste) — needs Ctrl key in event system
2. dispatch.zig is ~1100 lines — consider extracting text input helpers or tests
3. Mouse click-to-position cursor in text input
4. Mouse drag selection in text input

## What's Wrong

- dispatch.zig is ~1100 lines — tests account for most of it
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Radio button circle rendering depends on renderer corner_radius support
- Scroll clamping uses previous frame's child layout rects — off by one frame on content resize
- Focus ring draws outside widget bounds — may clip in scroll areas
- No keyboard-driven slider value change (arrow keys)
- Magic numbers for focus ring inset and checkbox/radio indicator inset
- Text input cursor position uses approximate char_width (font_size * 0.6) — will be wrong for non-monospace fonts
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- No Ctrl key support in event system — blocks clipboard, Ctrl+A select-all
