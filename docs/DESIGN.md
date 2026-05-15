# goop Design

## Overview

`goop` is a retained-mode, embeddable GUI library for Zig 0.16. The library
does not own the window, platform event loop, or renderer lifecycle. The
embedder creates a `Context`, builds a widget tree, pushes input events, runs
layout, and consumes semantic paint commands.

## Goals

- Keep the core independent from windowing and rendering backends
- Use simple, explicit data structures over framework-heavy abstractions
- Let embedders own integration details such as font loading, platform input,
  and swap timing
- Keep rendering optional: the core emits semantic paint data, not GPU commands

## Non-Goals

- Owning the native event loop
- Shipping a full application framework
- Hiding platform input behind a complex adapter layer
- Baking a renderer backend into the core API

## Architecture

### Public API

`src/goop.zig` exposes the core Zig API, and `include/goop.h`/`src/c_api.zig`
provide a thin C-facing wrapper over the same retained runtime. `Context`
owns:

- the widget tree
- queued input events
- mouse/focus interaction state
- the active theme
- layout and paint dirty flags
- a cached paint list

The public flow is:

1. Create a `Context`
2. Add or remove widgets in the retained tree
3. Push input events
4. Run layout
5. Process events
6. Generate a semantic paint list

The C layer mirrors that flow with:

1. `goop_context_create`
2. `goop_context_add_root` / `goop_context_add_child`
3. `goop_context_push_event`
4. `goop_context_do_layout`
5. `goop_context_process_events`
6. `goop_context_generate_draw_list`

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
- toolbar
- status bar
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

### Paint Generation

`src/core/paint.zig` turns the laid-out tree into a `PaintList` containing:

- semantic surface commands
- text commands
- clip commands
- icon commands
- custom embedder commands

The runtime does not expose primitive renderer commands. A renderer can consume
the semantic paint list directly, or a backend-specific adapter can lower it to
whatever primitives that renderer needs. The repo currently ships one renderer
in `demo/render.zig`, used by the Wayland demo.

`Context.generatePaintList()` caches the last paint list and reuses it when
`paint_dirty` is false. The cache is owned by the `Runtime` and freed when
either invalidated by state changes or when the runtime is deinitialized;
embedders never free paint lists themselves.

## Demo Integration

`demo/main.zig` is the reference embedder:

- Wayland surface and event handling
- EGL/OpenGL setup
- `xkbcommon` keyboard translation
- `wl_data_device_manager` clipboard integration
- `snail` font atlas/text measurement integration
- frame-callback-paced redraw scheduling

The demo is useful as both a sample app and an integration test for the current
core API.

## Current Constraints

- Text editing is codepoint-aware UTF-8, but not yet grapheme-cluster-aware
- IME composition and richer platform text input are still incomplete
- MSAA configuration is fixed at 4x with no fallback path

## Current Direction

Near-term work is focused on:

1. Improving text editing beyond the current codepoint-level path
2. Hardening the new C-facing surface and examples
3. Expanding embedder-level samples and validation
