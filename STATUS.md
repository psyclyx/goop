# Status

## Current

Iteration 53. Widget tree mutation/removal API.
78 tests pass. Build clean. Demo runs.

## Iteration Count

53

## Done This Iteration

- Changed NodeHandle from enum(u32) to struct { index, generation } for stale-handle detection
- Added alive/generation fields to Node, free list to Tree for slot reuse
- Implemented Tree.remove() — recursively removes subtrees, unlinks from siblings/parent, pushes to free list
- Added Tree.isAlive(), Tree.handleFromIndex(), Tree.slotCount() helpers
- Added Context.removeWidget() and Context.isAlive() to public API
- Updated all modules (layout, draw, hittest, focus, dispatch) to skip dead nodes
- 6 new tests: remove leaf, remove subtree, slot reuse, middle sibling removal

## Next

1. Draw list caching (draw-dirty flag, skip regeneration when unchanged)
2. Toolbar/menu bar widget
3. HiDPI/scale factor support (viewport assumes 1:1 logical:physical)
4. C API bindings (c_api.zig not yet created)

## What's Wrong

- No draw list caching — draw list regenerated every frame even when output unchanged
- Font loading uses popen("fc-match") — fragile, Linux-only
- MSAA sample count hardcoded to 4 — no fallback if GPU doesn't support it
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device)
- No toolbar/menu widget — last item from target widget set
- No HiDPI scaling — demo treats Wayland surface dimensions as 1:1 with physical pixels
- No C API yet
