# Goop design

Goop is a retained interaction and layout mechanism, surrounded by optional
libraries. The application owns domain state, effects, policy, event loop,
windowing, frame scheduling, rendering, and memory choices at the seams.

## Core contract

`goop.Context` is the ordinary core composition. It owns one retained `Tree`,
one `Runtime`, a theme, and an optional clipboard capability. A runtime is one
interaction/layout domain: focus, pointer gestures, queued input, and Clay
layout state are not implicitly shared across independent UI domains.

The core frame flow is explicit:

1. Project application state into `WidgetDesc`/`ControlDesc` values.
2. Construct the tree. `NodeHandle` is a temporary structural locator for
   parent/child construction and focused projection work.
3. Call `doLayout`, supplying an optional `TextMeasureCtx`.
4. Queue normalized `goop_input.Event` values with `pushEvent`.
5. Call `processEvents` and reduce the resulting semantic batch into
   application state.
6. Re-project and lay out if the application state changed.
7. Visit resolved UI with a custom look or pass read-only `chromeState()` to
   optional stock Chrome.

Application behavior is never called by core. Stable `ElementId` and
`ActionId` values connect tree input, semantic output, and model state.
Generational `NodeHandle` values are storage locators, not application IDs;
they do not appear in semantic output or `ResolvedElement`.

## Normalized input

`goop_input` is a leaf library. Its `Event` union contains:

- mouse position;
- mouse button, state, position, timestamp, and modifier snapshot;
- scroll delta and modifier snapshot;
- logical key, raw scancode, state, and modifier snapshot;
- Unicode text codepoint;
- focus state;
- logical size.

Wayland is one possible producer; a game input system can construct the same
values directly. Consecutive queued mouse movements retain the latest sample,
and consecutive queued scrolls accumulate. Other values retain their order.

## Semantic output

`processEvents` returns `ControlEvents`, an occurrence-ordered
borrowed journal keyed by semantic IDs. Its variants are:

- `activated` and `secondary_activated`;
- `value_changed` for scalar, selected index, or table-column fraction;
- `toggle_changed`, `text_changed`, `sort_changed`, `selection_changed`, and
  `scroll_changed`;
- `popup_visibility_changed` when core dismisses an identified retained popup;
- `drop`, with semantic source/target IDs and a typed position.

`ControlEvents.items`, `text_bytes`, and `selection_ids` borrow runtime
storage. `ControlEvents.text` and `ControlEvents.selection` resolve the
variable-size spans. All become invalid at the next processing call or runtime
destruction, so reducers copy only what their model needs to retain.

The journal reserves the worst-case capacity for the complete input batch
before dispatch begins and retains that capacity across calls. Growth may
allocate; after a successful reserve, dispatch writes do not allocate.
Applications with strict frame-time requirements can warm representative
paths during setup.

Marquee selection is live but provisional while the pointer is held. List,
grid, and table containers publish one completed `selection_changed` value on
release rather than rebuilding application state for every child crossed by a
drag. Gesture cancellation restores the selection from before the drag and
publishes no event.

## Resolved UI and custom looks

`Context.visitResolved(visitor)` is the public custom-look seam. The visitor
is generic and statically dispatched; it provides exact
`enter(ResolvedElement)` and `leave(ResolvedElement)` methods returning `void`
or `!void`.
Traversal is allocation-free and depth-first in logical sibling order. Every
successful enter is paired with a leave after its descendants, so a look can
emit structural clips without rebuilding hierarchy. Multiple-root order is
unspecified, and floating subtrees remain at their logical position so the
look owns layering policy.

Each `ResolvedElement` contains:

- optional element, parent, and action IDs;
- resolved bounds and style;
- read-only widget content/state;
- focused, hovered, pressed, and drop-hovered state.

Borrowed widget strings remain valid only while their source node remains
unchanged. The visitor receives no tree handle and cannot mutate core through
the resolved value; it must not mutate the traversed tree by another route
during the visit.

## Visual contract and components

`goop_visual` is a leaf rendering vocabulary. A structural encoder implements
seven generic methods:

```text
pushClip(Rect)   popClip()
surface(Surface) text(Text)
icon(Icon)       image(Image)
custom(Custom)
```

The values contain resolved geometry and appearance, not GPU resources or
frame state. An image borrows straight-alpha sRGBA8 pixels and carries a
caller-owned resource identity/revision; `goop_image` also defines the explicit
optional decoder capability. Direct calls and `visual.emit`/`visual.emitAll` are allocation-free
and use static dispatch. `visual.Recorder` is an explicitly allocating,
caller-owned option for tests or deferred replay; it is not required between a
look and a renderer.

`goop_components` contains dumb, allocation-free resolved visuals. Its current
building blocks are `Surface`, `Text`, `Icon`, `Image`, `FocusRing`, `Button`,
`Checkbox`, and `RadioButton`. They depend only on `goop_visual`, own no
behavior or retained state, and simply emit into a caller's encoder. A custom
look decides how a `ResolvedElement` maps to these values. Stock Chrome uses
the same components; core does not.

