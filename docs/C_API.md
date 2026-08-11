# C API

The C surface is split at the same seam as the Zig libraries:

- `goop.h` / `libgoop` provide retained UI state, layout, normalized input,
  and ordered semantic output.
- `goop_chrome.h` / `libgoop_chrome` optionally turn laid-out core state into
  backend-neutral `goop_visual_operation_t` values.

A game that supplies its own look and renderer links only `libgoop`. Neither
library creates a window, owns a rendering device, or submits GPU work.

## Core flow

1. Add elements with `goop_context_add_root` and
   `goop_context_add_child`. Every `goop_control_desc_t` carries a unique,
   caller-owned `element_id` and an optional application `action_id`.
2. Queue platform-neutral `goop_event_t` input.
3. Run `goop_context_do_layout`.
4. Call `goop_context_process_events` and consume its ordered
   `goop_control_events_t` result.
5. Project application state back into widget descriptions as needed, then
   lay out again.
6. Either visit resolved elements with `goop_context_visit_resolved` for a
   custom look or ask an explicitly owned Chrome object for stock visuals.

`goop_node_handle_t` is a generation-checked structural locator. It is useful
while constructing or querying the tree, but never appears in semantic output.
Use `goop_context_find_element` when an application has a stable element ID
and only needs a temporary handle.

`goop_context_process_events` may allocate while retained output capacity
grows. Capacity is reused on later calls. It can also trigger another internal
layout pass when text edits, scrolling, or resize input changes layout state.

## Semantic output

`goop_control_events_t.items` is in input occurrence order. Its variants are:

- activation and secondary activation, including optional action IDs
- scalar/index/table-column value changes
- toggle, text, sort, selection, and scroll changes
- semantic drag/drop with element IDs and a typed position

Text and selection payloads are spans into the batch's `text_bytes` and
`selection_ids` arenas. Resolve them with `goop_control_events_text` and
`goop_control_events_selection`.

The event array and both payload arenas are borrowed. They remain valid until
the next `goop_context_process_events` call or `goop_context_destroy`. Text is
UTF-8 and is not NUL-terminated. Copy anything that must survive that boundary.

There are deliberately no clicked/change flags to clear or poll, no last-drop
frame slot, and no handle-valued activation output.

## Custom looks and own renderers

`goop_context_visit_resolved` is the allocation-free core rendering seam. It
performs a synchronous depth-first traversal and calls both required visitor
callbacks for every element:

```c
static void enter(void *data, const goop_resolved_element_t *element);
static void leave(void *data, const goop_resolved_element_t *element);

goop_context_visit_resolved(context, &(goop_resolved_visitor_t){
    .enter = enter,
    .leave = leave,
    .user_data = renderer_state,
});
```

`enter` runs before an element's descendants and `leave` runs after them. Both
receive the same plain resolved value: optional element/parent/action IDs,
resolved bounds and style, widget view, and focused/hovered/pressed/drop-hover
state. It contains no node handle, tree, renderer, or platform object.

Callbacks are synchronous and read-only. The element pointer is valid only for
that callback invocation, and strings inside its widget view borrow core
storage. Do not mutate the context, recursively visit it, or retain those
pointers. Copy values that need a longer lifetime. `user_data` is passed
through unchanged; Goop never interprets it.

`GOOP_WIDGET_ICON` is passive visual data: an opaque `uint32_t` identity plus
an optional color. Tree and grid items expose the same optional icon hints.
Core assigns no click behavior or resource ownership to them; a custom look
maps the identity into its renderer, while stock Chrome emits
`GOOP_VISUAL_ICON`.

Traversal allocates nothing. Child order is logical sibling order; each enter
is balanced by one leave, which lets a custom look maintain clip, transform,
or container stacks directly in its own rendering pipeline. Order between
multiple roots is deliberately unspecified.

## Strings and clipboard

`goop_string_t` is a pointer plus length and need not be NUL-terminated.
Descriptor labels, content, placeholders, and menu/dropdown text are borrowed
for as long as the widget refers to them. A text input's seed value is copied
into its retained editor buffer.

Strings in node views borrow widget storage. Copy them before mutating or
removing the corresponding widget if they must live longer.

For accurate sizing, pass `goop_text_measure_ctx_t` to
`goop_context_do_layout`; `NULL` selects the core's rough fallback estimate.
Clipboard callbacks installed with `goop_context_set_clipboard` are optional.
`GOOP_EVENT_TEXT` carries Unicode scalar values, so platform text input should
be normalized before it enters Goop.

## Optional stock Chrome

Stock Chrome is explicit, caller-owned retained state:

```c
goop_chrome_t *chrome = goop_chrome_create();
goop_visual_list_t visuals = {0};

goop_chrome_result_t result = goop_chrome_prepare(
    chrome,
    context,
    &(goop_chrome_options_t){
        .kind = GOOP_CHROME_SCOPE_FULL,
        .include_floating = true,
    },
    &visuals);
```

Preparing a changed context or scope may allocate. A cache hit reuses retained
storage. The returned operations borrow Chrome storage and context-owned text;
consume them before a context mutation, dirty preparation, explicit Chrome
invalidation, or destruction of either owner.

The operation vocabulary is surfaces, text, clip push/pop, icons, decoded
images, and semantic custom visuals. Image pixels are borrowed straight-alpha
sRGBA8 data keyed by a caller resource ID/revision; they remain valid under the
same Chrome-list lifetime described above. The vocabulary contains no Vulkan, Wayland, command-buffer, or
tree-handle values. A renderer can consume it directly, while an application
with its own look can skip Chrome and encode its own renderer from core state.

`GOOP_WIDGET_CUSTOM` remains the first-class way to place an application-owned
visual in stock Chrome. Its visual operation is keyed by semantic element ID;
there is no presentation flag stored on the core context.

## Examples

The core-only example visits resolved UI with its own look, then consumes
UTF-8 text and activation events:

```sh
zig build c-example
```

The optional composition example owns a Chrome cache and inspects canonical
visual operations:

```sh
zig build c-chrome-example
```
