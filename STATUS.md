# Status

## Current

Iteration 12. Context now stores its allocator — pushEvent, deinit,
generateDrawList, freeDrawList no longer take an allocator parameter.
13/13 tests pass. Library and demo build clean.

## Iteration Count

12

## Done This Iteration

- Stored allocator in Context struct (set once in init)
- Removed allocator param from pushEvent, deinit, generateDrawList, freeDrawList
- Updated all call sites in tests and demo

## Next

1. Slider drag interaction
2. Frame callback in demo
3. Border rendering
4. Checkbox widget
5. Widget tree mutation/removal API

## What's Wrong

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
