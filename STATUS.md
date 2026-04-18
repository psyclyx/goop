# Status

## Current

Iteration 18. Added checkbox to demo scene.
18/18 tests pass. Build clean. Demo runs.

## Iteration Count

18

## Done This Iteration

- Added checkbox widget to demo scene ("Enable option")
- Added `clicked` field to `Checkbox` struct for click detection parity with buttons
- Extended `wasClicked()` and `clearClickedFlags()` to handle checkboxes
- Demo logs checkbox toggle state to stderr on click

## Next

1. Demo: run with timeout, add screenshot/headless capture for review
2. Extract slider thumb width to style (currently hardcoded in draw.zig and dispatch.zig)
3. Radio button widget
4. Chore cycle (iteration 20)

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
