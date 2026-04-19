# Status

## Current

Iteration 38.
54 tests pass. Build clean. Demo runs.

## Iteration Count

38

## Done This Iteration

- Added mouse click-drag selection in text input
- On press: set selection_anchor = cursor (instead of clearSelection)
- On mouse move while dragging: update cursor position to create selection
- Fixed insert() to clear selection after inserting — prevents phantom selections from stale anchor
- Added 3 tests: drag forward, drag backward, click-after-drag clears selection

## Next

1. Text input clipboard (Ctrl+C/V/X) — needs platform clipboard integration
2. dispatch.zig is ~1550 lines — consider extracting text input helpers or tests
3. More letter keys in Keycode enum (add as needed)
4. Shift-click to extend selection (currently only drag)

## What's Wrong

- dispatch.zig is ~1550 lines — tests account for most of it
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Radio button circle rendering depends on renderer corner_radius support
- Scroll clamping uses previous frame's child layout rects — off by one frame on content resize
- Focus ring draws outside widget bounds — may clip in scroll areas
- No keyboard-driven slider value change (arrow keys)
- Magic numbers for focus ring inset and checkbox/radio indicator inset
- Text input cursor position uses approximate char_width (font_size * 0.6) — will be wrong for non-monospace fonts
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard integration needs platform-specific code (Wayland wl_data_device)
- Only 'a' key mapped — other letter keys not yet in Keycode enum (add as needed)
