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
    placeholder_fg: Color = Color.rgb(120, 120, 120),
    selection_bg: Color = Color.rgba(80, 140, 220, 100),
    tree_guide: Color = Color.rgba(110, 110, 110, 180),

    font_size: f32 = 14,
    padding: Edges = Edges.all(6),
    border_radius: f32 = 4,
    border_width: f32 = 1,
    spacing: f32 = 4,
    thumb_width: f32 = 16,

    pub const default: Theme = .{};
};

/// Per-widget style overrides. Every field mirrors a `Theme` field;
/// null inherits from the active theme. The comptime check below
/// asserts the two field sets stay in sync — adding a field to Theme
/// without adding it here is a compile error. (Zig 0.16 removed
/// `@Type` so we can't auto-derive the struct, but the assert keeps
/// drift impossible.)
pub const Style = struct {
    bg: ?Color = null,
    fg: ?Color = null,
    accent: ?Color = null,
    border: ?Color = null,
    bg_hover: ?Color = null,
    bg_active: ?Color = null,
    focus_ring: ?Color = null,
    placeholder_fg: ?Color = null,
    selection_bg: ?Color = null,
    tree_guide: ?Color = null,
    font_size: ?f32 = null,
    padding: ?Edges = null,
    border_radius: ?f32 = null,
    border_width: ?f32 = null,
    spacing: ?f32 = null,
    thumb_width: ?f32 = null,

    pub fn resolve(self: Style, theme: Theme) ResolvedStyle {
        var out: ResolvedStyle = theme;
        inline for (@typeInfo(Theme).@"struct".fields) |field| {
            if (@field(self, field.name)) |value| {
                @field(out, field.name) = value;
            }
        }
        return out;
    }
};

/// Fully resolved style — no optional fields, ready for layout/draw.
/// Structurally identical to `Theme`.
pub const ResolvedStyle = Theme;

comptime {
    const theme_fields = @typeInfo(Theme).@"struct".fields;
    const style_fields = @typeInfo(Style).@"struct".fields;
    if (theme_fields.len != style_fields.len) {
        @compileError("Theme and Style have diverged: field counts differ");
    }
    for (theme_fields, style_fields) |theme_field, style_field| {
        if (!std.mem.eql(u8, theme_field.name, style_field.name)) {
            @compileError("Theme and Style have diverged: field name mismatch (Theme has '" ++
                theme_field.name ++ "', Style has '" ++ style_field.name ++ "')");
        }
        const opt_info = @typeInfo(style_field.type);
        if (opt_info != .optional or opt_info.optional.child != theme_field.type) {
            @compileError("Theme and Style have diverged: '" ++ theme_field.name ++
                "' should be `?<theme type>` on Style");
        }
    }
}

test "style resolves against theme" {
    const theme = Theme.default;
    const s = Style{ .bg = Color.rgb(255, 0, 0) };
    const resolved = s.resolve(theme);
    try std.testing.expectEqual(@as(u8, 255), resolved.bg.r);
    try std.testing.expectEqual(theme.fg, resolved.fg);
    try std.testing.expectEqual(theme.spacing, resolved.spacing);
}
