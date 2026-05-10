# C API

`goop`'s C surface mirrors the retained runtime in the Zig API. You build a
tree of widgets, push platform-neutral events, run layout/dispatch, and render
the resulting draw list however you want.

## Flow

Typical frame order:

1. Build or update widgets with `goop_context_add_root`, `goop_context_add_child`, and `goop_context_update_widget`.
2. Clear transient flags with `goop_context_clear_clicked_flags`.
3. Queue input with `goop_context_push_event`.
4. Run `goop_context_do_layout`.
5. Run `goop_context_process_events`.
6. Query widget state with helpers such as `goop_context_was_clicked`.
7. Generate draw commands with `goop_context_generate_draw_list`.

`goop_context_process_events` can trigger another internal layout pass when
text edits, scrolling, or resize events change layout-affecting state.

## Strings

`goop_string_t` is a pointer plus length pair. The pointer does not need to be
NUL-terminated.

Incoming descriptor strings are generally borrowed:

- labels, text content, placeholders, menu labels, and dropdown text should
  stay alive for as long as the widget keeps referring to them
- `text_input.value` is copied into the retained text buffer

Returned strings are borrowed from `goop`:

- `goop_context_text_input_value`
- `goop_context_tree_item_label`
- `goop_context_dropdown_value`
- draw-list text slices

Copy returned strings if you need them to outlive the current widget/context
state.

## Drawing

`goop_context_generate_draw_list` returns a flat list of:

- `GOOP_DRAW_RECT`
- `GOOP_DRAW_TEXT`
- `GOOP_DRAW_CLIP`
- `GOOP_DRAW_CUSTOM`

`GOOP_DRAW_CUSTOM` marks a widget that the embedder should render itself. It
carries the widget handle plus the resolved `bounds`, so custom rendering can
be inserted at the exact point `goop` emitted it in draw order.

`GOOP_DRAW_TEXT` carries:

- `bounds`: the content box used for alignment and clipping
- `baseline_y`: the baseline in Y-down coordinates
- `text_align`: horizontal alignment within `bounds`
- `overflow`: clip / wrap / ellipsis policy

If your renderer has baseline-aware text APIs, prefer `baseline_y` over
guessing from `font_size`.

The draw list is owned by `goop_context_t` and is valid until the next call
that mutates context state (events, tree edits, theme changes, resize).
Copy it if you need it to outlive the next frame.

## Text And Clipboard

For accurate text sizing, pass a `goop_text_measure_ctx_t` into
`goop_context_do_layout`. If you pass `NULL`, `goop` falls back to a rough
character-width estimate.

For best alignment, return real line metrics in:

- `height`: total line height
- `ascent`: distance from baseline to top of the line box
- `descent`: distance from baseline to bottom of the line box

Clipboard support is optional. Install callbacks with
`goop_context_set_clipboard` and `Ctrl+C` / `Ctrl+V` behavior in text inputs
will use them.

`GOOP_EVENT_TEXT` carries Unicode scalar values in `codepoint`, so UTF-8 text
input from a native platform layer should be translated into text events at
that level rather than passed as raw keycodes alone.

## Example

The repo includes a complete headless C example in
[examples/c/basic.c](../examples/c/basic.c). It creates a context, adds a text
input and button, sends a UTF-8 text sequence plus a click, and prints the
resulting state.

Run it with:

```sh
nix-shell --run 'zig build c-example'
```
