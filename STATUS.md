# Status

## Current

Iteration 23. Scroll area values clamped to content bounds.
25/25 tests pass. Build clean. Demo runs.

## Iteration Count

23

## Done This Iteration

- Added clampScroll() and contentExtent() helpers in dispatch.zig
- Scroll offsets clamped to [0, content_size - viewport_size] after each scroll event
- Added 2 new tests: clamping to max, clamping when content fits viewport

## Next

1. Design review at iteration 25
2. Text input widget (stretch)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- Font loading uses popen("fc-match") — fragile
- Radio button circle rendering depends on renderer corner_radius support
- Scroll clamping uses previous frame's child layout rects — off by one frame on content resize
