# Status

## Current

Iteration 54. Draw list caching.
80 tests pass. Build clean. Demo runs.

## Iteration Count

54

## Done This Iteration

- Added `draw_dirty` flag and `cached_draw_list` to Context
- `generateDrawList()` returns cached list when no events, layout, or tree changes occurred
- Context owns draw list memory — `freeDrawList()` is now a no-op (API preserved)
- Cache invalidated on: layout run, event processing, widget removal
- 2 new tests: caching returns same list, regeneration after events

## Next

1. Toolbar/menu bar widget
2. HiDPI/scale factor support (viewport assumes 1:1 logical:physical)
3. C API bindings (c_api.zig not yet created)

## What's Wrong

- Font loading uses popen("fc-match") — fragile, Linux-only
- MSAA sample count hardcoded to 4 — no fallback if GPU doesn't support it
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device)
- No toolbar/menu widget — last item from target widget set
- No HiDPI scaling — demo treats Wayland surface dimensions as 1:1 with physical pixels
- No C API yet
- `freeDrawList` is a no-op — technically a semver break if anyone relied on manual lifetime
