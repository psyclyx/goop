# Status

## Current

Chore cycle (iteration 5). Reviewed last 5 commits and codebase state.
Core modules scaffolded: widget tree, layout (clay), event types, draw types,
style/theme. Layout pass works (5/5 tests pass). Everything else is stubs.

## Iteration Count

5

## Done This Iteration

- Reviewed commits 2326ffd..92929a2 (5 commits)
- Audited all source files for dead code, inconsistencies, architecture drift
- No stale context to archive (project is young)
- Inbox empty, archive empty

## Findings

- c_api.zig listed in architecture but doesn't exist — OK, future work
- snail dep declared in build.zig.zon but not used in source yet
- Event types defined, no dispatch. Draw types defined, no generation.
- Demo is print-and-exit stub
- No dead code or rot — project is 4 iterations old, everything is intentional

## Next

1. Implement draw list generation from laid-out tree (draw.zig)
2. Wire event dispatch (hit testing, state updates)
3. Replace stub text measurement with snail

## What's Wrong

- Text measurement is a rough approximation — will produce wrong layout for real text
- draw.zig defines types but nothing generates draw commands from laid-out nodes
- No event processing — events are defined but nothing consumes them
- Demo is a print-and-exit stub — no window, no rendering
- Widget tree has no removal/mutation API — append-only
- No dirty tracking — full layout runs every frame
