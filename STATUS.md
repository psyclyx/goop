# Status

## Current

Iteration 21. Added demo timeout support.
23/23 tests pass. Build clean. Demo runs.

## Iteration Count

21

## Done This Iteration

- Added `GOOP_DEMO_TIMEOUT` env var: demo exits after N seconds
- Uses poll-based Wayland dispatch (100ms poll timeout) when timeout is active
- Normal (no timeout) path unchanged — still uses blocking `wl_display_dispatch`

## Next

1. Extract slider thumb width to style (hardcoded in draw.zig and dispatch.zig)
2. Design review at iteration 25
3. Text input widget (stretch)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- Font loading uses popen("fc-match") — fragile
- Slider thumb width (16px) hardcoded in draw.zig and dispatch.zig
- Radio button circle rendering depends on renderer corner_radius support
