# Status

## Current

Core data structures defined. Widget tree (flat array, handle-based) supports
container, text, button, slider, scroll_area. Event, style, and draw types
scaffolded. Context struct owns clay arena + tree + theme. All tests pass,
library and demo build.

## Iteration Count

3

## Next

1. Implement the layout pass (layout.zig) — walk tree, configure clay, write back rects
2. Implement draw list generation from laid-out tree
3. Wire event dispatch (hit testing, state updates)

## What's Wrong

- layout.zig is a placeholder — no clay integration yet, nodes have zero-size rects
- No event processing — events are defined but nothing consumes them
- draw.zig defines types but nothing generates draw commands
- demo is still a print-and-exit stub — no window, no rendering
- Widget tree has no removal/mutation API — append-only
- No dirty tracking — can't tell when to re-layout or re-draw
- Zig version is 0.17.0-dev (master) — ArrayListUnmanaged init syntax already differed
