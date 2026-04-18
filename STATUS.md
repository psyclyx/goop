# Status

## Current

Iteration 24. Keyboard focus navigation added.
29 tests pass. Build clean. Demo runs.

## Iteration Count

24

## Done This Iteration

- Added Keycode enum to event.zig (tab, enter, space, escape, shifts, unknown)
- Focus tracking in dispatch: Tab/Shift+Tab cycles, Enter/Space activates
- Click-to-focus on interactive widgets
- Focus ring rendering in draw.zig (accent-colored border around focused widget)
- focus_ring color added to Theme
- Wayland keyboard listener wired up in demo with evdev scancode mapping
- 4 new tests: tab cycling, shift+tab backwards, enter/space activation, click focus

## Next

1. Chore cycle at iteration 25
2. Design review at iteration 25 (10th multiple)
3. Text input widget (stretch)

## What's Wrong

- Widget tree is append-only — no removal/mutation API
- No dirty tracking — full layout + full draw list every frame
- Text baseline y-offset is approximate (y + font_size)
- Font loading uses popen("fc-match") — fragile
- Radio button circle rendering depends on renderer corner_radius support
- Scroll clamping uses previous frame's child layout rects — off by one frame on content resize
- Focus ring draws outside widget bounds — may clip in scroll areas
- No keyboard-driven slider value change (arrow keys)
