# Status

## Current

Iteration 45.
69 tests pass. Build clean. Demo runs.

## Iteration Count

45

## Done This Iteration

- Chore cycle: archived iterations 40-44, reviewed last 5 commits, updated DESIGN.md
- Codebase snapshot: 5186 LOC, 69 tests, 8 widget types
- dispatch.zig size issue resolved (extracted tests in iteration 42, now 824 lines)

## Next

1. Dirty tracking — avoid full layout + draw every frame
2. Real text measurement instead of approximate char_width
3. Widget tree mutation/removal API

## What's Wrong

- Approximate char_width (font_size * 0.6) — wrong for proportional fonts, needs real text measurement
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Scroll clamping uses previous frame's child layout rects — off by one frame
- Focus ring draws outside widget bounds — may clip in scroll areas
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device) yet
- Double-click detection requires embedder to provide timestamp_ms (defaults to 0 = disabled)
