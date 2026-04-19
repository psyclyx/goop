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

- **dispatch.zig past size threshold.** 974 lines (~550 tests). Extract
  focus.zig (focusNext/focusPrev/syncFocusFlags) and hittest.zig
  (hitTest/pointInRect/isInteractive). This is now overdue.
- **Magic numbers** for focus ring inset (-2) and checkbox/radio indicator
  inset (3). Move to Theme when styling becomes configurable.

### Resolved since iteration 25

- **Interaction bg selection** extracted to `interactionBg` helper in draw.zig
  (iteration 28).

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

## Chore Review — Iteration 45

### Codebase snapshot

5186 LOC total. 69 tests pass. 8 widget types (incl. text input).

| File | Lines | Role |
|------|-------|------|
| dispatch_text_input_test.zig | 1324 | Text input tests (extracted) |
| dispatch.zig | 824 | Event processing, hit testing, focus |
| draw.zig | 722 | Draw command generation |
| demo/main.zig | 661 | Wayland demo |
| layout.zig | 454 | Clay integration |
| widget.zig | 348 | Widget tree data |
| goop.zig | 285 | Public API |
| demo/render.zig | 274 | GL33 renderer |
| style.zig | 101 | Theme/style |
| focus.zig | 77 | Focus navigation |
| event.zig | 76 | Event types |
| hittest.zig | 40 | Hit testing |

### Review of iterations 40–44

Text input feature now mature: double-click word select, clipboard
(copy/cut/paste via embedder callbacks), mouse interaction complete.
Test extraction cleaned up dispatch.zig (1645→824 lines). Demo mouse
coordinate bug fixed.

### Resolved since iteration 40

- **dispatch.zig size**: text input tests extracted to separate file
  (iteration 42). dispatch.zig now 824 lines — manageable.

### Observations

- **Approximate char_width (font_size * 0.6)** still used for cursor
  positioning and click-to-position. Proper fix needs text measurement
  integration (MeasureTextFn from layout). Blocking for proportional fonts.
- **No dirty tracking.** Full layout + draw list every frame. Not a
  problem at current scale but will be for real apps.
- **Text input test file is large (1324 lines, 34 tests).** Acceptable
  for now since it's isolated, but watch for further growth.

### Deferred (still waiting)

- **Widget tree mutation/removal.** Still append-only.
- **Interaction result separation.** Still just .clicked on widget data.
