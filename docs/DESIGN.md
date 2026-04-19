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

## Design Review — Iteration 50

### Codebase snapshot

5306 LOC total. 72 tests pass. 8 widget types.

| File | Lines | Role |
|------|-------|------|
| dispatch_text_input_test.zig | 1324 | Text input tests |
| dispatch.zig | 820 | Event processing, hit testing, focus |
| draw.zig | 728 | Draw command generation |
| demo/main.zig | 664 | Wayland demo |
| layout.zig | 488 | Clay integration |
| widget.zig | 348 | Widget tree data |
| goop.zig | 365 | Public API |
| demo/render.zig | 275 | GL33 renderer |
| style.zig | 101 | Theme/style |
| focus.zig | 77 | Focus navigation |
| event.zig | 76 | Event types |
| hittest.zig | 40 | Hit testing |

### Hard questions

1. **Is append-only still acceptable?** The tree has been append-only for 50
   iterations. The demo builds once and never mutates. Any real application
   (dynamic lists, conditional UI, tab switching) will need removal. This is
   the single biggest architectural gap. Generational indices or a free-list
   are the obvious paths. The sibling linked-list pointers make removal
   non-trivial but not hard.

2. **Is the dirty tracking granular enough?** Current tracking is tree-level:
   one bool, reset each frame. This skips layout when the tree structure and
   dimensions are unchanged — a real win. But draw list regeneration has no
   caching at all. For static UI this means redundant work every frame. A
   draw-dirty flag (separate from layout-dirty) would be the minimum next
   step. Per-subtree invalidation is premature.

3. **Is first milestone complete?** Target was: buttons with click feedback,
   text label, slider, scroll area, rendered via GL33 from Wayland. All
   present. Text input, checkbox, radio button went beyond scope. The
   milestone is done. Time to define the next one.

### Decided

- **Text measurement resolved.** Iteration 45 observation about approximate
  char_width is fixed. Real glyph metrics now used for cursor positioning
  and selection via TextMeasureCtx threaded through dispatch and draw.

- **Layout dirty tracking shipped.** Tree-level dirty flag skips clay passes.
  Sufficient for current scale.

### Observations (act when 3x or blocking)

- **draw.zig has no caching.** Draw list regenerated every frame even when
  nothing changed. Add a draw-dirty flag gated on interaction state changes
  and layout recalculation.
- **Font loading uses popen("fc-match").** Works on Linux, breaks everywhere
  else. Needs embedder-provided font path or embedded default font.
- **MSAA hardcoded to 4x.** No capability query or fallback. Will fail on
  some GPUs.
- **No toolbar/menu widget.** Listed in target widget set but unimplemented.
  Toolbar is the last target widget not started.

### Resolved since iteration 25

- **dispatch.zig size** — text input tests extracted (iteration 42).
  dispatch.zig stable at 820 lines.
- **Approximate char_width** — replaced with real text measurement
  (iteration 49).
- **No dirty tracking** — layout dirty tracking added (iteration 46).

### Deferred (still waiting)

- **Widget tree mutation/removal.** Append-only for 50 iterations. Now the
  #1 priority — blocking for any dynamic UI.
- **Interaction result separation.** Still .clicked on widget data. Not yet
  blocking — double-click exists but didn't need a separate results struct.

### Next milestone proposal

**Milestone 2: Dynamic UI.** Ship the ability to add and remove widgets at
runtime. This unblocks conditional UI, dynamic lists, and real applications.
Concrete deliverables:
1. Widget removal API (generational handles or free-list)
2. Draw list caching (draw-dirty flag, skip when unchanged)
3. Toolbar/menu bar widget (last target widget)
4. Embedder-provided font path (remove popen("fc-match"))
