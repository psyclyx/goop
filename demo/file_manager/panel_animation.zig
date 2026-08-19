//! Policy for the file manager's panel transitions.
//!
//! The general interpolator lives in goop; this module only maps browser
//! visibility booleans to the three panel progress values.

const std = @import("std");
const goop = @import("goop");

pub const duration_ns: u64 = 110 * std.time.ns_per_ms;

pub const Targets = struct {
    sidebar: bool,
    preview: bool,
    details: bool,
};

pub const Tick = struct {
    changed: bool,
    active: bool,
};

pub const State = struct {
    initialized: bool = false,
    sidebar: goop.animation.Value = .{},
    preview: goop.animation.Value = .{},
    details: goop.animation.Value = .{},

    pub fn tick(self: *State, targets: Targets, now_ns: u64) Tick {
        if (!self.initialized) {
            self.sidebar = goop.animation.Value.init(boolValue(targets.sidebar));
            self.preview = goop.animation.Value.init(boolValue(targets.preview));
            self.details = goop.animation.Value.init(boolValue(targets.details));
            self.initialized = true;
            return .{ .changed = true, .active = false };
        }

        self.sidebar.setTarget(boolValue(targets.sidebar), now_ns, duration_ns);
        self.preview.setTarget(boolValue(targets.preview), now_ns, duration_ns);
        self.details.setTarget(boolValue(targets.details), now_ns, duration_ns);
        const old = [3]f32{ self.sidebar.value, self.preview.value, self.details.value };
        _ = self.sidebar.sample(now_ns);
        _ = self.preview.sample(now_ns);
        _ = self.details.sample(now_ns);
        return .{
            .changed = old[0] != self.sidebar.value or old[1] != self.preview.value or old[2] != self.details.value,
            .active = self.sidebar.active(now_ns) or self.preview.active(now_ns) or self.details.active(now_ns),
        };
    }
};

fn boolValue(value: bool) f32 {
    return if (value) 1 else 0;
}

test "panel transitions initialize without animating and finish quickly" {
    var state: State = .{};
    try std.testing.expect(!(state.tick(.{ .sidebar = true, .preview = false, .details = true }, 10).active));
    const started = state.tick(.{ .sidebar = false, .preview = true, .details = true }, 20);
    try std.testing.expect(started.active);
    const midpoint = state.tick(.{ .sidebar = false, .preview = true, .details = true }, 20 + duration_ns / 2);
    try std.testing.expect(midpoint.changed and midpoint.active);
    try std.testing.expect(state.sidebar.value > 0 and state.sidebar.value < 1);
    const finished = state.tick(.{ .sidebar = false, .preview = true, .details = true }, 20 + duration_ns);
    try std.testing.expect(finished.changed);
    try std.testing.expect(!finished.active);
    try std.testing.expectEqual(@as(f32, 0), state.sidebar.value);
    try std.testing.expectEqual(@as(f32, 1), state.preview.value);
}
