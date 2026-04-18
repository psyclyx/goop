# Status

## Current

Iteration 8. Implemented Wayland+EGL+OpenGL demo — opens a window, renders
goop draw commands as colored rects with rounded corners, handles mouse events.
Core pipeline fully wired: build tree → layout → dispatch events → draw → render.
13/13 tests pass. Demo runs and renders on Wayland compositors.

## Iteration Count

8

## Done This Iteration

- Wayland demo: connects to compositor, creates xdg_toplevel window
- EGL/GL3.3 setup: core profile context, shader-based quad rendering
- GL renderer (demo/render.zig): draws DrawRect with rounded corners via SDF fragment shader
- Text placeholder: renders semi-transparent colored rects for text position/size
- Mouse input: pointer motion, button press/release, scroll — translated to goop events
- Click detection works: button clicks logged to stderr
- Window resize handled via xdg_toplevel configure
- Generated xdg-shell protocol bindings (demo/protocol/)

## Next

1. Replace stub text measurement with snail integration
2. Integrate snail GPU text rendering in the demo renderer
3. Slider drag interaction (press on thumb, track mouse_move while held)

## What's Wrong

- Text is rendered as placeholder rects, not actual glyphs — needs snail
- Text measurement is still a rough approximation (font_size * 0.6 per char)
- No frame callback — redraws on every Wayland event batch, not paced
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Slider has no drag interaction — only visual, no mouse control
- No keyboard/focus navigation
- No border rendering on rects
- Demo uses page_allocator everywhere — no arena/frame allocator
- pushEvent takes allocator param on every call (queue could own allocator)
