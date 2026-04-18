# goop Design

## Overview

Retained-mode GUI library. Zig 0.16. Embeddable. No window ownership.

## Core Architecture

- **Widget tree**: retained data structure, user builds and mutates it
- **Event dispatch**: embedder pushes events as tagged unions, goop routes them
- **Layout**: delegated to clay (vendored C library)
- **Draw data**: core emits draw lists (vertices, textures, clips)
- **Renderers**: optional modules that consume draw data (GL 3.3, GL 4.4, Vulkan)

## Key Decisions

- Clay for layout — proven, fast, C, easy to vendor
- Snail for text — GPU Bezier rendering, already maintained by us
- Renderers are separate from core — embedder chooses or brings their own
- C API wraps the Zig API, not the other way around

## Design Review — Iteration 10

### Decided (implemented)

- **Text measurement abstracted from core.** layout.zig uses MeasureTextFn
  function pointer + opaque context. Snail adapter lives in demo.
- **Context owns its event queue allocator.** pushEvent uses Context's
  allocator. No per-call allocator parameter.

### Deferred (waiting for 3x signal)

- **Widget tree mutation/removal.** Handles are raw indices — removal needs
  generational indices or tombstones. No real need yet (demo builds tree once).
  Decide when dynamic content forces the issue.
- **Interaction result separation.** Button.clicked lives on widget data,
  mixed with persistent state. Works for one interaction type. If we add
  double-click, right-click, or drag-end, extract to a separate results
  structure.
- **Scroll clamping.** Scroll values accumulate unbounded. Needs content
  height from layout to clamp properly — address with scroll area improvements.

### Validated

- Clay integration pattern (widget tree → clay elements → rects back)
- Draw command model (rect/text/clip tagged union)
- Event dispatch with hit testing (linear scan, fine for current scale)
- Module boundaries: event types → dispatch → draw generation
- Theme + per-widget Style override pattern

## Design Review — Iteration 25

### Codebase snapshot

3171 LOC total. 29 tests pass. 7 widget types.

| File | Lines | Role |
|------|-------|------|
| dispatch.zig | 682 | Event processing, hit testing, focus |
| draw.zig | 542 | Draw command generation |
| layout.zig | 413 | Clay integration |
| goop.zig | 275 | Public API |
| widget.zig | 180 | Widget tree data |
| style.zig | 99 | Theme/style |
| event.zig | 63 | Event types |
| demo/main.zig | 640 | Wayland demo |
| demo/render.zig | 277 | GL33 renderer |

### Decided

- **Scroll clamping done.** Resolved from iteration 10 deferred list.
  Content bounds now clamped each frame.

### Observations (act when 3x or blocking)

- **dispatch.zig approaching size threshold.** 682 lines, ~365 are tests.
  If it grows past ~800, extract focus.zig (focusNext/focusPrev/syncFocusFlags)
  and hittest.zig (hitTest/pointInRect/isInteractive).
- **Interaction bg selection duplicated 3x** in draw.zig (button, checkbox,
  radio button). Extract when a 4th widget needs it.
- **Magic numbers** for focus ring inset (-2) and checkbox/radio indicator
  inset (3). Move to Theme when styling becomes configurable.

### Deferred (still waiting)

- **Widget tree mutation/removal.** Still append-only. No dynamic content
  forces the issue yet.
- **Interaction result separation.** Still just .clicked on widget data.
  Wait for double-click/drag-end to force extraction.

### Validated (new)

- Widget addition pattern: ~80 lines across 4 files. Clean.
- Focus navigation via Tab/Shift+Tab. Enter/Space activation.
- Core-demo decoupling: core has zero demo dependencies.
- Keyboard event model (Keycode enum + scancode mapping in demo).
