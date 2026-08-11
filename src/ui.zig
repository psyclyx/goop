//! Stable semantic identities shared across Goop's composable layers.
//!
//! This module deliberately contains no widget descriptions, visual values,
//! retained state, behavior, or rendering policy. Higher layers communicate
//! about controls with these IDs without depending on one another.

const std = @import("std");

pub const ElementId = enum(u64) {
    _,

    pub fn init(id_value: u64) ElementId {
        return @enumFromInt(id_value);
    }

    pub fn value(self: ElementId) u64 {
        return @intFromEnum(self);
    }
};

pub const ActionId = enum(u64) {
    _,

    pub fn init(id_value: u64) ActionId {
        return @enumFromInt(id_value);
    }

    pub fn value(self: ActionId) u64 {
        return @intFromEnum(self);
    }
};

test "semantic IDs preserve their values and remain distinct types" {
    const element = ElementId.init(17);
    const action = ActionId.init(17);

    try std.testing.expectEqual(@as(u64, 17), element.value());
    try std.testing.expectEqual(@as(u64, 17), action.value());
    try std.testing.expect(ElementId != ActionId);
}

test "identity leaf has no declarative, visual, retained, or behavior API" {
    const identity = @This();

    comptime {
        std.debug.assert(!@hasDecl(identity, "Element"));
        std.debug.assert(!@hasDecl(identity, "WidgetKind"));
        std.debug.assert(!@hasDecl(identity, "Style"));
        std.debug.assert(!@hasDecl(identity, "Theme"));
        std.debug.assert(!@hasDecl(identity, "Color"));
        std.debug.assert(!@hasDecl(identity, "IconId"));
        std.debug.assert(!@hasDecl(identity, "Tree"));
        std.debug.assert(!@hasDecl(identity, "Runtime"));
        std.debug.assert(!@hasDecl(identity, "Behavior"));
    }
}
