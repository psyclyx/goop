# Status

## Current

Iteration 6. Implemented draw list generation from laid-out widget tree.
Core pipeline now runs: build tree → layout (clay) → generate draw commands.
8/8 tests pass (all previous + 4 new draw tests).

## Iteration Count

6

## Done This Iteration

- Implemented `draw.generate()` — walks tree, emits DrawCommands per widget type
- Container/scroll area: background rect; button: bg rect + label text with
  interaction-aware colors; text: DrawText; slider: track + thumb rects;
  scroll area: clip push/pop
- Added `Context.generateDrawList()` / `Context.freeDrawList()` to public API
- Exported DrawCommand/DrawList types from goop.zig
- 3 unit tests in draw.zig + 1 integration test in goop.zig

## Next

1. Wire event dispatch — hit testing against layout_rects, state updates
   (hovered/pressed/focused), button click detection
2. Replace stub text measurement with snail
3. Build out demo — open a window, render draw commands via GL backend

## What's Wrong

- Text measurement is still a rough approximation (font_size * 0.6 per char)
- No event processing — events defined but nothing consumes them
- Demo is a print-and-exit stub — no window, no rendering
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Button label positioning is padding-offset, not true centering
- Draw list is allocated fresh each frame — no reuse/pooling
