const std = @import("std");

/// RGBA color, 0–255 per channel.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

/// Spacing for padding/margin (top, right, bottom, left).
pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn symmetric(h: f32, v: f32) Edges {
        return .{ .top = v, .right = h, .bottom = v, .left = h };
    }
};

/// Global theme. Widgets inherit from this by default.
pub const Theme = struct {
    bg: Color = Color.rgb(30, 30, 30),
    fg: Color = Color.rgb(220, 220, 220),
    accent: Color = Color.rgb(80, 140, 220),
    border: Color = Color.rgb(60, 60, 60),

    bg_hover: Color = Color.rgb(45, 45, 45),
    bg_active: Color = Color.rgb(55, 55, 55),
    focus_ring: Color = Color.rgba(80, 140, 220, 200),

    font_size: f32 = 14,
    padding: Edges = Edges.all(6),
    border_radius: f32 = 4,
    border_width: f32 = 1,
    spacing: f32 = 4,
    thumb_width: f32 = 16,

    pub const default: Theme = .{};
};

/// Per-widget style overrides. null fields inherit from the theme.
pub const Style = struct {
    bg: ?Color = null,
    fg: ?Color = null,
    border: ?Color = null,
    font_size: ?f32 = null,
    padding: ?Edges = null,
    border_radius: ?f32 = null,
    border_width: ?f32 = null,
    thumb_width: ?f32 = null,

    pub fn resolve(self: Style, theme: Theme) ResolvedStyle {
        return .{
            .bg = self.bg orelse theme.bg,
            .fg = self.fg orelse theme.fg,
            .border = self.border orelse theme.border,
            .font_size = self.font_size orelse theme.font_size,
            .padding = self.padding orelse theme.padding,
            .border_radius = self.border_radius orelse theme.border_radius,
            .border_width = self.border_width orelse theme.border_width,
            .thumb_width = self.thumb_width orelse theme.thumb_width,
        };
    }
};

/// Fully resolved style — no optional fields, ready for layout/draw.
pub const ResolvedStyle = struct {
    bg: Color,
    fg: Color,
    border: Color,
    font_size: f32,
    padding: Edges,
    border_radius: f32,
    border_width: f32,
    thumb_width: f32,
};

test "style resolves against theme" {
    const theme = Theme.default;
    const style = Style{ .bg = Color.rgb(255, 0, 0) };
    const resolved = style.resolve(theme);
    try std.testing.expectEqual(@as(u8, 255), resolved.bg.r);
    try std.testing.expectEqual(theme.fg, resolved.fg);
}
