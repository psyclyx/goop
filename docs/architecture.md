# Architecture

Goop is a collection of libraries rather than a framework. Applications
compose the layers they need and own every cross-layer call.

## Dependency graph

```text
goop_geometry + goop_image ──> goop_visual
goop_ui + goop_input + goop_visual ──> goop
goop_input + goop ──> goop_desktop
goop_visual ──> goop_components

goop + optional goop_components ──> custom look ──> caller renderer
goop + goop_components + goop_visual ──> goop_chrome ──> caller renderer
goop_visual ──> optional recorder

goop_visual + goop_image ──> goop_snail ──> goop_render_vulkan
goop_visual ─────────────────────────────> goop_render_skia   (-Dskia)
goop_graphics_vulkan ─────────> goop_render_vulkan
        ├─────────────────────> goop_render_skia
        ├─────────────────────> goop_present_vulkan ──> RenderTarget
        └─────────────────────> goop_wayland_vulkan <── WSI handles
goop_platform_wayland ─────────────────────────────────┘
```

`goop_render_skia` (GPU/Ganesh) and `goop_render_vulkan` (snail) are
interchangeable renderers of the neutral `goop_visual` vocabulary; only
`goop_render_vulkan` depends on snail. Everything below the renderer — the
device, presentation, WSI, and window — is shared and snail-agnostic.

Arrows point from a supplied contract to a consumer. The build
wiring enforces the important negative dependencies: core, desktop,
components, and Chrome do not import Wayland or Vulkan; the Vulkan renderer
does not import presentation or a window system; the Wayland platform does not
import Vulkan, rendering, or core.

## Leaf value libraries

`goop_geometry` owns `Point` and `Rect`.

`goop_ui` owns only the distinct stable `ElementId` and `ActionId` value types.
It has no widget, behavior, retained-state, style, or rendering API.

`goop_input` owns the exact normalized `Event`, key, button, modifier, and
shortcut vocabulary. Native platforms and game input systems translate into
these plain values.

`goop_image` owns decoded straight-alpha sRGBA8 values, stable resource
identity/revision, encoded-format detection, and an explicit caller-supplied
decoder capability. It performs no file I/O and chooses no codec.

`goop_visual` owns resolved surfaces, text, icons, images, clip operations, and
semantic custom visuals, plus generic direct-emission helpers. It knows no UI
tree or rendering backend.

## Core mechanism: `goop`

Core owns the retained widget tree, input queue, interaction state, hit
testing, Clay layout, semantic event journal, and resolved UI projection. It
does not execute application commands or own a visual cache, renderer,
presenter, platform loop, or GPU resource.

`ControlDesc` keeps semantic identity orthogonal to widget content.
`NodeHandle` is a temporary, generation-checked structural address used during
tree construction/projection. Cross-layer output instead uses `ElementId` and
`ActionId`.

`processEvents` returns the borrowed ordered `ControlEvents` journal.
Occurrence order is preserved across activation, values, toggles, text, sort,
selection, scroll, and drop output. Text and selection spans resolve through
the batch. Consumers copy only data that must outlive the next processing
boundary.

`visitResolved` calls a statically dispatched visitor with balanced
`enter(ResolvedElement)` and `leave(ResolvedElement)` operations. Traversal allocates nothing,
exposes no retained handles, and preserves enough structure for direct clip
emission. The application-owned look decides both mapping to visual operations
and floating-layer policy.

A `Runtime` represents one interaction/layout domain. `Context` composes it
with one tree, theme, and clipboard capability. Independent focus or window
domains use independent contexts; there is no implicit cross-context manager.

## Reusable policy: `goop_desktop`

Desktop is an optional, exact-type layer above normalized input and core
semantics. It supplies command/shortcut/binding values, shortcut resolution,
semantic activation matching, and common control-description constructors.

It owns neither behavior nor visuals. Resolving a command produces an
`ActionId`; the application reduces that data into its model and effects.

## Dumb visuals: `goop_components`

Components consume already-resolved geometry, content, and appearance and emit
into a generic visual encoder. They allocate nothing and own no interaction,
identity, renderer resource, or retained state. A look may reuse a component,
override every supplied style value, combine it with custom visuals, or ignore
the library entirely.

Components do not “draw the model” on their own: the caller maps
`ResolvedElement` plus application policy to component values. That mapping is
the look.

## Optional stock look: `goop_chrome`

