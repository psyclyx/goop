# Architecture

Goop is a set of libraries, not an application framework. The caller owns the
model, event loop, effects, frame scheduling, memory policy, and rendering
pipeline. Each Goop layer is usable without importing the layers above it.

## Dependency graph

```text
application model and effects
        |
        +----> goop_desktop --------+
        |       desktop semantics   |
        |       and notifications   |
        |                           v
        +------------------------> goop
                                    runtime, keyed reconciliation,
                                    interaction, layout, resolved UI
                                             |
                  +--------------------------+--------------------------+
                  |                                                     |
                  v                                                     v
             goop_chrome                                      caller-owned look
             stock, read-only visuals                         custom visuals
                  |                                                     |
                  +-----------------------+-----------------------------+
                                          v
                                  visual encoder contract
                                  /                       \
                         caller renderer            optional recorder
                                                        or Vulkan stack
```

Platform input is an independent source of plain input values. Wayland is one
such source. Presentation is an independent producer of render targets. Vulkan
rendering consumes a minimal Vulkan render target; it does not import a
presenter or a window-system module.

## Library responsibilities

### `goop_ui`

`goop_ui` owns immutable description values and semantic identity:

- `ElementId` and `ActionId`;
- tree structure, content, layout inputs, and appearance selection;
- no retained state, handles, callbacks, renderer objects, or platform types.

There is one definition of each identity type in the repository. Other layers
reuse or re-export these exact types.

### `goop`

The core library owns mechanism:

- reconciliation by `ElementId`;
- retained interaction state;
- normalized input processing, hit testing, focus, and gestures;
- layout and resolved geometry;
- an ordered semantic event journal keyed by `ElementId`/`ActionId`.

Core never executes application behavior. Interaction results are returned as
data. `NodeHandle` is an internal storage address and is not application
identity. Core does not import Vulkan, Wayland, Snail, a desktop look, or an
application event loop.

Output lifetime is explicit. A borrowed event or snapshot slice states which
operation invalidates it. Frame clearing is part of processing; consumers do
not clear transient flags on individual nodes.

### `goop_desktop`

The desktop library owns reusable desktop semantics:

- commands and shortcuts;
- buttons, menus, toolbars, text editing, selection, tables, outlines,
  disclosure, split views, popups, and drag/drop notifications;
- typed desktop events that contain semantic IDs and values.

Desktop owns no visuals, renderer, filesystem behavior, or application
callbacks. It depends only on value contracts and core mechanism. A command
activation is emitted as data; the application decides what that command
means.

### `goop_chrome`

Chrome is an optional stock look. It reads resolved content, geometry, style,
and visual state and emits drawing operations. It may provide intrinsic
measurement and default metrics. It cannot mutate interaction or application
state.

Custom looks can replace Chrome entirely or delegate individual roles to it.
Look composition is caller-owned and explicit; there is no global component
registry or type-erased lifecycle convention.

### Visual encoding

The mandatory rendering boundary is a small capability for clips, surfaces,
text, icons/images, and explicit custom visuals. It is not a mandatory retained
scene or Goop-owned GPU abstraction.

A game renderer may implement that capability directly and record into its own
frame queues without allocating or translating an intermediate Goop scene. An
optional recorder may store the same operations for tests, deferred rendering,
or the bundled Vulkan stack. Unsupported operations are errors or declared
capability failures; they are never silently discarded.

Text measurement, shaping, icon resolution, image lookup, scale, and resource
upload are explicit caller-supplied capabilities or explicit preparation
steps. Recording does not hide allocation or queue-wide synchronization.

### Optional integrations

- `goop_snail`: Snail text/vector preparation.
- `goop_graphics_vulkan`: generic Vulkan mechanism from explicit device
  requirements.
- `goop_render_vulkan`: Vulkan recording against a minimal render target.
- `goop_present_vulkan`: swapchain and frame scheduling; produces targets.
- `goop_platform_wayland`: connection, surface, input, and frame-clock pieces.
- `goop_wayland_vulkan`: the sole Wayland/Vulkan WSI join.

None is a dependency of core, desktop, or Chrome.

## Application boundary

Applications own domain meaning. For the file browser this includes paths,
directory history, filesystem operations, preview loading, conflict policy,
and mapping UI item IDs to files. The file-browser controller consumes typed
desktop events; it does not inspect a Goop tree, retain `NodeHandle`s, read
layout rectangles, or import rendering/platform modules.

The showcase and file browser are acceptance tests for composition. Neither
contains a legacy handle-polling path or paint-protocol adapter.

## Supported compositions

- File browser: domain + desktop + core + stock Chrome + Snail/Vulkan +
  presenter + Wayland.
- Game tools: selected desktop controls + core + stock/custom look + the
  game's input and renderer.
- Game HUD: core interaction/layout + custom look + the game's renderer.
- Headless tests: core and optionally the recording encoder; no GPU/window.

## Hard rules

1. Input and output cross library boundaries as values.
2. Stable semantic IDs replace cross-layer storage handles.
3. Behavior, visual projection, rendering, presentation, and platform input
   are separate dependencies.
4. A lower layer never imports an optional higher layer.
5. No hidden application callbacks, global registries, service locators, or
   ownership-by-convention `anyopaque` state.
6. No duplicate paint/scene protocols or ordinal/bit-cast bridges.
7. Allocation, preparation, upload, and synchronization costs are visible in
   operation names and API boundaries.
8. Convenience composition is optional and remains a thin, inspectable call
   sequence; it never owns the caller's loop.
