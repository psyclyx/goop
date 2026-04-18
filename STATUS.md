# Status

## Current

Iteration 16. Added SDF-based border rendering to the GL33 rect shader.
14/14 tests pass. Build clean. Demo runs.

## Iteration Count

16

## Done This Iteration

- Added u_border_color and u_border_width uniforms to the rect fragment shader
- Shader uses existing SDF distance to blend border color near edges
- Border data was already flowing through DrawRect — renderer was ignoring it

## Next

1. Checkbox widget
2. Demo: run with timeout, add screenshot/headless capture for review
3. Extract slider thumb width to style (currently hardcoded in draw.zig and dispatch.zig)
4. Chore cycle (iteration 20)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Scroll values accumulate unbounded — no clamping to content bounds
- Text baseline y-offset is approximate (y + font_size)
- No keyboard/focus navigation
- Demo uses page_allocator everywhere — no arena/frame allocator
- Font loading uses popen("fc-match") — works but fragile
- Slider thumb width (16px) is hardcoded in both draw.zig and dispatch.zig
- Demo has no timeout or headless capture — can hang, requires manual kill
- Border rendering not yet visually verified — needs demo screenshot
