//! Coordinate-space values shared across UI, input, visuals, and renderers.
//!
//! The types carry no coordinate-system policy. A boundary that accepts them
//! must document whether its values are surface-local, control-local, or in
//! another explicit space.

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

test "geometry values are plain coordinate data" {
    const point = Point{ .x = 12, .y = 18 };
    const rect = Rect{ .x = point.x, .y = point.y, .w = 40, .h = 24 };

    try @import("std").testing.expectEqual(@as(f32, 12), rect.x);
    try @import("std").testing.expectEqual(@as(f32, 24), rect.h);
}
