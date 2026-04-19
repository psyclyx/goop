# Status

## Current

Iteration 52. Text rendering fix.
72 tests pass. Build clean. Demo runs.

## Iteration Count

52

## Done This Iteration

- Fixed jagged text rendering by snapping glyph positions to pixel grid
- Root cause: Clay layout produces fractional x/y, passed directly to snail causing coverage to straddle pixel boundaries
- Fix: @round() both x and baseline_y in demo/render.zig before addString()

## Next

1. Widget tree mutation/removal API (generational handles or free-list)
2. Draw list caching (draw-dirty flag, skip regeneration when unchanged)
3. Toolbar/menu bar widget
4. HiDPI/scale factor support (viewport assumes 1:1 logical:physical)

## What's Wrong

- Widget tree is append-only — no removal/mutation API (50+ iterations deferred)
- No draw list caching — draw list regenerated every frame even when output unchanged
- Font loading uses popen("fc-match") — fragile, Linux-only
- MSAA sample count hardcoded to 4 — no fallback if GPU doesn't support it
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device)
- No toolbar/menu widget — last item from target widget set
- No HiDPI scaling — demo treats Wayland surface dimensions as 1:1 with physical pixels
