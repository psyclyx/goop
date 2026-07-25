//! Browser-specific semantic actions.
//!
//! Raw IDs cross the generic component/driver boundary; browser intent stays
//! independent of the UI implementation.

pub const Action = enum(u16) {
    back = 1,
    forward,
    up,
    refresh,
    home,
    quit,
};

const entry_base: u64 = 0x1000_0000;

pub fn raw(action: Action) u64 {
    return @intFromEnum(action);
}

pub fn entry(index: usize) u64 {
    return entry_base + index;
}

pub const Decoded = union(enum) {
    action: Action,
    entry: usize,
};

pub fn decode(value: u64) ?Decoded {
    if (value >= entry_base) return .{ .entry = @intCast(value - entry_base) };
    const action: Action = switch (value) {
        1 => .back,
        2 => .forward,
        3 => .up,
        4 => .refresh,
        5 => .home,
        6 => .quit,
        else => return null,
    };
    return .{ .action = action };
}

const std = @import("std");

test "semantic action IDs round trip without UI types" {
    try std.testing.expectEqual(Action.back, decode(raw(.back)).?.action);
    try std.testing.expectEqual(@as(usize, 42), decode(entry(42)).?.entry);
}
