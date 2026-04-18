# Status

## Current

Iteration 22. Extracted slider thumb width to style system.
23/23 tests pass. Build clean. Demo runs.

## Iteration Count

22

## Done This Iteration

- Added `thumb_width` field to Theme (default 16), Style, and ResolvedStyle
- draw.zig reads thumb width from resolved style instead of hardcoded constant
- dispatch.zig now takes theme parameter; updateSliderValue resolves per-widget style

## Next

1. Design review at iteration 25
2. Text input widget (stretch)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- Font loading uses popen("fc-match") — fragile
- Radio button circle rendering depends on renderer corner_radius support
