# Status

## Current

Iteration 30.
36 tests pass. Build clean. Demo runs. 3637 LOC.

## Iteration Count

30

## Done This Iteration

- Chore cycle: archived iterations 25–29, reviewed last 5 commits, pruned
- dispatch.zig is 974 lines — past the 800-line extraction threshold
- Updated DESIGN.md: marked interactionBg resolved, escalated dispatch.zig split
- Corrected test count (36, not 37)

## Next

1. Extract focus.zig and hittest.zig from dispatch.zig (overdue per design review)
2. Delete key support for text input
3. Text input placeholder text

## What's Wrong

- dispatch.zig is 974 lines — needs splitting (focus + hittest extraction)
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
