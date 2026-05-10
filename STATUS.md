# Status

## Snapshot

`goop` is an embeddable retained-mode GUI library for Zig 0.16.0. The core owns
the widget tree, layout, event dispatch, and draw command generation. The demo
is a Wayland embedder with EGL/OpenGL rendering and `snail` text support.

Current baseline: `zig build test` is clean. Use `nix-shell` before
`zig build`; the shell provides `harfbuzz` and the other demo dependencies.
Set `GOOP_DEMO_FONT_PATH` if the demo font is not in one of the built-in
fallback locations.

## Recent Progress

- `Context` forwards every per-handle `Runtime` method (`mutateKind`,
  `setStyle`, `setCustomDraw`, `updateWidget`, `frame`, `invalidate`,
  `focusWidget`, `clearFocus`, `cancelPointerGesture`) plus
  `setTheme`/`setClipboard`. Demo and C wrapper drop ~120 sites of
  `ctx.runtime.X(&ctx.tree, …)` boilerplate
- `WidgetKind` arms separate genuinely-internal per-frame state into
  per-kind `Internal` substructs (`drag`, `marquee_*`, `drop_preview*`,
  `anchor_*`, `column_weights`, editor buffers). `WidgetDesc` already
  prevented construction-time seeding; the `Internal` boundary now
  documents the dispatch/draw-owned region structurally
- `GridDrop`/`ListDrop`/`TableDrop` collapsed into one `ContainerDrop`
  (shape was already identical; `TableDrop.Position.row` aliased to
  `.item`). C ABI matched. Drop union arms (`.grid`, `.list`, `.table`)
  still distinguish container kind
- Embedder-facing tree helpers (`tableHeaderRow`, `tableCellAt`,
  `tableResizeHandleIndexAtPoint`, `gridItemAt`, …) re-exported on
  `goop` so callers don't need to reach into `widget.*`
- Tagged read-only `WidgetView` replaces ~30 per-widget query methods on
  `Runtime`/`Context` and the matching C exports
- `Tree` mutations route through `setStyle`/`updateWidget`/`mutateKind`/
  `setCustomDraw` so the runtime always invalidates layout/draw caches
- `freeDrawList` / `freePaintList` no-ops removed; cached draw lists
  are owned by `Runtime` and freed automatically on invalidation
- C/Zig bool field names synced (no more `disable_*` vs `allow_*` skew)
- `Event.Keycode` expanded to a comprehensive named-key table; new
  `Event.Modifiers` packed bitmask carried on key/mouse events
- `dispatch` is now an internal-only namespace; not re-exported



- HiDPI-aware Wayland demo sizing with logical-vs-buffer dimensions
- UTF-8-safe text input editing, cursor movement, deletion, and clipboard paste
- Demo-side UTF-8 text event delivery and on-demand font atlas growth
- Explicit text draw baselines/content bounds plus better line-height handling
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
- Resizable table columns with retained width fractions
- Sortable table headers with retained sort state
- Multi-select list boxes with Ctrl-toggle and Shift-range behavior
- Table row selection policies with single/multi-select behavior
- Keyboard navigation for selectable lists and table rows
- Toolbar and status-bar structural widgets for editor chrome
- Hover/focus-driven tooltips built on the floating layout path
- Secondary-click reporting plus caller-managed context menu positioning
- Demo font loading no longer shells out through `fc-match`
- Installable C API header plus retained-tree/event/draw wrappers for C
- Headless C API example built and exercised from `zig build test`
- Shared `libgoop` install output alongside the static archive
- Real Wayland clipboard selection in the demo via `wl_data_device_manager`

## Next Priorities

1. Demo/runtime portability polish around the new C surface
2. Broader C API docs/reference coverage
3. Richer text input behavior beyond codepoint-level editing

## Known Issues

- MSAA sample count is hardcoded to `4` with no capability fallback
- Text editing is still codepoint-based; grapheme clusters and IME composition are not implemented
- `widget.zig` grew significantly with removal logic and should be watched
