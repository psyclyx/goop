# Status

## Current

Iteration 11. Abstracted text measurement out of core — layout.zig no longer
imports snail. TextMeasureCtx is now a generic function pointer + opaque
context. Snail adapter moved to demo. 13/13 tests pass. Library builds
without snail dependency.

## Iteration Count

11

## Done This Iteration

- Replaced snail-specific TextMeasureCtx with generic MeasureTextFn + opaque ctx
- Removed snail import from layout.zig and snail dep from goop_mod/test_mod
- Moved snail measurement code to demo/main.zig as SnailTextCtx adapter
- Exported MeasureTextFn and TextDimensions from goop.zig

## Next

1. Clean up pushEvent API (Context owns event queue allocator)
2. Slider drag interaction
3. Frame callback in demo
4. Border rendering
5. Checkbox widget

## What's Wrong

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