## Optional desktop seam

`goop_desktop` provides reusable desktop command/control semantics above core:

- `Command`, `Shortcut`, and `Binding` values;
- allocation-free shortcut and semantic activation resolution;
- common `ControlDesc` constructors for buttons, menu items, toggles, text
  input, selection, tables, and splitters.

It reuses core `ElementId`, `ActionId`, `ControlDesc`, and `ControlEvents`
types exactly. It owns no visual style, platform objects, application
callbacks, or renderer. Applications give commands domain meaning.

## Optional stock Chrome

`goop_chrome.Chrome` is a caller-owned stock look and retained visual cache.
It consumes the read-only hierarchy capability returned by
`Context.chromeState()` and produces canonical `goop_visual` operations.

`Chrome.prepare` keys its cache by source tree, resolved visual revision,
text-measure capability, and options. A matching preparation returns the same
borrowed storage without allocating. A dirty preparation may allocate, then
replaces the old cache. `Chrome.emit` prepares if needed and structurally
replays the exact cached operations into a generic encoder; replay itself is
allocation-free. `invalidate` and `deinit` make cache ownership explicit.

Custom looks use `visitResolved` and need not import Chrome. Chrome cannot
mutate core interaction or application state.

## Optional native integrations

The bundled path retains the same separation:

- `goop_snail` handles backend-neutral Snail text/vector preparation. Text
  placement takes an explicit scene-to-device-pixel transform, so origin
  snapping and TrueType ppem selection follow the embedding renderer's grid.
- `goop_graphics_vulkan` owns Vulkan instance/device mechanism and the minimal
  per-frame `RenderTarget`: command buffer, extent, and reusable frame slot.
- `goop_render_vulkan` owns rendering pipelines, buffers, and device-atlas
  resources. CPU shaping/allocation, GPU resource update, and command recording
  are explicit `prepareVisuals`, `updateVisualResources`, and
  `drawPreparedVisuals` calls.
- `goop_present_vulkan` owns swapchain images, render pass, synchronization,
  acquisition, submission, and presentation. `beginFrame` produces the target
  consumed by the renderer.
- `goop_platform_wayland` owns a Wayland window and a queue of platform events;
  it imports neither core nor Vulkan.
- `goop_wayland_vulkan` is the only module containing the Wayland/Vulkan WSI
  join.

The Vulkan renderer does not import the presenter or Wayland. The presenter
does not import the renderer or UI. A game with an existing render graph can
skip this entire path and implement the visual encoder against its own queues.

The desktop demo's Fontconfig loader is deliberately outside `goop_snail`:
host font discovery produces an ordered fallback chain, while a game can use
packed assets through the same adapter API. Native-em shaping for layout and
device-ppem shaping for TrueType rendering are separate caches. On a TT cache
miss the adapter follows Snail's explicit sequence: shape to discover glyphs,
prepare missing hinted advances, reshape with the cache-only advance provider,
then prepare ppem-specific geometry and place the run on the caller's device
grid. Unsupported outline
formats remain on the unhinted grayscale path. The bundled Vulkan renderer
requests grayscale coverage only and does not enable the dual-source feature
used for LCD text. Embedded bitmap glyph strikes use the same explicit
`goop_image.Decoder` capability as application images. The native composition
provides PNG, JPEG, and WebP through libspng, libjpeg-turbo, and libwebp; Goop,
Chrome, components, and Snail do not choose or link a codec. The bundled renderer synchronizes its application-image atlas
to the current prepared visual stream, so browsing through resources does not
turn navigation history into permanent CPU/GPU cache growth.

## File-manager acceptance evidence

The file manager deliberately uses the whole optional stack to test the
boundaries. Its application root owns window, text, core, Chrome, GPU, and
frame-loop values. Browser state is split independently:

- `Session`: application lifetime and logical dimensions;
- `Domain`: browser model, interaction intent, and semantic identity registry;
- `Effects`: clipboard and drag transfer buffers;
- `View`: projection scratch, virtualization, and measurement capability.

Image previews are behavior-prepared renderer-neutral pixels. The view emits a
passive image component, Chrome resolves it through an explicit custom-visual
resolver, and the application supplies the decoder capability. Preview code
owns no Snail, Vulkan, or codec-library object.

The controller receives only a focused `Behavior` capability and an ordered
`ControlEvents` batch. It sees no tree, layout handle, renderer, or platform
object. Visual projection receives read-only `ViewInput` and focused
`ViewOutput` scratch/identity capabilities. `Browser` is only the demo's
composition owner; none of these demo types is consumer API.

This is acceptance evidence rather than a prescribed application framework:
consumers may split their own model and effects differently while preserving
the value boundaries.

## Non-goals

- Owning a native event loop, window, swapchain, or game frame.
- Calling application behavior through hidden lifecycle hooks.
- Requiring a retained visual stream or GPU abstraction.
- Making visual components responsible for interaction semantics.
- Treating internal tree storage identity as domain identity.
- Hiding allocation, shaping, upload, or synchronization behind rendering.
