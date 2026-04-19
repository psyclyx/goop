# Status

## Current

Iteration 44.
69 tests pass. Build clean. Demo runs.

## Iteration Count

44

## Done This Iteration

- Added clipboard support (Ctrl+C/V/X) for text input via embedder-provided Clipboard interface
- Added keycodes c, v, x and mapped them in the demo
- Added TextInput.insertSlice for pasting multi-character text
- 8 new tests covering copy, cut, paste, edge cases, and round-trip

## Next

1. More letter keys in Keycode enum (add as needed for shortcuts)
2. Further test extraction if other test files grow large
3. Dirty tracking — avoid full layout + draw every frame

## What's Wrong

- Clipboard is callback-based but demo doesn't wire up a real Wayland clipboard (wl_data_device) yet
- Approximate char_width (font_size * 0.6) — wrong for proportional fonts, needs real text measurement
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Scroll clamping uses previous frame's child layout rects — off by one frame
- Focus ring draws outside widget bounds — may clip in scroll areas
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Double-click detection requires embedder to provide timestamp_ms (defaults to 0 = disabled)
