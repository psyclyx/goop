# Architecture

Goop is split into modules whose dependency direction is part of the public
contract. A platform or renderer may be replaced without changing component
code, and browser behavior may be tested without a window or GPU.

## Module graph

```text
goop_components → goop_ui ──────────────→ goop_display
                       ↘                ↗
                         goop_driver

goop_render_vulkan → goop_display
        ├──────────→ goop_snail
        ├──────────→ goop_graphics_vulkan
        └──────────→ goop_present_vulkan → goop_graphics_vulkan

goop_wayland_vulkan → goop_graphics_vulkan
goop_platform_wayland             (imports no graphics module)

showcase_view → established goop widget API ← showcase_controller
                                     ↑
showcase_app → paint_bridge ─────────┘
       ├────→ goop_platform_wayland
       └────→ demo_gpu → Vulkan renderer/presenter/WSI modules

file_manager view/fs/state ← file_manager_logic
                                  ↑
file_manager_app → paint_bridge ──┘
       ├────────→ goop_platform_wayland
       └────────→ demo_gpu → Vulkan renderer/presenter/WSI modules
```

The two `app.zig` files are composition roots. They translate platform
events and connect browser/showcase logic to rendering, but do not absorb
the state owned by those subsystems.

## Responsibilities

### `goop_display`

Backend-neutral output: geometry, colors, semantic paint operations, stable
command identities, display deltas, and damage regions. It has no UI,
application, text-engine, graphics-API, or platform dependency.

### `goop_ui`

Declarative element descriptions, styles, stable element identities, and
semantic action identities. It describes what should be displayed and what
semantic action an interactive element represents. It owns no retained
interaction state.

### `goop_components`

An opinionated collection of pure component constructors. Components accept
props and return `goop_ui.Element` values. They may compose other components,
but must not mutate a model, read the filesystem or clock, dispatch events,
or import a renderer or platform.

### `goop_driver`

The retained implementation: tree reconciliation, layout, hit testing,
focus, scrolling, generic widget interaction, semantic action emission, and
display-delta generation. The retained tree is private driver state rather
than component API.

### `goop_snail`

The Snail adapter. It owns fonts, faces, page pools, CPU atlases, shaping,
recording, placement, upload plans, and emitted draw records. It contains no
Vulkan objects and performs no command submission.

### `goop_graphics_vulkan`

Vulkan instance, physical/logical device, queues, memory helpers, and command
infrastructure. It accepts an opaque `VkSurfaceKHR` where presentation
capability must be considered, but knows nothing about Wayland.

### `goop_render_vulkan`

Vulkan UI pipelines, buffers, Snail device-atlas resources, display-delta
application, and rendering into a caller-supplied frame target. It does not
create windows, surfaces, or swapchains.

### `goop_present_vulkan`

Swapchain, frame synchronization, persistent composition target, acquisition,
and presentation. It does not know about UI elements or browser state.

### `goop_platform_wayland`

Wayland connection, windows and surfaces, input, and frame pacing. It emits
backend-neutral input and window events and imports no graphics renderer.
Clipboard, drag-and-drop, outputs, cursors, and popup surfaces belong here
when those capabilities are added.

### `goop_wayland_vulkan`

The intentionally small WSI bridge. It supplies required instance extensions
and creates/destroys a `VkSurfaceKHR` from Wayland handles.

## Browser boundaries

- `file_manager/state.zig` divides runtime references, browser model, view
  handles, interaction state, and transfer buffers into cohesive owners.
- `file_manager/fs.zig` owns directory operations, navigation, sorting, copy,
  move, and delete behavior.
- `file_manager/view.zig` builds the original browser widget tree and semantic
  icon paint without importing Snail, Vulkan, or Wayland.
- `file_manager/controller.zig` drives widget state and browser commands without
  owning platform or GPU resources.
- `file_manager/app.zig` translates platform events and connects paint deltas
  to shared GPU ownership and presentation.
- `showcase/view.zig` and `showcase/controller.zig` preserve the original
  component showcase while keeping its construction and behavior apart.

Wayland callbacks must never import the browser composition root. They write
platform events into a sink. Demo view and controller code must never import
Snail, Vulkan, or Wayland.

## Damage and retained rendering

Every display operation has a stable identity and content fingerprint.
Updating or removing an operation damages its old bounds; inserting or
updating damages its new bounds. The driver emits a `DisplayDelta` instead of
requiring the renderer to rediscover changes.

The Vulkan presenter keeps a canonical persistent composition image. The
renderer redraws only damaged scissors into that image. Presentation may copy
the complete composition image to an acquired swapchain image for
correctness; expensive UI shading and Snail evaluation remain restricted to
damage. With no damage, the application does not acquire, render, or present.

Resize, scale, target-format changes, and uncertain invalidation explicitly
promote damage to a full redraw.

## Ownership rules

- Components own no runtime state.
- The driver owns no application model.
- Snail CPU state owns no GPU object.
- The renderer owns no window or swapchain.
- The presenter owns no UI state.
- The platform owns no renderer.
- Small composition structs may aggregate cohesive subsystem owners; they
  must not flatten all subsystem fields into one application-wide state
  object.
