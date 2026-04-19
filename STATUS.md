# Status

## Current

Iteration 42.
61 tests pass. Build clean. Demo runs.

## Iteration Count

42

## Done This Iteration

- Extracted 22 text input tests (~1080 lines) from dispatch.zig into dispatch_text_input_test.zig
- dispatch.zig reduced from ~1830 to ~760 lines

## Next

1. Text input clipboard (Ctrl+C/V/X) — needs platform clipboard integration
2. More letter keys in Keycode enum (add as needed)
3. Further test extraction if other test files grow large

## What's Wrong

- Approximate char_width (font_size * 0.6) — wrong for proportional fonts, needs real text measurement
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Scroll clamping uses previous frame's child layout rects — off by one frame
- Focus ring draws outside widget bounds — may clip in scroll areas
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard integration needs platform-specific code (Wayland wl_data_device)
- Double-click detection requires embedder to provide timestamp_ms (defaults to 0 = disabled)
