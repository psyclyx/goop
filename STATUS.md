# Status

## Snapshot

`goop` is an embeddable retained-mode GUI library for Zig 0.16. The core owns
the widget tree, layout, event dispatch, and draw command generation. The demo
is a Wayland embedder with EGL/OpenGL rendering and `snail` text support.

Current baseline: 80 tests pass, `zig build` is clean, and the demo runs.

## Recent Progress

- Generational widget handles with subtree removal
- Draw-list caching behind `draw_dirty`
- Pixel-snapped text positioning in the demo renderer
- `xkbcommon`-driven keyboard input in the demo

## Next Priorities

1. Toolbar/menu bar widget
2. Embedder-provided font path instead of `popen("fc-match")`
3. C API bindings
4. HiDPI scaling

## Known Issues

- Font loading uses `popen("fc-match")`, which is fragile and Linux-only
- MSAA sample count is hardcoded to `4` with no capability fallback
- Text input only handles printable ASCII; UTF-8 editing is not implemented
- The demo clipboard path does not yet use the real Wayland clipboard
- No toolbar/menu widget yet
- No HiDPI scaling; the demo treats surface size as physical pixels
- No C API yet
- `freeDrawList` is a no-op for compatibility; `Context` owns draw-list memory
- `widget.zig` grew significantly with removal logic and should be watched

## Historical Notes

The previous iteration-by-iteration workflow has been retired. Historical
records from that loop live in `docs/archive/`.
