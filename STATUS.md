# Status

## Current

Iteration 14. Frame callback pacing added to demo — rendering is now
throttled to compositor refresh rate via wl_surface.frame callbacks.
14/14 tests pass. Library and demo build clean.

## Iteration Count

14

## Done This Iteration

- Added wl_callback_listener for wl_surface.frame done events
- Added requestFrame helper to request compositor pacing
- Main loop now skips drawing when a frame callback is pending
- After each swap, a frame callback is requested before the next draw

## Next

1. Border rendering
2. Checkbox widget
3. Widget tree mutation/removal API
4. Chore cycle (iteration 15)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- No border rendering on rects
- Demo uses page_allocator everywhere — no arena/frame allocator
- Font loading uses popen("fc-match") — works but fragile
- Slider thumb width (16px) is hardcoded in both draw.zig and dispatch.zig
