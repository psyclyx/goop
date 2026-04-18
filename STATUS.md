# Status

## Current

Build system functional. Clay v0.14 vendored. Snail dependency wired.
`zig build`, `zig build test`, and `zig build demo` all work.
Minimal `src/goop.zig` initializes clay. Stub `demo/main.zig` exists.

## Iteration Count

2

## Next

1. Scaffold core modules (widget.zig, event.zig, layout.zig, style.zig, draw.zig)
2. Define the widget tree data structure
3. Wire up clay layout pass

## What's Wrong

- `src/goop.zig` is a thin clay wrapper — no widget tree, no event model, no draw data
- `demo/main.zig` is a stub — no window, no rendering
- `default.nix` references `src/` and `vendor/` correctly now but hasn't been tested as a nix build
- Zig version is 0.17.0-dev (master) — API may shift
- `zig-pkg/` directory created by build cache is untracked (should be gitignored)
