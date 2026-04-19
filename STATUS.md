# Status

## Current

Iteration 51. Text input fix.
72 tests pass. Build clean. Demo runs.

## Iteration Count

51

## Done This Iteration

- Wired up xkbcommon in the demo to convert Wayland key events to text codepoints
- Text input now works: keymap handler receives compositor keymap, modifiers handler tracks state, keyboardKey produces .text events via xkb_state_key_get_utf32
- Addressed inbox feedback about text input not working

## Next

1. Investigate jagged text rendering (second part of inbox feedback)
2. Widget tree mutation/removal API (generational handles or free-list)
3. Draw list caching (draw-dirty flag, skip regeneration when unchanged)
4. Toolbar/menu bar widget

## What's Wrong

- Text rendering may have subpixel positioning issues causing jagged appearance
- Widget tree is append-only — no removal/mutation API (50+ iterations deferred)
- No draw list caching — draw list regenerated every frame even when output unchanged
- Font loading uses popen("fc-match") — fragile, Linux-only
- MSAA sample count hardcoded to 4 — no fallback if GPU doesn't support it
- Text input only handles printable ASCII — no UTF-8 multi-byte support
- Clipboard demo doesn't wire up real Wayland clipboard (wl_data_device)
- No toolbar/menu widget — last item from target widget set
