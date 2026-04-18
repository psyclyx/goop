# Status

## Current

Iteration 19. Added radio button widget.
23/23 tests pass. Build clean. Demo runs.

## Iteration Count

19

## Done This Iteration

- Added `RadioButton` to `WidgetKind` union with `label`, `group`, `selected`, `clicked` fields
- Mutual exclusivity: clicking a radio button deselects all others in the same group
- Circular rendering via `corner_radius = box_size / 2`
- Added to dispatch (isInteractive, fireClick with group scan), draw, layout
- Added `isSelected()` to Context API; extended `wasClicked()` and `clearClickedFlags()`
- Demo scene: three radio buttons (Option A/B/C) in group 1, with logging
- 5 new tests: dispatch group behavior, draw unselected/selected, context integration

## Next

1. Chore cycle (iteration 20): archive stale context, review last 5 commits, prune
2. Extract slider thumb width to style (currently hardcoded in draw.zig and dispatch.zig)
3. Text input widget (stretch)

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
- Radio button circle rendering depends on renderer supporting corner_radius well
