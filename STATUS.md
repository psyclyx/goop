# Status

## Current

Iteration 17. Added checkbox widget.
18/18 tests pass. Build clean. Demo runs.

## Iteration Count

17

## Done This Iteration

- Added `Checkbox` variant to `WidgetKind` (label + checked bool)
- Layout: row with grow width, text label, clay element
- Draw: bordered box rect + accent fill when checked + label text
- Dispatch: toggle checked on click via `fireClick`
- Public API: `isChecked(handle)` convenience method
- 4 new tests (2 draw, 1 dispatch, 1 integration)

## Next

1. Demo: add checkbox to the demo scene
2. Demo: run with timeout, add screenshot/headless capture for review
3. Extract slider thumb width to style (currently hardcoded in draw.zig and dispatch.zig)
4. Radio button widget
5. Chore cycle (iteration 20)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- Demo uses page_allocator everywhere — no arena/frame allocator
- Font loading uses popen("fc-match") — works but fragile
- Slider thumb width (16px) is hardcoded in both draw.zig and dispatch.zig
- Demo has no timeout or headless capture — can hang, requires manual kill
- Border rendering not yet visually verified — needs demo screenshot
- Checkbox box is drawn at font_size square — may not align perfectly with text baseline
