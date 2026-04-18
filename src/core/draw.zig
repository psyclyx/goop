const style = @import("style.zig");

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// A single draw command emitted by the core.
pub const DrawCommand = union(enum) {
    rect: DrawRect,
    text: DrawText,
    clip: ClipRect,

    pub const DrawRect = struct {
        bounds: Rect,
        color: style.Color,
        border_color: style.Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const DrawText = struct {
        x: f32,
        y: f32,
        text: []const u8,
        color: style.Color,
        font_size: f32,
    };

    pub const ClipRect = struct {
        bounds: ?Rect,
    };
};

/// Accumulated draw output from a frame.
pub const DrawList = struct {
    commands: []const DrawCommand,
};
