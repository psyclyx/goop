# Status

## Current

Iteration 40 (chore cycle).
56 tests pass. Build clean. Demo runs.
4476 LOC total across 9 source files.

## Iteration Count

40

## Done This Iteration

- Archived iterations 30–34 and 35–39
- Reviewed last 5 commits (all text input mouse interaction)
- Updated DESIGN.md with iteration 40 codebase snapshot and observations
- Pruned STATUS.md

## Next

1. Text input clipboard (Ctrl+C/V/X) — needs platform clipboard integration
2. Extract text input dispatch logic or tests from dispatch.zig (~1645 lines)
3. Double-click to select word
4. More letter keys in Keycode enum (add as needed)

## What's Wrong

- dispatch.zig is 1645 lines — tests are ~60% of it, still growing
- Approximate char_width (font_size * 0.6) — wrong for proportional fonts, needs real text measurement
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Scroll clamping uses previous frame's child layout rects — off by one frame
- Focus ring draws outside widget bounds — may clip in scroll areas
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard integration needs platform-specific code (Wayland wl_data_device)
