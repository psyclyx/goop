# Status

## Current

Iteration 32.
38 tests pass. Build clean. Demo runs.

## Iteration Count

32

## Done This Iteration

- Added Delete key support for text input (forward delete)
- Added `delete` to Keycode enum, `deleteForward()` to TextInput, dispatch handler, evdev mapping (scancode 111)
- Added test: "text input delete key deletes forward"

## Next

1. Text input placeholder text
2. dispatch.zig still large — consider extracting scroll/slider helpers or tests
3. Text input selection support

## What's Wrong

- dispatch.zig is ~900 lines — still large, tests account for most of it
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
