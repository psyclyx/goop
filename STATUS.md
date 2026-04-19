# Status

## Current

Iteration 55. Chore cycle (archive, review, prune).
80 tests pass. Build clean. Demo runs.

## Iteration Count

55

## Done This Iteration

- Archived iterations 50–54 to docs/archive/
- Reviewed last 5 commits: removal API, draw caching, pixel snapping, xkbcommon
- Updated DESIGN.md: resolved widget removal and draw caching deferrals, added iteration 55 chore review with current codebase snapshot
- Pruned DESIGN.md milestone 2 checklist (2 of 4 items struck through as done)

## Next

1. Toolbar/menu bar widget (last target widget, milestone 2 item #3)
2. Embedder-provided font path (milestone 2 item #4, removes popen("fc-match"))
3. C API bindings (c_api.zig)

## What's Wrong

- Font loading uses popen("fc-match") — fragile, Linux-only
- MSAA sample count hardcoded to 4 — no fallback if GPU doesn't support it
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device)
- No toolbar/menu widget — last item from target widget set
- No HiDPI scaling — demo treats surface dimensions as 1:1 with physical pixels
- No C API yet
- `freeDrawList` is a no-op — semver break if anyone relied on manual lifetime
- widget.zig grew 54% (348→536) from removal logic — watch for further growth
