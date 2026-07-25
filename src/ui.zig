//! Declarative UI descriptions.
//!
//! `Element` is presentation data. Retained interaction state belongs to
//! `goop_driver`; application state belongs to the embedding application.

const std = @import("std");
const display = @import("goop_display");

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

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(value: f32) Edges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn symmetric(horizontal: f32, vertical: f32) Edges {
        return .{
            .top = vertical,
            .right = horizontal,
            .bottom = vertical,
            .left = horizontal,
        };
    }
};

pub const Theme = struct {
    bg: display.Color = .rgb(30, 30, 30),
    fg: display.Color = .rgb(220, 220, 220),
    accent: display.Color = .rgb(80, 140, 220),
    border: display.Color = .rgb(60, 60, 60),
    bg_hover: display.Color = .rgb(45, 45, 45),
    bg_active: display.Color = .rgb(55, 55, 55),
    focus_ring: display.Color = .rgba(80, 140, 220, 200),
    placeholder_fg: display.Color = .rgb(120, 120, 120),
    selection_bg: display.Color = .rgba(80, 140, 220, 100),
    tree_guide: display.Color = .rgba(110, 110, 110, 180),
    font_size: f32 = 14,
    padding: Edges = .all(6),
    border_radius: f32 = 4,
    border_width: f32 = 1,
    spacing: f32 = 4,
    thumb_width: f32 = 16,

    pub const default: Theme = .{};
};

pub const Style = struct {
    bg: ?display.Color = null,
    fg: ?display.Color = null,
    accent: ?display.Color = null,
    border: ?display.Color = null,
    bg_hover: ?display.Color = null,
    bg_active: ?display.Color = null,
    focus_ring: ?display.Color = null,
    placeholder_fg: ?display.Color = null,
    selection_bg: ?display.Color = null,
    tree_guide: ?display.Color = null,
    font_size: ?f32 = null,
    padding: ?Edges = null,
    border_radius: ?f32 = null,
    border_width: ?f32 = null,
    spacing: ?f32 = null,
    thumb_width: ?f32 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: f32 = 0,
    min_height: f32 = 0,
    flex_grow: f32 = 0,
    gap: ?f32 = null,
    text_align: display.TextAlign = .start,
};

pub const WidgetKind = union(enum) {
    container: Container,
    text: Text,
    button: Button,
    icon: Icon,
    spacer,

    pub const Container = struct {
        direction: Direction = .column,

        pub const Direction = enum { row, column };
    };

    pub const Text = struct {
        content: []const u8,
        overflow: display.TextOverflow = .visible,
    };

    pub const Button = struct {
        label: []const u8,
    };

    pub const Icon = struct {
        kind: display.IconId,
    };
};

pub const Element = struct {
    id: ElementId,
    widget: WidgetKind,
    style: Style = .{},
    action: ?ActionId = null,
    children: []const Element = &.{},
};

pub const Color = display.Color;
pub const IconId = display.IconId;
pub const TextOverflow = display.TextOverflow;

test "elements carry description without runtime state" {
    const element = Element{
        .id = .init(1),
        .widget = .{ .button = .{ .label = "Open" } },
        .action = .init(7),
    };
    try std.testing.expectEqual(@as(u64, 1), element.id.value());
    try std.testing.expectEqual(@as(u64, 7), element.action.?.value());
}
