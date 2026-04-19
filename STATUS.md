# Status

## Current

Iteration 50. Design review + chore cycle.
72 tests pass. Build clean. Demo runs.

## Iteration Count

50

## Done This Iteration

- Design review: assessed architecture at 50-iteration mark
- Archived iterations 45–49
- Declared first milestone complete (buttons, text, slider, scroll, GL33, Wayland)
- Proposed milestone 2: dynamic UI (widget removal, draw caching, toolbar, font path)
- Reviewed all deferred items — widget removal now #1 priority

## Next

1. Widget tree mutation/removal API (generational handles or free-list)
2. Draw list caching (draw-dirty flag, skip regeneration when unchanged)
3. Toolbar/menu bar widget
4. Embedder-provided font path (remove popen)

## What's Wrong

- Widget tree is append-only — no removal/mutation API (50 iterations deferred, now blocking)
- No draw list caching — draw list regenerated every frame even when output unchanged
- Font loading uses popen("fc-match") — fragile, Linux-only
- MSAA sample count hardcoded to 4 — no fallback if GPU doesn't support it
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device)
- No toolbar/menu widget — last item from target widget set
