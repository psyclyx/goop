# Status

## Current

Iteration 48.
72 tests pass. Build clean. Demo runs.

## Iteration Count

48

## Done This Iteration

- Enabled 4x MSAA antialiasing: EGL_SAMPLE_BUFFERS + EGL_SAMPLES in EGL config, glEnable(GL_MULTISAMPLE) in renderer
- Works alongside existing SDF smoothstep edge softening in fragment shader
- Addresses inbox "jagged af" report

## Next

1. Real text measurement instead of approximate char_width
2. Widget tree mutation/removal API
3. Draw list caching (skip draw generation when only layout skipped and no interaction changed)

## What's Wrong

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
- MSAA sample count is hardcoded to 4 — no fallback if GPU doesn't support it
