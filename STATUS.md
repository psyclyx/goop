# Status

## Current

Iteration 41.
61 tests pass. Build clean. Demo runs.

## Iteration Count

41

## Done This Iteration

- Added double-click to select word in text input
- Added `timestamp_ms` to MouseButton events for double-click timing
- Added `wordBounds()` to TextInput for word boundary detection
- Added double-click tracking state to MouseState
- 5 new tests (2 wordBounds unit tests, 4 double-click dispatch tests)

## Next

1. Text input clipboard (Ctrl+C/V/X) — needs platform clipboard integration
2. Extract text input dispatch logic or tests from dispatch.zig (~1800 lines now)
3. More letter keys in Keycode enum (add as needed)

## What's Wrong

- dispatch.zig is ~1800 lines — tests are ~60% of it, still growing
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
