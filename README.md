# goop

Retained-mode GUI library for Zig 0.16. `goop` is meant to be embedded inside
another application. It owns widget state, layout, and draw command generation;
the embedder owns the window, input delivery, and final rendering.

## Current State

- Core widget tree with generational handles and subtree removal
- Layout via vendored `clay`
- Draw command generation with cached draw lists when nothing changed
- Widgets: container, text, button, checkbox, radio button, tree item,
  dropdown, list box, selectable, table, table row, table cell, menu bar,
  menu, popup, tooltip, menu item, drag value, spinbox, tab bar, tab item, splitter,
  slider, scroll area, text input
- Secondary-click reporting for caller-owned context menu handling, with
  optional in-canvas popup/menu composition
- Wayland demo with EGL/OpenGL rendering, `xkbcommon` key handling, and
  `snail` text measurement/rendering

## Repo Layout

```text
goop/
├── src/
│   ├── goop.zig          # public API
│   └── core/             # widget tree, events, layout, draw generation
├── demo/
│   ├── main.zig          # Wayland embedder + demo app
│   └── render.zig        # OpenGL renderer used by the demo
├── vendor/clay/          # vendored layout engine
├── docs/
│   ├── DESIGN.md         # current architecture and constraints
│   └── archive/          # historical notes from the old iteration loop
├── STATUS.md             # current priorities and known issues
└── build.zig
```

## Build / Test

Use `nix-shell` first. The shell provides `harfbuzz` and the rest of the demo's
native dependencies.

```bash
nix-shell
zig build
zig build test
zig build demo
```

`zig build demo` builds and runs the Wayland demo.

## Working Docs

- [STATUS.md](STATUS.md): current snapshot, priorities, known issues
- [docs/DESIGN.md](docs/DESIGN.md): current architecture and design constraints
- [DESIGN_HISTORY.md](DESIGN_HISTORY.md): preserved design reviews from the old loop
- `docs/archive/`: historical iteration summaries

## Near-Term Priorities

1. Sortable table headers and richer selection models
2. Embedder-provided font path instead of `popen("fc-match")`
3. C API bindings
4. HiDPI scaling in the demo/runtime model
