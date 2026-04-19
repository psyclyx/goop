# Status

## Current

Iteration 37.
51 tests pass. Build clean. Demo runs.

## Iteration Count

37

## Done This Iteration

- Fixed flipped text rendering: snail positions glyph quads in Y-up font coordinates, but the renderer was using a Y-down ortho projection, rendering all text upside-down
- Changed ortho from (0, w, h, 0) to (0, w, 0, h) for Y-up projection
- Converted baseline calculation to flip from goop's Y-down to snail's Y-up coords

## Next

1. Mouse drag selection in text input (shift-click or click-drag to select)
2. Text input clipboard (Ctrl+C/V/X) — needs platform clipboard integration
3. dispatch.zig is ~1400 lines — consider extracting text input helpers or tests
4. More letter keys in Keycode enum (add as needed)

## What's Wrong

- dispatch.zig is ~1400 lines — tests account for most of it
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
