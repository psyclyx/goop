# Status

## Current

Iteration 29.
37 tests pass. Build clean. Demo runs. 3637 LOC.

## Iteration Count

29

## Done This Iteration

- Added `home` and `end` keycodes to `Keycode` enum
- Home/End key handling in dispatch.zig for text input cursor (jump to start/end)
- Mapped evdev scancodes 102 (home) and 107 (end) in demo
- Added test for Home/End cursor movement

## Next

1. Delete key support for text input
2. Plan dispatch.zig extraction when goop.zig passes ~800 lines (currently 280)
3. Text input placeholder text

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
