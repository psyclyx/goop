# Status

## Current

Iteration 49.
72 tests pass. Build clean. Demo runs.

## Iteration Count

49

## Done This Iteration

- Threaded TextMeasureCtx through dispatch and draw modules
- Text input cursor positioning (click + drag) now uses real glyph metrics via layout.charIndexAtX
- Selection highlight and cursor rendering now uses real widths via layout.textWidthUpTo
- Both helpers fall back to font_size * 0.6 when no measurement context provided
- Context stores text_measure_ctx from doLayout for use in processEvents and generateDrawList

## Next

1. Widget tree mutation/removal API
2. Draw list caching (skip draw generation when only layout skipped and no interaction changed)
3. Text baseline y-offset — use real font ascent/descent from snail

## What's Wrong

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
- charIndexAtX iterates all positions — O(n) per call, fine for short inputs but won't scale to large text fields
