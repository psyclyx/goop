# Status

## Current

Iteration 28. Refactor iteration.
35 tests pass. Build clean. Demo runs. 3559 LOC.

## Iteration Count

28

## Done This Iteration

- Extracted `interactionBg` helper in draw.zig — was duplicated in button, checkbox, radio_button, text_input emitters
- Net -19 lines

## Next

1. Home/End keys for text input cursor (jump to start/end)
2. Plan dispatch.zig extraction when goop.zig passes ~800 lines (currently 280)
3. Delete key support for text input

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
