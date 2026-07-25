//! Backend-neutral display output and damage protocol.
//!
//! This module is the only rendering vocabulary exposed to the UI layers.
//! Backends consume it; components and drivers never name a graphics API.

const types = @import("display/types.zig");
const std = @import("std");

pub const Rect = types.Rect;
pub const Color = types.Color;
pub const PaintCommand = types.PaintCommand;
pub const PaintList = types.PaintList;
pub const TextAlign = types.TextAlign;
pub const TextOverflow = types.TextOverflow;
pub const IconId = types.IconId;
pub const CustomId = types.CustomId;

pub const DamageSet = @import("display/damage.zig").DamageSet;

pub const CommandId = enum(u64) {
    _,

    pub fn init(id_value: u64) CommandId {
        return @enumFromInt(id_value);
    }

    pub fn value(self: CommandId) u64 {
        return @intFromEnum(self);
    }

    /// Derive a stable paint-command ID from a stable element ID and a
    /// component-local slot. Components may emit several commands without
    /// exposing renderer-specific handles.
    pub fn fromElement(element_id: u64, slot: u16) CommandId {
        var hash = std.hash.Wyhash.init(0x676f_6f70_6469_7370);
        hash.update(std.mem.asBytes(&element_id));
        hash.update(std.mem.asBytes(&slot));
        return .init(hash.final());
    }
};

pub const Command = struct {
    id: CommandId,
    fingerprint: u64,
    order: u32 = 0,
    paint: PaintCommand,

    pub fn bounds(self: Command) ?Rect {
        return commandBounds(self.paint);
    }
};

pub const Remove = struct {
    id: CommandId,
    old_bounds: ?Rect,
};

pub const Operation = union(enum) {
    put: Command,
    remove: Remove,
};

/// Incremental semantic display update. The operation slice is borrowed from
/// the driver; damage is owned by the producer and remains valid for the same
/// lifetime as `operations`.
pub const DisplayDelta = struct {
    operations: []const Operation,
    damage: Damage,

    pub const Damage = union(enum) {
        none,
        regions: []const Rect,
        full,
    };
};

pub fn commandBounds(command: PaintCommand) ?Rect {
    return switch (command) {
        .surface => |value| value.bounds,
        .text => |value| value.bounds,
        .icon => |value| value.bounds,
        .custom => |value| value.bounds,
        .clip => |value| value.bounds,
    };
}

/// Content fingerprint used by retained drivers. It hashes semantic fields,
/// not struct bytes, so padding and borrowed slice addresses are irrelevant.
pub fn fingerprint(command: PaintCommand) u64 {
    var hash = std.hash.Wyhash.init(0x676f_6f70_7061_696e);
    const tag = std.meta.activeTag(command);
    hash.update(std.mem.asBytes(&tag));
    switch (command) {
        .surface => |value| {
            hashRect(&hash, value.bounds);
            hash.update(std.mem.asBytes(&value.role));
            hash.update(std.mem.asBytes(&value.state));
            hashColor(&hash, value.color);
            hashColor(&hash, value.border_color);
            hash.update(std.mem.asBytes(&value.border_width));
            hash.update(std.mem.asBytes(&value.corner_radius));
        },
        .text => |value| {
            hashRect(&hash, value.bounds);
            hash.update(value.text);
            hashColor(&hash, value.color);
            hash.update(std.mem.asBytes(&value.font_size));
            hash.update(std.mem.asBytes(&value.text_align));
            hash.update(std.mem.asBytes(&value.overflow));
        },
        .icon => |value| {
            hashRect(&hash, value.bounds);
            hash.update(std.mem.asBytes(&value.kind));
            hashColor(&hash, value.color);
        },
        .custom => |value| {
            hash.update(std.mem.asBytes(&value.id));
            hashRect(&hash, value.bounds);
        },
        .clip => |value| {
            const present = value.bounds != null;
            hash.update(std.mem.asBytes(&present));
            if (value.bounds) |bounds| hashRect(&hash, bounds);
        },
    }
    return hash.final();
}

fn hashRect(hash: *std.hash.Wyhash, rect: Rect) void {
    hash.update(std.mem.asBytes(&rect.x));
    hash.update(std.mem.asBytes(&rect.y));
    hash.update(std.mem.asBytes(&rect.w));
    hash.update(std.mem.asBytes(&rect.h));
}

fn hashColor(hash: *std.hash.Wyhash, color: Color) void {
    hash.update(&.{ color.r, color.g, color.b, color.a });
}

test {
    _ = @import("display/damage.zig");
}

test "paint fingerprints ignore slice addresses and track content" {
    const first = PaintCommand{ .text = .{
        .bounds = .{ .x = 1, .y = 2, .w = 30, .h = 10 },
        .text = "same",
        .color = .rgb(1, 2, 3),
        .font_size = 14,
    } };
    var copy = [_]u8{ 's', 'a', 'm', 'e' };
    const second = PaintCommand{ .text = .{
        .bounds = .{ .x = 1, .y = 2, .w = 30, .h = 10 },
        .text = &copy,
        .color = .rgb(1, 2, 3),
        .font_size = 14,
    } };
    try std.testing.expectEqual(fingerprint(first), fingerprint(second));
    copy[0] = 'S';
    try std.testing.expect(fingerprint(first) != fingerprint(second));
}
