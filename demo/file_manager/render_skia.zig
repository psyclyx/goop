//! Skia (GPU/Ganesh) renderer for the file manager demo.
//!
//! Implements the same `Renderer` seam as `render_snail.zig`, but draws the
//! visual vocabulary with Skia and measures text with Skia's own `SkFont` — so
//! this build never links `goop_snail` or the demo text engine.
//!
//! Known gaps versus the snail backend: icon/image ops are Skia stubs (toolbar
//! and list icons and image previews do not draw yet), and the About child
//! window is not hosted here.

const std = @import("std");
const goop = @import("goop");
const visual = @import("goop_visual");
const platform = @import("goop_platform_wayland");
const bridge = @import("goop_wayland_vulkan");
const graphics = @import("goop_graphics_vulkan");
const skia = @import("goop_render_skia");

const allocator = std.heap.smp_allocator;

/// This backend does not host the About child window.
pub const supports_about = false;

pub const Renderer = struct {
    instance: graphics.Instance,
    surface: bridge.Surface,
    device: graphics.Device,
    ctx: skia.Context,
    target: skia.WindowTarget,

    /// Heap-pinned for uniformity with the snail backend (and so the
    /// measure context's `user_data` stays valid).
    pub fn create(
        window: *const platform.Window,
        io: std.Io,
        env: *const std.process.Environ.Map,
        width: u32,
        height: u32,
    ) !*Renderer {
        _ = io;
        _ = env;
        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);

        const extensions = bridge.requiredInstanceExtensions();
        self.instance = try graphics.Instance.init("goop-file-manager-skia", extensions[0..]);
        errdefer self.instance.deinit();

        const handles = window.wsiHandles();
        self.surface = try bridge.Surface.init(self.instance, .{
            .display = @ptrCast(handles.display),
            .surface = @ptrCast(handles.surface),
        });
        errdefer self.surface.deinit();

        self.device = try graphics.Device.init(allocator, self.instance, self.surface.handle);
        errdefer self.device.deinit();

        self.ctx = try skia.Context.initVulkan(self.instance, self.device);
        errdefer self.ctx.deinit();

        self.target = try skia.WindowTarget.init(&self.ctx, self.device, self.surface.handle, width, height, allocator);
        return self;
    }

    pub fn destroy(self: *Renderer) void {
        self.target.deinit();
        self.ctx.deinit();
        self.device.deinit();
        self.surface.deinit();
        self.instance.deinit();
        allocator.destroy(self);
    }

    pub fn measureContext(self: *Renderer) goop.TextMeasureCtx {
        return .{ .measureFn = measure, .user_data = self.ctx.handle };
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.target.resize(width, height) catch {};
    }

    pub fn renderFrame(self: *Renderer, window: *platform.Window, commands: []const visual.Operation, clear: [4]f32) !bool {
        const frame = (try self.target.acquire()) orelse return false;
        var f = frame;
        var enc = f.surface.encoder();
        enc.clear(colorFromClear(clear));
        try visual.emitAll(&enc, commands);
        window.requestFrame();
        try self.target.present(f);
        return true;
    }
};

fn colorFromClear(clear: [4]f32) visual.Color {
    return .{
        .r = @intFromFloat(std.math.clamp(clear[0], 0, 1) * 255),
        .g = @intFromFloat(std.math.clamp(clear[1], 0, 1) * 255),
        .b = @intFromFloat(std.math.clamp(clear[2], 0, 1) * 255),
        .a = @intFromFloat(std.math.clamp(clear[3], 0, 1) * 255),
    };
}

fn measure(bytes: []const u8, font_size: f32, user_data: ?*anyopaque) goop.TextDimensions {
    const handle = user_data orelse return fallback(bytes, font_size);
    var ctx = skia.Context{ .handle = handle, .backend = .vulkan };
    const m = ctx.measureText(bytes, font_size);
    if (m.width <= 0 and bytes.len > 0) return fallback(bytes, font_size);
    return .{ .width = m.width, .height = m.height, .ascent = m.ascent, .descent = m.descent };
}

fn fallback(bytes: []const u8, font_size: f32) goop.TextDimensions {
    const glyphs = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
    return .{
        .width = @as(f32, @floatFromInt(glyphs)) * font_size * 0.6,
        .height = font_size * 1.2,
        .ascent = font_size,
        .descent = font_size * 0.2,
    };
}
