# Status

## Current

Iteration 13. Slider drag interaction implemented — click and drag
sets slider value proportionally. 14/14 tests pass. Library and demo
build clean.

## Iteration Count

13

## Done This Iteration

- Added drag_target to MouseState for tracking active slider drags
- Mouse press on slider starts drag and sets value from click position
- Mouse move during drag updates slider value (clamped to min/max)
- Mouse release ends drag
- Added Context.sliderValue convenience accessor
- Added slider drag test

## Next

1. Frame callback in demo
2. Border rendering
3. Checkbox widget
4. Widget tree mutation/removal API
5. Chore cycle (iteration 15)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- No border rendering on rects
- No frame callback — redraws on every event, not paced
- Demo uses page_allocator everywhere — no arena/frame allocator
- Font loading uses popen("fc-match") — works but fragile
- Slider thumb width (16px) is hardcoded in both draw.zig and dispatch.zig
