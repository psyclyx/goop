# Status

## Current

Iteration 10 (design review). Reviewed architecture after 9 iterations and
~2,000 lines. Core architecture validated — clean module boundaries, correct
layering. Two actionable findings: core depends on snail (must abstract), and
pushEvent API takes unnecessary allocator param. 13/13 tests pass.

## Iteration Count

10

## Done This Iteration

- Design review: challenged widget tree mutation model, core/snail coupling,
  transient state placement, event queue API, scroll clamping, frame pacing
- Updated DESIGN.md with decisions: abstract text measurement, fix pushEvent
  API; deferred widget removal and interaction result separation (no 3x signal)
- Validated: Clay integration, draw command model, dispatch, module boundaries

## Next

1. Abstract text measurement out of core (remove snail import from layout.zig)
2. Clean up pushEvent API (Context owns event queue allocator)
3. Slider drag interaction
4. Frame callback in demo
5. Border rendering

## What's Wrong

- Core imports snail in layout.zig — violates "core must not depend on rendering"
- pushEvent takes allocator on every call — API friction, Context already has one
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- Slider has no drag interaction — only visual
- No keyboard/focus navigation
- No border rendering on rects
- No frame callback — redraws on every event, not paced
- Demo uses page_allocator everywhere — no arena/frame allocator
- Font loading uses popen("fc-match") — works but fragile
