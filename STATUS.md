# Status

## Current

Iteration 26. Feature iteration.
34 tests pass. Build clean. Demo runs. 3483 LOC.

## Iteration Count

26

## Done This Iteration

- Added text input widget with fixed 256-byte buffer, cursor tracking, insert/delete
- Added backspace keycode to event system
- Text input handles character events when focused, backspace to delete
- Draws background, text content, cursor line (when focused), focus ring
- Focusable via click and tab navigation
- Added to demo widget tree
- 5 new tests (dispatch: 4, draw: 2)

## Next

1. Arrow key cursor movement for text input (left/right keycodes)
2. Extract interaction bg helper in draw.zig when 4th widget needs it
3. Plan dispatch.zig extraction if it passes ~800 lines

## What's Wrong

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
- Text input has no placeholder text or selection support
