# Status

## Current

Iteration 15 (chore cycle). Reviewed iterations 10–14, processed inbox,
removed dead import in layout.zig. 14/14 tests pass. Build clean.

## Iteration Count

15

## Done This Iteration

- Reviewed last 5 iterations: allocator refactor and text measurement
  abstraction both clean; slider thumb width still duplicated
- Processed inbox: zig.md (already on nightly/master — resolved),
  demo.md (timeout + screenshot capture needed — added to backlog below)
- Removed unused `draw` import from layout.zig
- No stale context to archive — docs are lean

## Next

1. Border rendering
2. Checkbox widget
3. Demo: run with timeout, add screenshot/headless capture for review
4. Extract slider thumb width to style (currently hardcoded in draw.zig and dispatch.zig)
5. Chore cycle (iteration 20)

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
- Demo has no timeout or headless capture — can hang, requires manual kill
