//! Demo-owned Snail text resources and Goop measurement capability.

const std = @import("std");
const goop = @import("goop");
const snail = @import("goop_snail");
const font_loader = @import("demo_font_loader");
const image_decoder = @import("demo_image_decoder");

pub const Text = struct {
    allocator: std.mem.Allocator,
    fonts: font_loader.FontSet,
    engine: snail.TextEngine,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
    ) !Text {
        var fonts = try font_loader.load(allocator, io, environment);
        errdefer fonts.deinit();
        const faces = try allocator.alloc(snail.FontFace, fonts.faces.len);
        defer allocator.free(faces);
        var face_count: usize = 0;
        for (fonts.faces) |font| {
            const face = snail.FontFace{
                .bytes = font.bytes,
                .face_index = font.face_index,
            };
            snail.validateFontFace(face) catch continue;
            faces[face_count] = face;
            face_count += 1;
        }
        if (face_count == 0) return error.FontNotFound;
        return .{
            .allocator = allocator,
            .fonts = fonts,
            .engine = try snail.TextEngine.initFaces(allocator, faces[0..face_count], .{
                .image_decoder = image_decoder.decoder,
            }),
        };
    }

    pub fn deinit(self: *Text) void {
        self.engine.deinit();
        self.fonts.deinit();
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

test "desktop font composition shapes across the resolved fallback chain" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var text = try Text.init(std.testing.allocator, std.testing.io, &environment);
    defer text.deinit();

    const metrics = try text.engine.measure("Latin \xd8\xb9 \xe4\xb8\xad", 14);
    try std.testing.expect(metrics.width > 0);
    var prepared = try text.engine.prepareText(
        std.testing.allocator,
        "Latin \xd8\xb9 \xe4\xb8\xad",
        .{
            .baseline = .{ .x = 0.25, .y = 15.75 },
            .world_to_pixel = .identity,
        },
        14,
        .rgb(255, 255, 255),
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.shapes.len > 0);

    if (image_decoder.supports_png) {
        var emoji = try text.engine.prepareText(
            std.testing.allocator,
            "A\u{1f600}",
            .{
                .baseline = .{ .x = 0, .y = 20 },
                .world_to_pixel = .identity,
            },
            18,
            .rgb(255, 255, 255),
        );
        defer emoji.deinit();
        var saw_color_bitmap = false;
        for (emoji.shapes) |shape| {
            saw_color_bitmap = saw_color_bitmap or snail.isColorBitmapShape(shape);
        }
        try std.testing.expect(saw_color_bitmap);
    }
}
