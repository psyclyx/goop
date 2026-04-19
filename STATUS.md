# Status

## Snapshot

`goop` is an embeddable retained-mode GUI library for Zig 0.16. The core owns
the widget tree, layout, event dispatch, and draw command generation. The demo
is a Wayland embedder with EGL/OpenGL rendering and `snail` text support.

Current baseline: `zig build test` is clean. Use `nix-shell` before
`zig build`; the shell provides `harfbuzz` and the other demo dependencies.

## Recent Progress

- Generational widget handles with subtree removal
- Draw-list caching behind `draw_dirty`
- Pixel-snapped text positioning in the demo renderer
- `xkbcommon`-driven keyboard input in the demo
- Tree items for outline-style editors
- Dropdown/popup/menu-item composition for menus and selectors
- Drag values, spinboxes, and structural tab bars/tab items
- Menu bars, menus, submenu popups, and splitters
- List boxes and selectable rows for denser editor selections
- Structural tables with aligned columns, header rows, and striping
- Hover/focus-driven tooltips built on the floating layout path
- Secondary-click reporting plus caller-managed context menu positioning

## Next Priorities

1. Sortable/resizable table columns and richer selection models
2. Embedder-provided font path instead of `popen("fc-match")`
3. C API bindings
4. HiDPI scaling

## Known Issues

- Font loading uses `popen("fc-match")`, which is fragile and Linux-only
- MSAA sample count is hardcoded to `4` with no capability fallback
- Text input only handles printable ASCII; UTF-8 editing is not implemented
- The demo clipboard path does not yet use the real Wayland clipboard
- No HiDPI scaling; the demo treats surface size as physical pixels
- No C API yet
- `freeDrawList` is a no-op for compatibility; `Context` owns draw-list memory
- `widget.zig` grew significantly with removal logic and should be watched

## Historical Notes

The previous iteration-by-iteration workflow has been retired. Historical
records from that loop live in `docs/archive/`.
