# Changelog

All notable changes to `goop` will be documented here. The project follows
[Semantic Versioning](https://semver.org). Pre-1.0 releases may include
breaking changes between minor versions.

## Unreleased

### Added

- Optional Skia (GPU/Ganesh-on-Vulkan) rendering backend, `goop_render_skia`,
  gated behind `-Dskia`. It consumes the same backend-neutral `goop_visual`
  operations as the snail renderer and reuses the snail-agnostic
  `goop_graphics_vulkan` device; only the renderer differs. Clips, surfaces, and
  text (via Skia's own `SkFont`/fontconfig stack) render on the GPU and are
  verified offscreen. The C++ shim is compiled by the system g++ to share
  libskia's libstdc++ ABI. Icon/image ops and on-screen swapchain presentation
  are in progress.
- The Skia backend auto-selects GPU (Ganesh) or Skia's CPU raster path: GPU only
  for a real GPU, CPU raster otherwise (including software Vulkan like lavapipe).
  `GOOP_SKIA_BACKEND={vulkan,cpu}` (read in the library) overrides the choice.
- Skia can wrap a caller-owned `VkImage` (e.g. an acquired swapchain image) as a
  render target — the primitive on-screen presentation is built on, verified
  offscreen on a real GPU.
- On-screen presentation for the Skia backend: `WindowTarget` owns a swapchain
  and drives acquire → render → present (`flushPresent` waits on the acquire
  semaphore, signals the present semaphore, and transitions to `PRESENT_SRC`),
  with a `zig build skia-window -Dskia` example. This path needs a Wayland
  compositor and a real GPU; it compiles and links but is not exercised by the
  headless test suite. The snail `goop_present_vulkan` path is untouched.
- The file manager demo can render through the Skia backend
  (`zig build file-manager-skia -Dskia`), a separate executable sharing all
  browser logic with the snail demo. Needs a display + real GPU; icon/image ops
  are not yet mapped (icons and previews do not draw) and text is measured with
  the demo font but drawn with Skia's.

## 0.2.0 — 2026-08-18

### Added

- Time-driven `Context.update(now_ms)` (and C `goop_context_update`) returning a
  `changed` flag and next wake-up deadline; tooltips derive visibility from this
  explicit host clock. Added an allocation-free scalar `animation` primitive.
- A backend-neutral stock-icon vocabulary (`StockIcon`) with tonal shading,
  drawn by the Vulkan renderer and used for checked menu items and button icons.
- Win32-style menu access keys: `Alt`+letter opens a menu and a bare letter
  activates an item while a menu is open, with the access key underlined.
- `PopupVisibilityChanged` control events, host pointer-cursor / dragged-element
  accessors, and captured-button press-visual semantics that clear outside the
  button and restore on re-entry.
- Wayland cursor theming, child dialog windows sharing one Vulkan
  instance/device, and external file drag-out. The file-manager demo gains a
  permissions inspector that edits Unix mode bits.

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
