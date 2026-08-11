# goop

[![ci](https://github.com/psyclyx/goop/actions/workflows/ci.yml/badge.svg)](https://github.com/psyclyx/goop/actions/workflows/ci.yml)

Goop is a set of composable retained-UI libraries for Zig. It does not own the
application model, event loop, window, frame lifecycle, or rendering pipeline.

> [!WARNING]
> Goop is pre-1.0. The seams described here are implemented, but the widget and
> C APIs can still change.

## Pick the layers you need

- A game HUD can use `goop` for interaction and layout, visit resolved
  elements with a custom look, and write straight into the game's renderer.
- A game tool can add `goop_components`, a small set of allocation-free visual
  building blocks, while retaining its own look and renderer.
- A desktop-style tool can add `goop_desktop` for commands and shortcuts, and
  optionally `goop_chrome` for the stock look.
- The shipped demos compose the full optional stack: desktop semantics, core,
  Chrome, Snail text preparation, Vulkan rendering and presentation, and
  Wayland.

There is no required rendering adapter or application framework between these
choices. See [the architecture guide](docs/architecture.md) for the dependency
graph and ownership rules.

## Core data flow

The caller builds a tree, supplies normalized `goop_input.Event` values, runs
layout, and receives an ordered borrowed `ControlEvents` batch:

```zig
const goop = @import("goop");

var context = try goop.Context.init(allocator, .{
    .width = 1280,
    .height = 720,
});
defer context.deinit();

const root = try context.tree.addRoot(.{ .container = .{} });
_ = try context.tree.addChildControl(root, .{
    .identity = .{
        .element_id = .init(1),
        .action_id = .init(10),
    },
    .widget = .{ .button = .{ .label = "Open" } },
});

context.doLayout(text_measure); // null selects the rough fallback
try context.pushEvent(.{ .mouse_move = .{ .x = 96, .y = 48 } });
const events = try context.processEvents();

for (events.items) |event| switch (event) {
    .activated => |activation| {
        if (activation.action) |action| {
            if (action == goop.ActionId.init(10)) openProject();
        }
    },
    .text_changed => |change| updateName(events.text(change)),
    .selection_changed => |change| updateSelection(events.selection(change)),
    else => {},
};
```

`ElementId` is stable application identity; `ActionId` is stable command
identity. `NodeHandle` is only a generation-checked structural locator used
while constructing or projecting a tree. Application models and controllers
should retain semantic IDs, not handles.

Input is one exact, platform-neutral union: mouse movement and buttons,
scrolling, logical keys plus raw scancodes and modifier snapshots, Unicode
text, focus, and resize. Consecutive queued mouse movements coalesce to the
latest sample; consecutive scroll samples coalesce by summing their deltas.

Semantic output preserves occurrence order and includes activation, secondary
activation, scalar/index/column values, toggles, UTF-8 text, sorting,
selection, scrolling, and drag/drop. The batch and its text/selection payloads
borrow runtime storage until the next processing call or runtime destruction;
copy values that must survive that boundary. Capacity grows explicitly when
needed and is retained for later batches.

One `Runtime` is one interaction/layout domain. `Context` owns one `Tree` and
provides the usual composition. Separate windows or independently focused UI
domains use separate contexts.

## Custom game look and renderer

`visitResolved` is generic, statically dispatched, allocation-free, and
depth-first in logical sibling order. Its exact `enter(ResolvedElement)` and
`leave(ResolvedElement)` calls preserve hierarchy so a look can emit balanced
clips without reconstructing a tree. Each element contains semantic IDs,
parent ID, bounds, resolved style, widget content/state, and interaction state,
but no retained storage handle. The visitor must not mutate the traversed tree;
borrowed widget strings and structural position are valid for the duration of
the call.

The visitor can emit directly into the game's render queue. This example uses
one of Goop's dumb visual components; a custom look can call the encoder
methods directly instead. The complete executable version is
[examples/game_embed.zig](examples/game_embed.zig).

```zig
const goop = @import("goop");
const components = @import("goop_components");
const visual = @import("goop_visual");

const GameEncoder = struct {
    queue: *GameUiQueue,

    pub fn pushClip(self: *@This(), rect: visual.Rect) !void {
        try self.queue.pushClip(rect);
    }
    pub fn popClip(self: *@This()) !void {
        try self.queue.popClip();
    }
    pub fn surface(self: *@This(), value: visual.Surface) !void {
        try self.queue.addSurface(value);
    }
    pub fn text(self: *@This(), value: visual.Text) !void {
        try self.queue.addText(value);
    }
    pub fn icon(self: *@This(), value: visual.Icon) !void {
        try self.queue.addIcon(value);
    }
    pub fn image(self: *@This(), value: visual.Image) !void {
        try self.queue.addImage(value);
    }
    pub fn custom(self: *@This(), value: visual.Custom) !void {
        try self.queue.addGameVisual(value);
    }
};

const GameLook = struct {
    encoder: *GameEncoder,

    pub fn enter(self: *@This(), element: goop.ResolvedElement) !void {
        switch (element.widget) {
            .button => |button| try (components.Button{
                .background = .{
                    .bounds = element.bounds,
                    .color = if (element.pressed)
                        element.style.bg_active
                    else if (element.hovered)
                        element.style.bg_hover
                    else
                        element.style.bg,
                    .border_color = element.style.border,
                    .border_width = element.style.border_width,
                    .corner_radius = element.style.border_radius,
                },
                .label = .{
                    .bounds = element.bounds,
                    .content = button.label,
                    .color = element.style.fg,
                    .font_size = element.style.font_size,
                    .text_align = .center,
                },
                .focus = .{
                    .bounds = element.bounds,
                    .color = element.style.focus_ring,
                    .corner_radius = element.style.border_radius,
                    .visible = element.focused,
                },
            }).emit(self.encoder),
            else => {},
        }
    }

    pub fn leave(_: *@This(), _: goop.ResolvedElement) void {}
};

var encoder = GameEncoder{ .queue = &game.ui_queue };
var look = GameLook{ .encoder = &encoder };
try context.visitResolved(&look);
```

The structural visual contract is precisely seven generic methods:
`pushClip`, `popClip`, `surface`, `text`, `icon`, `image`, and `custom`. Image
operations borrow straight-alpha sRGBA8 pixels identified by an application
resource ID and revision; decoding and lifetime remain caller-owned. The seam owns no
allocator, GPU objects, resource lookup, or frame lifecycle. The optional
`goop_visual.Recorder` stores the same operations when retained recording is
useful; direct encoding does not require it.

## Optional stock Chrome

Chrome is a caller-owned stock look. It is separate from core behavior and
emits the same backend-neutral visual vocabulary:

```zig
const chrome_module = @import("goop_chrome");

var chrome = chrome_module.Chrome.init(allocator);
defer chrome.deinit();

// A changed core revision, text-measure capability, or scope may allocate.
_ = try chrome.prepare(context.chromeState(), .{});

// The matching cached preparation is replayed into the game encoder without
// allocation or a second scene/protocol conversion.
try chrome.emit(context.chromeState(), .{}, &encoder);
```

`prepare` returns a borrowed `goop_visual.List`. A matching cache hit reuses
the stored operations without allocating. Dirty preparation may allocate and
invalidates an older borrowed list. `invalidate` and `deinit` explicitly
discard Chrome-owned storage. Core owns neither the cache nor the stock look.

## Optional native stack

The bundled backend is split at native ownership boundaries:

- `goop_snail` prepares text/vector data without owning a window.
- `goop_graphics_vulkan` owns Vulkan instance/device mechanism and defines the
  minimal `RenderTarget` (`command_buffer`, `extent`, `frame_slot`).
- `goop_render_vulkan` owns UI rendering resources and exposes explicit
  `prepareVisuals`, `updateVisualResources`, and `drawPreparedVisuals` phases.
- `goop_present_vulkan` owns the swapchain, render pass, synchronization, and
  frame lifecycle, and produces a `RenderTarget`.
- `goop_platform_wayland` owns a Wayland window and platform events but knows
  nothing about Vulkan or Goop core.
- `goop_wayland_vulkan` is the sole Wayland/Vulkan WSI join.

The demos' composition roots show all of these calls explicitly; none is
required by a game that already has a window and renderer.

Font and image decoding are likewise composition policy. The desktop demos ask
native Fontconfig for a primary face, explicit emoji face, and priority-ordered
script fallback chain, then pass the
borrowed font bytes to `goop_snail`. Games can pass packaged faces instead and
never link Fontconfig. Text placement supplies an explicit world-to-device
transform so Snail can choose ppem-specific TrueType records and snap glyph
origins to the device grid. Layout's native-em shapes are cached separately
from TT render shapes, whose keys include the exact device ppem; TT misses use
Snail's prepare-advances/reshape/prepare-geometry sequence. The bundled Vulkan
path renders grayscale coverage only; it neither compiles LCD shader families
nor enables dual-source blending. Snail color-bitmap strikes and ordinary
visual images share the renderer-neutral `goop_image.Decoder` contract but use
independent caches/atlases. The native demo composition supplies PNG, JPEG,
and WebP decoding with libspng, libjpeg-turbo, and libwebp; games may supply
their existing asset decoder.

## Using as a Zig dependency

Add Goop to `build.zig.zon`, then request only the package modules that the
application uses:

```zig
.dependencies = .{
    .goop = .{ .path = "../goop" },
},
```

```zig
const goop_dep = b.dependency("goop", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("goop", goop_dep.module("goop"));
exe.root_module.addImport("goop_visual", goop_dep.module("goop_visual"));
exe.root_module.addImport("goop_image", goop_dep.module("goop_image"));
exe.root_module.addImport(
    "goop_components",
    goop_dep.module("goop_components"),
);

// Add these only when the application chooses their policy.
exe.root_module.addImport("goop_desktop", goop_dep.module("goop_desktop"));
exe.root_module.addImport("goop_chrome", goop_dep.module("goop_chrome"));
```

Other exported optional modules are `goop_input`, `goop_ui`, `goop_snail`,
`goop_graphics_vulkan`, `goop_render_vulkan`, `goop_present_vulkan`,
`goop_platform_wayland`, and `goop_wayland_vulkan`.

## Build and examples

Use `nix-shell -A shell` first. The shell pins Zig 0.16.0 and provides the
native dependencies used by the optional demos and Vulkan backend. Native image
decoding is demo composition, not a Goop library dependency; pass
`-Ddemo-image-codecs=false` to typecheck/build the demos without those codecs.

```sh
zig build test                    # all unit, contract, and C example tests
zig build test-core               # renderer-free core
zig build test-visual             # structural visual contract
zig build test-fonts              # Fontconfig fallback + hinted placement
zig build test-image-codecs       # native PNG/JPEG/WebP decoder contract
zig build test-chrome             # optional stock look
zig build test-file-manager       # browser model/projection seams
zig build build-demo              # build the Vulkan widget showcase
zig build build-file-manager-demo # build the full file-browser demo
zig build demo                    # run the showcase on Wayland/Vulkan
zig build file-manager-demo       # run the file browser on Wayland/Vulkan
zig build c-example               # core-only C example
zig build c-chrome-example        # caller-owned Chrome C example
zig build game-embed-example      # core/components into a game-owned queue
```

See [docs/C_API.md](docs/C_API.md) for C ownership and lifetime details,
[docs/DESIGN.md](docs/DESIGN.md) for the core contracts, and
[STATUS.md](STATUS.md) for the current verified snapshot.
