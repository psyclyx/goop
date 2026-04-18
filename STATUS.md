# Status

## Current

Iteration 9. Integrated snail GPU text rendering into the core layout and demo
renderer. Text is now measured with real glyph metrics (advance widths, kerning)
instead of the 0.6×font_size stub. Demo renders actual text glyphs via snail's
SDF pipeline. 13/13 tests pass.

## Iteration Count

9

## Done This Iteration

- layout.zig: added TextMeasureCtx (snail Font+Atlas), wired into Clay's
  measureText callback via user data pointer
- goop.zig: exposed TextMeasureCtx, doLayout now accepts optional text context
- demo/render.zig: integrated snail Renderer+Batch for text; flushes text batch
  before rect/clip commands to preserve draw order
- demo/main.zig: loads font via fontconfig fallback, builds glyph atlas for
  printable ASCII, passes TextMeasureCtx to layout
- build.zig: added snail module import to demo module

## Next

1. Verify text baseline positioning visually (may need y-offset tuning)
2. Slider drag interaction (press on thumb, track mouse_move while held)
3. Add frame callback for proper Wayland frame pacing

## What's Wrong

- Text baseline y-offset is approximate (y + font_size) — may render too low
- Only printable ASCII in atlas — non-ASCII chars will show as fallback boxes
- No font size variation — all text uses theme default, no per-widget override
- No frame callback — redraws on every Wayland event batch, not paced
- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Slider has no drag interaction — only visual, no mouse control
- No keyboard/focus navigation
- No border rendering on rects
- Demo uses page_allocator everywhere — no arena/frame allocator
- pushEvent takes allocator param on every call (queue could own allocator)
- Font loading uses popen("fc-match") — works but fragile
