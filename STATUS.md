# Status

## Current

Iteration 27. Feature iteration.
35 tests pass. Build clean. Demo runs. 3578 LOC.

## Iteration Count

27

## Done This Iteration

- Added `left` and `right` keycodes to event system
- Dispatch handles left/right arrow keys to move text input cursor
- Cursor clamps to [0, len] at boundaries
- Mapped evdev scancodes 105/106 in demo
- 1 new test covering cursor movement, insertion at mid-position, boundary clamping

## Next

1. Extract interaction bg helper in draw.zig when 4th widget needs it
2. Plan dispatch.zig extraction if it passes ~800 lines
3. Home/End keys for text input cursor (jump to start/end)

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