Chrome is one implementation of a look. It reads a narrow, immutable
hierarchy-aware core capability and uses `goop_components` to emit canonical
`goop_visual` operations. It cannot update interaction or application state.

Its cache is a caller-owned `Chrome` value. Dirty preparation may allocate;
matching preparation is a no-allocation cache hit. Generic replay into an
encoder is allocation-free. This cost boundary is visible in `prepare` and
`emit`, and applications can explicitly invalidate or destroy the cache.

## Renderer boundary

A look targets a structural capability with exactly these operations:

```text
pushClip   popClip   surface   text   icon   image   custom
```

The capability is generic rather than a vtable. A game can implement it on its
own render-queue type and receive operations directly. No second scene format,
conversion allocation, global component registry, or backend object is
required.

The optional `visual.Recorder` is useful when retained operations are desired.
Stock Chrome uses such retained operations for its explicit cache. Direct
custom looks need not record anything.

## Vulkan, presentation, and Wayland

The optional native stack separates device mechanism, rendering, presentation,
platform input, and their one necessary join:

1. `goop_graphics_vulkan` creates an instance/device and defines
   `RenderTarget { command_buffer, extent, frame_slot }`.
2. `goop_present_vulkan` owns the swapchain and frame lifecycle. Its
   `beginFrame` returns a target inside an active render pass, and `endFrame`
   submits and presents it.
3. `goop_render_vulkan` consumes only the target plus visual/text resources.
   `prepareVisuals` performs explicit CPU work, `updateVisualResources`
   performs the explicit GPU resource phase, and `drawPreparedVisuals` records
   the already-prepared stream.
4. `goop_platform_wayland` produces window events and exposes raw WSI handles.
5. `goop_wayland_vulkan` consumes those handles solely to create the Vulkan
   surface and name the required instance extensions.

Scale is passed explicitly to visual preparation. Frame-slot count and
attachment format are explicit renderer initialization inputs. Unsupported
custom visuals are reported by the bundled renderer rather than ignored.
Text and application images have separate caller-owned preparation caches and
Vulkan atlas bindings. Bitmap font strikes and native file previews receive a
decoder from the composition root; a game can supply its existing asset
decoder without adapting rendering systems. The application-image atlas is
bounded by the current prepared stream; resource identity revisions make
replacement explicit without retaining every prior preview.

## Supported compositions

| Composition | Goop supplies | Caller supplies |
| --- | --- | --- |
| Game HUD | core interaction/layout and resolved visits | input mapping, custom look, game renderer/window |
| Game UI with components | core plus dumb resolved visuals | look policy, game renderer/window |
| Desktop-style game tool | desktop semantics, core, optional components/Chrome | domain behavior, game renderer/window |
| Full file-browser demo | desktop, core, Chrome, Snail/Vulkan, presenter, Wayland | browser model/effects and explicit composition root |
| Headless tests | core and optionally a visual recorder | synthetic input and assertions |

No row implies a preferred application architecture. Each is a supported
library cut.

## File-manager proof

The file manager is the acceptance test for the full composition. It keeps
browser domain data and interaction intent in `Domain`, external transfer
buffers in `Effects`, application lifetime/dimensions in `Session`, and visual
projection scratch in `View`. Its composition-only `Browser` groups those
owners but is not passed indiscriminately through behavior and view code.

The controller receives `Behavior` plus borrowed semantic events and returns
whether the view should be rebuilt. It imports neither tree storage nor native
rendering. Projection receives read-only `ViewInput` and a focused `ViewOutput`
for scratch and identity assignment. The application root alone connects
Wayland, core, Chrome, Snail/Vulkan, and presentation.

The optional image-preview capability is equally explicit: filesystem behavior
decodes into presentation-owned pixels, the projection emits passive image
data, and the renderer consumes the same `goop_visual.Image` a game renderer
would. libspng, libjpeg-turbo, and libwebp exist only in the native demo
composition.

These demo types are evidence that the seams hold, not another framework layer
for consumers.

## Rules

1. Input and output cross boundaries as plain values or narrow borrowed
   capabilities.
2. Semantic IDs cross layers; retained storage addresses do not.
3. Behavior, look, visual encoding, rendering, presentation, and native input
   remain independently replaceable.
4. Optional higher layers never leak into lower-layer types.
5. Application behavior is an explicit reducer, not an invisible callback.
6. Allocation, CPU preparation, GPU upload, and synchronization remain visible
   at named boundaries.
7. Convenience layers are caller-owned values and never capture the
   application's loop.
