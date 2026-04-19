# Status

## Current

Iteration 39.
56 tests pass. Build clean. Demo runs.

## Iteration Count

39

## Done This Iteration

- Added shift-click to extend selection in text input
- When shift held: anchor stays (or sets from cursor if none), cursor moves to click position
- When shift not held: existing behavior (both cursor and anchor set to click position)
- Added 2 tests: shift-click from cursor, shift-click extending existing selection

## Next

1. Text input clipboard (Ctrl+C/V/X) — needs platform clipboard integration
2. dispatch.zig is ~1650 lines — consider extracting text input helpers or tests
3. More letter keys in Keycode enum (add as needed)
4. Double-click to select word

## What's Wrong

- dispatch.zig is ~1650 lines — tests account for most of it
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
