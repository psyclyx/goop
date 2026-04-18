# Status

## Current

Iteration 35.
47 tests pass. Build clean. Demo runs.

## Iteration Count

35

## Done This Iteration

- Added Ctrl key modifier support to the event system
- Added `left_ctrl`, `right_ctrl`, and `a` to `Keycode` enum
- Added `ctrl_down: bool` to `MouseState`, tracked on key press/release
- Implemented Ctrl+A select-all for text input (sets anchor=0, cursor=len)
- Mapped evdev scancodes 29 (left ctrl), 97 (right ctrl), 30 (a) in demo
- Added 2 tests: ctrl+a selects all, ctrl+a on empty is no-op

## Next

1. Text input clipboard (Ctrl+C/V/X) — Ctrl modifier is now in place, needs platform clipboard integration
2. dispatch.zig is ~1200 lines — consider extracting text input helpers or tests
3. Mouse click-to-position cursor in text input
4. Mouse drag selection in text input

## What's Wrong

- dispatch.zig is ~1200 lines — tests account for most of it
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
