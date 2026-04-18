# Status

## Current

Iteration 25. Chore cycle + design review.
29 tests pass. Build clean. Demo runs. 3171 LOC.

## Iteration Count

25

## Done This Iteration

- Archived iterations 20–24 to docs/archive/
- Design review: assessed all 9 source files, documented observations
- Updated DESIGN.md with iteration 25 review (size thresholds, deferred items, validations)
- Marked scroll clamping as resolved from iteration 10 deferred list

## Next

1. Text input widget — next feature target
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
