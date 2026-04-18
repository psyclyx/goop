# Status

## Current

Layout pass implemented. layout.zig walks the widget tree, emits clay
elements per widget kind, runs clay layout, writes bounding boxes back
to Node.layout_rect. Context exposes doLayout() and setDimensions().
Stub text measurement (0.6 × fontSize per char) until snail integration.
All tests pass (5/5), library and demo build.

## Iteration Count

4

## Next

1. Implement draw list generation from laid-out tree (draw.zig)
2. Wire event dispatch (hit testing, state updates)
3. Replace stub text measurement with snail

## What's Wrong

- Text measurement is a rough approximation — will produce wrong layout for real text
- draw.zig defines types but nothing generates draw commands from laid-out nodes
- No event processing — events are defined but nothing consumes them
- demo is still a print-and-exit stub — no window, no rendering
- Widget tree has no removal/mutation API — append-only
- No dirty tracking — full layout runs every frame
- Zig version is 0.17.0-dev (master) — may need adjustment for 0.16 release
