# Status

## Current

Iteration 7. Implemented event dispatch — hit testing, hover/press state
tracking, button click detection, scroll event routing.
Core pipeline: build tree → layout (clay) → process events → generate draw.
13/13 tests pass (8 previous + 4 dispatch unit + 1 dispatch integration).

## Iteration Count

7

## Done This Iteration

- Created `src/core/dispatch.zig` — event processing against laid-out rects
- Hit testing: point-in-rect, topmost interactive widget wins
- Hover: updated on mouse_move, only topmost widget marked hovered
- Click: press+release on same button sets `clicked` flag
- Scroll: mouse_scroll routed to scroll_area under cursor
- Context API: `pushEvent`, `processEvents`, `clearClickedFlags`, `wasClicked`
- MouseState tracks cursor position, left button, press target across events

## Next

1. Replace stub text measurement with snail integration
2. Build out demo — open a window, render draw commands via GL backend
3. Slider drag interaction (press on thumb, track mouse_move while held)

## What's Wrong

- Text measurement is still a rough approximation (font_size * 0.6 per char)
- Demo is a print-and-exit stub — no window, no rendering
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Slider has no drag interaction — only visual, no mouse control
- Hit testing is O(n) linear scan every event — fine for now
- No keyboard/focus navigation
- pushEvent takes allocator param on every call (queue could own allocator)
