# Status

Goop is pre-1.0 and targets Zig 0.16.0. This file is a short description of the
current tree; architecture contracts and examples live in
[docs/architecture.md](docs/architecture.md) and [docs/DESIGN.md](docs/DESIGN.md).

## Implemented

- Separate exported modules for identity, normalized input, geometry, visual
  operations, core, desktop semantics, dumb visual components, stock Chrome,
  Snail preparation, Vulkan device/render/presentation, Wayland, and the single
  Wayland/Vulkan WSI bridge.
- Stable `ElementId`/`ActionId` control descriptions and an ordered borrowed
  semantic output journal covering activation, values, toggles, text, sort,
  selection, scroll, and drag/drop.
- Allocation-free, generic `visitResolved` traversal for custom looks, yielding
  balanced structural entry/exit and handle-free `ResolvedElement` values.
- Allocation-free structural visual encoding through clip, surface, text,
  icon, decoded image, and custom operations; an explicitly allocating
  optional recorder.
- Allocation-free visual components with no behavior or backend dependencies.
- Passive icon values for standalone, tree, and grid content, with stock
  Chrome and C ABI parity but no interaction behavior in the icon component.
- Caller-owned stock Chrome with explicit dirty preparation and no-allocation
  cache hits/replay.
- A Vulkan renderer that consumes a minimal caller-supplied render target and
  exposes CPU preparation, GPU resource update, and draw phases separately.
- An optional Skia (GPU/Ganesh-on-Vulkan) renderer (`goop_render_skia`, behind
  `-Dskia`) that draws the same `goop_visual` vocabulary on the shared
  `goop_graphics_vulkan` device. Clips, surfaces, and Skia-font text render on
  the GPU and are verified offscreen, including wrapping a caller-owned
  `VkImage` as a render target. It auto-selects GPU vs CPU raster
  (`GOOP_SKIA_BACKEND={vulkan,cpu}` overrides). On-screen output is wired via
  `WindowTarget` + the `skia-window` example (swapchain acquire/render/present);
  that path needs a display and is not covered by the headless suite. Icon/image
  ops remain.
- Native Fontconfig fallback composition in the desktop demos and explicit
  Snail device-grid placement with ppem-specific TrueType hinting and
  grayscale-only Vulkan coverage.
- Snail 0.19 bitmap-glyph preparation plus renderer-neutral application image
  resources. Native PNG/JPEG/WebP decoding is supplied by libspng,
  libjpeg-turbo, and libwebp at the demo composition root; the file manager
  previews supported image files without coupling its model/view to a codec or
  renderer.
- Scroll areas derive overflow from logical content extent, hide bars when no
  scrolling is possible, and expose neutral/hovered/active thumb state without
  application styling.
- Core-only and stock-Chrome C libraries/examples; see
  [docs/C_API.md](docs/C_API.md).
- A showcase and file manager migrated to semantic output and explicit
  composition. The file-manager controller is separated from tree, graphics,
  and platform ownership; its view receives focused input/output capabilities.
- An executable game-embedding acceptance example that imports only core,
  visuals, and components and writes directly into a game-owned command queue.

## Verification commands

```sh
zig build test
zig build test-core
zig build test-desktop
zig build test-visual
zig build test-fonts
zig build test-image-codecs
zig build test-chrome
zig build test-render-vulkan
zig build test-file-manager
zig build build-demo
zig build build-file-manager-demo
zig build game-embed-example
```

The full suite and native demos require the dependencies supplied by
`nix-shell -A shell`. `GOOP_DEMO_FONT_PATH` can select the demo font explicitly.
`-Ddemo-image-codecs=false` replaces the native codec composition with an
explicit unsupported-codec capability for renderer-neutral build checks.

## Known limitations

- The API remains unstable before 1.0.
- Text editing is Unicode-codepoint-aware but not grapheme-cluster-aware; IME
  composition is incomplete.
- The bundled Vulkan renderer uses fixed assumptions, including 4x MSAA,
  rather than a complete capability/fallback matrix.
- `visitResolved` intentionally leaves multiple-root order unspecified and
  leaves floating-layer policy to the custom look.
- The shipped visual component set is small; custom looks commonly combine it
  with application-owned visuals.
