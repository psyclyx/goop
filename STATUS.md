# Status

## Current

Iteration 47.
72 tests pass. Build clean. Demo runs.

## Iteration Count

47

## Done This Iteration

- Fixed demo frame callback ordering: register `wl_surface_frame` BEFORE `eglSwapBuffers` so the compositor fires callbacks
- Without this fix, only 1 frame ever rendered — all events accumulated but were never processed
- Changed `frameDone` to not force `needs_redraw` — demo now renders event-driven instead of continuously

## Next

1. Antialiased rendering (inbox: "jagged af")
2. Real text measurement instead of approximate char_width
3. Widget tree mutation/removal API
4. Draw list caching (skip draw generation when only layout skipped and no interaction changed)

## What's Wrong

- Rendering is jagged — no antialiasing (inbox note)
- Approximate char_width (font_size * 0.6) — wrong for proportional fonts, needs real text measurement
- Widget tree is append-only — no removal/mutation API
- No draw list caching — draw list regenerated every frame even when output unchanged
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Scroll clamping uses previous frame's child layout rects — off by one frame
- Focus ring draws outside widget bounds — may clip in scroll areas
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device) yet
- Double-click detection requires embedder to provide timestamp_ms (defaults to 0 = disabled)
