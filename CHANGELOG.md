# Changelog

All notable changes to `goop` will be documented here. The project follows
[Semantic Versioning](https://semver.org). Pre-1.0 releases may include
breaking changes between minor versions.

## Unreleased

### Changed

- Cut over to Snail 0.13 and its CPU-side font/Faces/PagePool/Atlas API.
- Split declarative UI, dumb components, retained driving, display deltas,
  Snail adaptation, Vulkan graphics, Vulkan rendering, Vulkan presentation,
  Wayland platform handling, and Wayland/Vulkan WSI into named Zig modules.
- Replaced the EGL/OpenGL demos with a Vulkan file browser whose model,
  controller, view, GPU ownership, and composition root are separate modules.
- Added stable command reconciliation, old/new-bound damage tracking, a
  persistent Vulkan composition image, and no-damage frame elision.
- Removed the retired GL renderer, EGL utilities, screenshot tool, and legacy
  monolithic browser implementation.

## 0.1.1 — 2026-05-10

### Fixed

- CI screenshot regression couldn't initialize EGL on headless GitHub
  runners. `shell.nix` now provides `mesa` and exports
  `__EGL_VENDOR_LIBRARY_FILENAMES`, `LIBGL_ALWAYS_SOFTWARE=1`, and
  `GALLIUM_DRIVER=llvmpipe` when `GOOP_FORCE_SOFTWARE_GL` is set in the
  calling environment. Local developers with hardware GL are unaffected.

No library changes.

## 0.1.0 — 2026-05-10

First preview release.

### Public API

- Retained widget tree with generational handles and subtree removal.
- 31 widget kinds: container, spacer, text, button, checkbox, radio
  button, tree item, dropdown, popup, tooltip, menu bar / menu / menu
  item, list box, selectable, grid selector, grid item, table / row /
  cell, toolbar, status bar, drag value, spinbox, slider, text input,
  tab bar / tab item, splitter, scroll area, custom.
- `Context` (single-tree convenience) and `Runtime` (multi-tree
  primitive) with thin-forward symmetry. `WidgetDesc` for construction,
  `NodeView` / `WidgetView` for reads, `mutateKind` / `setStyle` /
  `updateWidget` / `setCustomPaint` for writes.
- Per-kind `internal` substructs hide dispatch/paint-owned per-frame
  state (drag rects, marquee, editor buffers) from embedders.
- Platform-neutral `Event` model (mouse, key, text, focus, resize)
  with a `Modifiers` bitmask carried on key/mouse events.
- `PaintCommand` output (`surface`, `text`, `clip`, `icon`, `custom`)
  consumed by an embedder-owned renderer or backend-specific lowering layer.
- Per-widget style overrides via `Style` (resolved against `Theme`).
- Optional `TextMeasureCtx` injection for accurate text sizing.
- Optional `Clipboard` callback interface for cut/copy/paste in text
  inputs.
- C API in `include/goop.h` mirroring the Zig surface; `libgoop`
  ships as both static archive and shared library.

### Reference embedders

- Wayland / EGL / OpenGL demo (`zig build demo`).
- File-manager demo backed by the real filesystem (`zig build
  file-manager-demo`).
- Headless rendering pipeline used for CI screenshot regression
  (`zig build screenshot`).
- Headless C API example (`zig build c-example`).

### Known limitations

- Text editing is codepoint-aware UTF-8 but not grapheme-cluster-aware;
  IME composition is not implemented.
- MSAA sample count is hardcoded to 4× with no capability fallback.
- The public API may still shift between minor versions until 1.0.
