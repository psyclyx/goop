# Status

## Current

Iteration 20. Chore cycle: archived iterations 15–19, processed inbox, pruned.
23/23 tests pass. Build clean. Demo runs.

## Iteration Count

20

## Done This Iteration

- Archived iterations 15–19 summary to docs/archive/
- Processed inbox: demo window popup complaint → elevated to top priority
- Marked iteration 10 design review items as implemented in DESIGN.md
- Cleared inbox

## Review Notes (iterations 15–19)

- Steady widget progress: borders (16), checkbox (17–18), radio button (19)
- All new widgets follow established pattern: WidgetKind + dispatch + draw + layout + tests + demo
- Code growth is proportional — no bloat detected
- Module sizes reasonable: draw.zig 510, dispatch.zig 375, layout.zig 413, widget.zig 180

## Next

1. Fix demo to not require manual kill — add timeout or headless mode (user inbox complaint)
2. Extract slider thumb width to style (hardcoded in draw.zig and dispatch.zig)
3. Design review at iteration 25
4. Text input widget (stretch)

## What's Wrong

- **Demo pops up windows requiring manual kill** — top priority per user feedback
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- Font loading uses popen("fc-match") — fragile
- Slider thumb width (16px) hardcoded in draw.zig and dispatch.zig
- Radio button circle rendering depends on renderer corner_radius support
