# Changelog

All notable changes to `goop` will be documented here. The project follows
[Semantic Versioning](https://semver.org). Pre-1.0 releases may include
breaking changes between minor versions.

## Unreleased

### Changed

- Split Goop into independently composable geometry, normalized input,
  semantic identity, core interaction/layout, desktop policy, visual
  component, stock Chrome, rendering, presentation, and platform libraries.
- Replaced retained-handle occurrence polling with stable `ElementId` /
  `ActionId` control descriptions and an ordered borrowed semantic event
  journal.
- Added allocation-free balanced resolved traversal for custom looks and a
  seven-operation structural visual capability that can write directly into an
  application renderer.
- Made stock Chrome an optional caller-owned cache and moved reusable buttons,
  checkboxes, radio buttons, passive icons, surfaces, text, and focus rings
  into visual-only components.
- Split the C artifacts into core-only `libgoop` and optional
  `libgoop_chrome`, with semantic output and caller-owned Chrome lifetimes.
- Cut over to Snail 0.19 and its CPU-side font/Faces/PagePool/Atlas API,
  including the plan/prepare/apply atlas population pipeline.
- Replaced the Vulkan renderer's wrap of snail's demo reference renderer
  (an unpublished snail path) with a goop-owned renderer: goop compiles its
  SPIR-V from snail's slang sources with `slangc` (new `goop_render_shaders`
  module), owns the device atlas and pipelines
  (`src/render/vulkan/device_atlas.zig`, `src/render/vulkan/renderer.zig`),
  and consumes only snail's public data contract and committed shader
  reflection. Building the Vulkan renderer now requires `slangc`
  (shader-slang) on PATH; the nix shell already provides it.
- Migrated both established demos from EGL/OpenGL to the explicit
  Chrome/Snail/Vulkan/presentation/Wayland composition. The file manager now
  reduces semantic events into domain state and retains no widget handle bag.
- Added native Fontconfig fallback-chain composition for the desktop demos,
  explicit device-grid text placement, ppem-specific TrueType hinting, and a
  grayscale-only Vulkan text path with no LCD shader or dual-source feature.
- Corrected TrueType shaping to prepare hinted advances and reshape through
  Snail before placement. Native layout shapes and rendered TT shapes now use
  separate caches, with the latter keyed by exact device ppem.
- Added the renderer-neutral decoded-image/resource seam, passive image
  component, C Chrome image operation, separate Snail/Vulkan application-image
  atlas, and PNG/JPEG/WebP file-manager previews. Native demos compose
  libspng, libjpeg-turbo, and libwebp explicitly; consumers may supply their
  own decoder and renderer unchanged.
- Added Snail color-bitmap glyph support using exact strike/ppem cache keys,
  while retaining grayscale-only outline rendering.
- Made scrollbars self-hide from logical overflow and own their standard idle,
  hovered, and active presentation instead of requiring demo styling.
- Fixed file-browser list/grid icons and made cross-child marquee selection a
  container-owned gesture that publishes once on release and rolls back on
  cancellation.
- Removed the retired GL renderer, EGL utilities, screenshot tool, and
  application-owned Wayland renderer, along with the old paint/display and
  callback-widget compatibility surfaces.

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
