# goop Design

## Overview

`goop` is a retained-mode, embeddable GUI library for Zig 0.16. The library
does not own the window, platform event loop, or renderer lifecycle. The
embedder creates a `Context`, builds a widget tree, pushes input events, runs
layout, and consumes draw commands.

## Goals

- Keep the core independent from windowing and rendering backends
- Use simple, explicit data structures over framework-heavy abstractions
- Let embedders own integration details such as font loading, platform input,
  and swap timing
- Keep rendering optional: the core emits draw data, not GPU commands

## Non-Goals

- Owning the native event loop
- Shipping a full application framework
- Hiding platform input behind a complex adapter layer
- Baking a renderer backend into the core API

## Architecture

### Public API

`src/goop.zig` exposes the core modules and the `Context` type. `Context`
owns:

- the widget tree
- queued input events
- mouse/focus interaction state
- the active theme
- layout and draw dirty flags
- a cached draw list

The public flow is:

1. Create a `Context`
2. Add or remove widgets in the retained tree
3. Push input events
4. Run layout
5. Process events
6. Generate draw commands

### Widget Tree

`src/core/widget.zig` stores widgets in an array-backed tree with sibling links.
Handles are generational:

- `NodeHandle = { index, generation }`
- stale handles are rejected
- removed slots go onto a free list and can be reused safely
- removal is subtree-recursive

Current widget kinds:

- container
- text
- button
- checkbox
- radio button
- tree item
- dropdown
- list box
- selectable
- table
- table row
- table cell
- menu bar
- menu
- popup
- tooltip
- menu item
- drag value
- spinbox
- tab bar
- tab item
- splitter
- slider
- scroll area
- text input

### Event Model

`src/core/event.zig` defines platform-neutral events. The embedder is expected
to map native input into:

- mouse move
- mouse button
- mouse scroll
- key
- text
- focus
- resize

`src/core/dispatch.zig` applies those events to widget state. The embedder is
also responsible for text input sourcing and logical key mapping. Secondary
clicks are surfaced back to the caller so native context menus remain an
embedder decision, while the retained tree can also express in-canvas popup
menus when that is preferable.

### Layout

`src/core/layout.zig` uses vendored `clay` for layout. The layout pass walks the
retained tree, emits Clay elements, and writes the resulting rectangles back to
the widget nodes.

Text measurement is injected by the embedder through `TextMeasureCtx`:

- if present, layout and text interaction use real measurements
- if absent, fallback behavior uses a rough width approximation

This keeps the core independent from any specific font stack.

### Draw Generation

`src/core/draw.zig` turns the laid-out tree into a `DrawList` containing:

- rectangle commands
- text commands
- clip commands

The core does not issue GPU calls. The repo currently ships one renderer in
`demo/render.zig`, used by the Wayland demo.

`Context.generateDrawList()` caches the last draw list and reuses it when
`draw_dirty` is false. `freeDrawList()` is currently a compatibility no-op
because the `Context` owns cached draw memory.

## Demo Integration

`demo/main.zig` is the reference embedder:

- Wayland surface and event handling
- EGL/OpenGL setup
- `xkbcommon` keyboard translation
- `snail` font atlas/text measurement integration
- frame-callback-paced redraw scheduling

The demo is useful as both a sample app and an integration test for the current
core API.

## Current Constraints

- Font discovery still shells out to `fc-match`
- Text input editing is ASCII-only
- Clipboard support in the demo is not wired to the real Wayland clipboard
- The demo assumes 1:1 surface size to physical pixels
- There is no C API yet
- There are no sortable/resizable table columns yet
- MSAA configuration is fixed at 4x with no fallback path

## Current Direction

Near-term work is focused on:

1. Polishing denser data-view widgets with sorting, resizing, and richer selection
2. Removing the `fc-match` dependency from font loading
3. Adding a C-facing API layer
4. Improving runtime portability and display scaling behavior

## History

The old iteration-based development loop is no longer the active workflow.
Historical design reviews are preserved in `DESIGN_HISTORY.md`, and iteration
summaries are preserved in `docs/archive/`.
