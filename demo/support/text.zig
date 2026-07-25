//! Snail 0.13 text ownership and the legacy goop measurement boundary.

const std = @import("std");
const goop = @import("goop");
const snail = @import("goop_snail");
const font_loader = @import("demo_font_loader");

pub const Text = struct {
    allocator: std.mem.Allocator,
    font_bytes: []u8,
    engine: snail.TextEngine,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
    ) !Text {
        const font_bytes = try font_loader.load(allocator, io, environment);
        errdefer allocator.free(font_bytes);
        return .{
            .allocator = allocator,
            .font_bytes = font_bytes,
            .engine = try snail.TextEngine.init(allocator, font_bytes, .{}),
        };
    }

    pub fn deinit(self: *Text) void {
        self.engine.deinit();
        self.allocator.free(self.font_bytes);
        self.* = undefined;
    }

    pub fn measureContext(self: *Text) goop.TextMeasureCtx {
        return .{
            .measureFn = measure,
            .user_data = @ptrCast(self),
        };
    }

    fn measure(
        bytes: []const u8,
        font_size: f32,
        user_data: ?*anyopaque,
    ) goop.TextDimensions {
        const self: *Text = @ptrCast(@alignCast(user_data orelse return fallback(bytes, font_size)));
        const metrics = self.engine.measure(bytes, font_size) catch return fallback(bytes, font_size);
        return .{
            .width = metrics.width,
            .height = metrics.height(),
            .ascent = metrics.ascent,
            .descent = @abs(metrics.descent),
        };
    }
};

fn fallback(bytes: []const u8, font_size: f32) goop.TextDimensions {
    const glyphs = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
    return .{
        .width = @as(f32, @floatFromInt(glyphs)) * font_size * 0.6,
        .height = font_size * 1.2,
        .ascent = font_size,
        .descent = font_size * 0.2,
    };
}
