# goop

[![ci](https://github.com/psyclyx/goop/actions/workflows/ci.yml/badge.svg)](https://github.com/psyclyx/goop/actions/workflows/ci.yml)

Goop is a set of composable retained-UI libraries for Zig. It provides tree
construction, interaction, layout, and a backend-neutral visual vocabulary. It
does not own the application model, event loop, window, frame lifecycle, or
rendering pipeline; the caller supplies those and links only the layers it uses.

> [!WARNING]
> Pre-1.0, targeting Zig 0.16.0. The module seams described here are
> implemented, but the widget and C APIs can still change.

## Layers

Each capability is a separate module. Add only what the application needs.

- `goop` — tree construction, interaction, layout, and resolved-element
  traversal. No renderer.
- `goop_input` — the normalized input event union.
- `goop_visual` — backend-neutral visual operations and the `Recorder`.
- `goop_components` — allocation-free visual building blocks with no behavior or
  backend dependency.
- `goop_desktop` — commands and keyboard shortcuts.
- `goop_chrome` — a caller-owned stock look built on the visual vocabulary.
- Renderers: `goop_render_skia` (GPU/Ganesh, recommended) or `goop_render_vulkan`
  (the original snail path). See [Rendering backends](#rendering-backends).
- Native backend: `goop_snail` (text/vector preparation),
  `goop_graphics_vulkan`, `goop_present_vulkan`, `goop_platform_wayland`, and
  `goop_wayland_vulkan` (the sole Wayland/Vulkan join). Each is split at its
  native ownership boundary.

There is no required rendering adapter or application framework between these
choices. See [docs/architecture.md](docs/architecture.md) for the dependency
graph and ownership rules.

## Core loop

The caller builds a tree, feeds normalized input, runs layout, drains an ordered
batch of semantic events, then advances time-driven state such as tooltips and
animation.

```zig
const goop = @import("goop");

var context = try goop.Context.init(allocator, .{ .width = 1280, .height = 720 });
defer context.deinit();

const root = try context.tree.addRoot(.{ .container = .{} });
_ = try context.tree.addChildControl(root, .{
    .identity = .{ .element_id = .init(1), .action_id = .init(10) },
    .widget = .{ .button = .{ .label = "Open" } },
});

context.doLayout(text_measure); // null selects the rough fallback
try context.pushEvent(.{ .mouse_move = .{ .x = 96, .y = 48 } });

const events = try context.processEvents();
for (events.items) |event| switch (event) {
    .activated => |a| if (a.action) |id| {
        if (id == goop.ActionId.init(10)) openProject();
    },
    .text_changed => |c| setName(events.text(c)),
    .selection_changed => |c| setSelection(events.selection(c)),
    else => {},
};

// now_ms is the caller's monotonic clock, in milliseconds.
const status = context.update(now_ms);
// status.changed          -> a redraw is needed
// status.next_deadline_ms -> when to wake next, or null if nothing is pending
```

### Identity and data flow

- `ElementId` is stable application identity; `ActionId` is stable command
  identity. `NodeHandle` is a generation-checked structural locator used only
  while building or projecting a tree. Retain semantic IDs, not handles.
- Input is one platform-neutral union: pointer motion and buttons, scroll,
  logical keys with raw scancodes and modifier snapshots, Unicode text, focus,
  and resize. Queued pointer moves coalesce to the latest sample; scroll samples
  coalesce by summing their deltas.
- `processEvents` returns an ordered batch preserving occurrence order:
  activation, secondary activation, scalar/index/column values, toggles, UTF-8
  text, sort, selection, scroll, popup visibility, and drag/drop. The batch and
  its text/selection payloads borrow runtime storage until the next processing
  call or runtime destruction; copy anything that must outlive that boundary.
- `update(now_ms)` is the only time input. It advances clock-driven state and
  reports whether a redraw is needed and the next wake-up deadline; without it,
  tooltips and animations do not progress.

One `Runtime`, wrapped by `Context`, is one interaction and layout domain.
Separate windows or independently focused domains use separate contexts.
`pointerCursor()`, `draggedElementId()`, and `focusedElementId()` expose the
current interaction state to the host.

## Custom look and renderer

`visitResolved` is generic, statically dispatched, allocation-free, and
depth-first in logical sibling order. It calls `enter(ResolvedElement)` and
`leave(ResolvedElement)` in balanced pairs, so a look can emit nested clips
without reconstructing a tree. Each element carries semantic IDs, bounds,
resolved style, widget content and state, and interaction flags — but no storage
handle. The visitor must not mutate the traversed tree.

The visitor writes into any encoder that implements seven methods: `pushClip`,
`popClip`, `surface`, `text`, `icon`, `image`, and `custom`. `image` borrows
straight-alpha sRGBA8 pixels identified by an application resource ID and
revision; decoding and lifetime stay caller-owned. `icon` carries an application
`IconId` or a `StockIcon` from the built-in set. The seam owns no allocator, GPU
object, resource lookup, or frame lifecycle.

```zig
const GameLook = struct {
    encoder: *GameEncoder,

    pub fn enter(self: *@This(), e: goop.ResolvedElement) !void {
        switch (e.widget) {
            .button => |button| try (components.Button{
                // ... map resolved bounds/style into a component ...
            }).emit(self.encoder),
            else => {},
        }
    }

    pub fn leave(_: *@This(), _: goop.ResolvedElement) void {}
};

try context.visitResolved(&look);
```

The complete compiling version is
[examples/game_embed.zig](examples/game_embed.zig). `goop_components` supplies
ready-made encoders for common widgets; `goop_visual.Recorder` optionally
retains the same operations when direct encoding is not wanted.

## Stock Chrome

`goop_chrome` is a caller-owned stock look, separate from core behavior, that
emits the same backend-neutral visual vocabulary.

```zig
const chrome_module = @import("goop_chrome");

var chrome = chrome_module.Chrome.init(allocator);
defer chrome.deinit();

// prepare returns a borrowed goop_visual.List; a matching cache hit does not
// allocate. Dirty preparation may allocate and invalidates an older list.
_ = try chrome.prepare(context.chromeState(), .{});

// emit replays the cached preparation into the encoder without a second
// scene conversion.
try chrome.emit(context.chromeState(), .{}, &encoder);
```

`invalidate` and `deinit` explicitly discard Chrome-owned storage. Core owns
neither the cache nor the stock look.

## Rendering backends

A renderer consumes the backend-neutral `goop_visual` operations. Two exist;
they share the Vulkan device, WSI, presentation, and window layers, and differ
only in the renderer.

### Skia (GPU) — recommended

`goop_render_skia` renders the visual vocabulary with Skia's GPU backend
(Ganesh on Vulkan) and is the recommended backend. It binds a `GrDirectContext`
to the shared `goop_graphics_vulkan` device and draws clips, surfaces, and text
(via Skia's own `SkFont`/fontconfig stack) onto GPU surfaces. Skia is C++, so it
links `libskia` through a small POD-only C-ABI shim compiled by the system g++;
enable it with `-Dskia`. The renderer picks GPU (Ganesh) or Skia's CPU raster
path automatically — GPU only for a real GPU, CPU raster otherwise (including
software Vulkan such as lavapipe); override with
`GOOP_SKIA_BACKEND={vulkan,cpu}`. It is new and opt-in. The surface/text/clip
vocabulary renders and is verified offscreen on a real GPU (including wrapping a
caller-owned `VkImage`). On-screen output is wired through `WindowTarget`
(swapchain acquire → render → present) and the `zig build skia-window -Dskia`
example; that path needs a Wayland compositor and a real GPU and is not
exercised by the headless test suite. Icon and image ops are the remaining gap.

### snail + Vulkan — the original path

`goop_render_vulkan` is goop's own renderer over `goop_snail`'s prepared
text/vector data. goop was originally written to stress-test snail — it is a 2D,
affine-only UI toolkit, which makes it a bad fit for snail, but it works. This
path remains for that lineage and for callers already invested in it.

## Native stack

Below the renderer, the bundled backend is split at native ownership boundaries.
A game that already has a window and renderer needs none of it.

- `goop_snail` — text and vector preparation; owns no window.
- `goop_graphics_vulkan` — Vulkan instance and device; defines the minimal
  `RenderTarget` (`command_buffer`, `extent`, `frame_slot`). Shared by both
  renderers.
- `goop_render_vulkan` / `goop_render_skia` — the two renderers above.
- `goop_present_vulkan` — swapchain, render pass, synchronization, and frame
  lifecycle; produces a `RenderTarget`.
- `goop_platform_wayland` — Wayland window and platform events; knows nothing
  about Vulkan or Goop core.
- `goop_wayland_vulkan` — the sole Wayland/Vulkan WSI join.

Font and image decoding are composition policy, not library dependencies. The
desktop demos ask Fontconfig for a primary face, an emoji face, and a
priority-ordered fallback chain, pass the borrowed bytes to `goop_snail`, and
decode PNG, JPEG, and WebP with libspng, libjpeg-turbo, and libwebp behind the
renderer-neutral `goop_image.Decoder`. The bundled Vulkan path renders grayscale
coverage only. A game can supply packaged faces and its own decoder instead.

## Using as a Zig dependency

Add Goop to `build.zig.zon`, then import only the modules the application uses.

```zig
.dependencies = .{
    .goop = .{ .path = "../goop" },
},
```

```zig
const goop_dep = b.dependency("goop", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("goop", goop_dep.module("goop"));
exe.root_module.addImport("goop_visual", goop_dep.module("goop_visual"));

// Add the rest as their policy is chosen: goop_input, goop_image,
// goop_components, goop_desktop, goop_chrome, goop_snail, goop_graphics_vulkan,
// goop_render_vulkan, goop_present_vulkan, goop_platform_wayland,
// goop_wayland_vulkan. The Skia renderer (goop_render_skia) is gated behind the
// -Dskia build option.
```

## Build and examples

`nix-shell -A shell` pins Zig 0.16.0 and the native dependencies used by the
demos and Vulkan backend. Native image decoding is demo composition; pass
`-Ddemo-image-codecs=false` to build the demos without those codecs.

```sh
zig build test                    # all unit, contract, and C example tests
zig build test-core               # renderer-free core
zig build test-visual             # structural visual contract
zig build test-fonts              # Fontconfig fallback + hinted placement
zig build test-image-codecs       # native PNG/JPEG/WebP decoder contract
zig build test-chrome             # stock look
zig build test-skia -Dskia        # optional Skia GPU backend (needs libskia)
zig build skia-window -Dskia      # on-screen Skia example (needs display + GPU)
zig build test-file-manager       # browser model/projection seams
zig build build-demo              # build the Vulkan widget showcase
zig build build-file-manager-demo # build the file-browser demo
zig build demo                    # run the showcase on Wayland/Vulkan
zig build file-manager-demo       # run the file browser on Wayland/Vulkan
zig build c-example               # core-only C example
zig build c-chrome-example        # caller-owned Chrome C example
zig build game-embed-example      # core + components into a game-owned queue
```

## Documentation

- [docs/architecture.md](docs/architecture.md) — module dependency graph and
  ownership rules.
- [docs/DESIGN.md](docs/DESIGN.md) — core contracts.
- [docs/C_API.md](docs/C_API.md) — C ownership and lifetime details.
- [STATUS.md](STATUS.md) — current verified snapshot.
