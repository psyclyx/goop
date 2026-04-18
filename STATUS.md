# Status

## Current

Iteration 33.
40 tests pass. Build clean. Demo runs.

## Iteration Count

33

## Done This Iteration

- Added placeholder text support for text input widget
- Added `placeholder: []const u8` field to TextInput struct
- Added `placeholder_fg` color to Theme (rgb 120,120,120)
- Draw placeholder in dimmed color when input is empty, content text when non-empty
- Fixed emitTextInput to access TextInput via node pointer (was value copy — dangling slice bug)
- Updated demo to use placeholder: "Type here..."
- Added tests: "empty text input shows placeholder", "text input with content shows content not placeholder"

## Next

1. dispatch.zig still large — consider extracting scroll/slider helpers or tests
2. Text input selection support
3. Text input clipboard (copy/paste)

## What's Wrong

- dispatch.zig is ~900 lines — still large, tests account for most of it
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
- Text input has no selection support
