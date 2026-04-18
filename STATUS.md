# Status

## Current

Iteration 31.
37 tests pass. Build clean. Demo runs. 3644 LOC.

## Iteration Count

31

## Done This Iteration

- Extracted focus.zig (77 lines) and hittest.zig (40 lines) from dispatch.zig
- dispatch.zig reduced from 974 to 862 lines
- Tests remain in dispatch.zig (they test integrated behavior)

## Next

1. Delete key support for text input
2. Text input placeholder text
3. dispatch.zig still 862 lines — consider extracting scroll/slider helpers or tests

## What's Wrong

- dispatch.zig is 862 lines — still large, tests account for most of it
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
